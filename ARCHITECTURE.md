# iPad Display: Architecture & Internal Design

This document details the internal architecture, design invariants, hardware pipelines, and state management of **iPad Display**.

---

## 🏛️ System Overview

iPad Display consists of five cooperating subsystems orchestrated around a strict serial state machine:

```
+-------------------------------------------------------------+
|                     MenuBarController                       |
|               (AppKit, User Preferences, UI)                |
+-------------------------------------------------------------+
                               |
                               v
+-------------------------------------------------------------+
|                    DisplayStreamBackend                     |
|           (Serial queue orchestrator & state machine)       |
+-------------------------------------------------------------+
         |                        |                     |
         v                        v                     v
+------------------+    +-------------------+   +--------------------+
|  VirtualDisplay  |    |    ScreenRelay    |   |  SunshineProcess   |
|     Manager      |    |  (Metal / SCKit)  |   |    (Host Daemon)   |
+------------------+    +-------------------+   +--------------------+
         |                        |                     |
         v                        v                     v
  WindowServer             Render Pipeline         Moonlight (iPad)
(Private CoreGraphics)      (90°/270° GPU)          (RTSP / H.264)
```

---

## 1. Subsystem Breakdown

### 1.1 `MenuBarController` (`MenuBarController.swift`)
- **Role**: Pure AppKit UI shell and settings keeper.
- **Invariants**:
  - Never references CoreGraphics display APIs or Sunshine directly.
  - Maintains `DisplaySettings` (`orientation`, `portraitRotation`, `sizeIndex`, `refreshRate`, `hiDPI`) persisted via `UserDefaults`.
  - Disables menu interactions (`isApplying = true`) while a reconfiguration task is in-flight to prevent overlapping display mutations.
  - Controls launch-at-login via `ServiceManagement.SMAppService`.

### 1.2 `DisplayStreamBackend` (`DisplayStreamBackend.swift`)
- **Role**: State coordinator and serialized execution engine.
- **State Machine (`StreamState`)**:
  - `.stopped`: Engine inactive, virtual displays destroyed.
  - `.starting`: Displays being provisioned, relay starting, Sunshine initializing.
  - `.waitingForClient`: Sunshine ready and listening for an RTSP/Moonlight connection.
  - `.streaming(clientName)`: Active video stream established to client.
  - `.failed(reason)`: Unrecoverable error encountered (e.g., missing permissions, binary crash).
- **Sequential Order of Operations on Reconfiguration**:
  ```
  Request -> Stop Sunshine -> Stop ScreenRelay -> Destroy Displays ->
  Create New Virtual Display(s) -> Start ScreenRelay (if Portrait) ->
  Update Sunshine Configuration with Capture Display ID -> Start Sunshine
  ```

### 1.3 `VirtualDisplayManager` & `IPDVirtualDisplay` (`VirtualDisplayManager.swift`, `IPDVirtualDisplay.h/.m`)
- **Role**: Lifecycle management for macOS virtual monitors.
- **Undocumented CoreGraphics Private API**:
  Accesses Apple's internal `CGVirtualDisplay` runtime classes via `NSClassFromString`:
  - `CGVirtualDisplayDescriptor`: Declares display name, max pixel limits, physical size in millimeters, vendor ID (`0x4950`), product ID (`0x4944`), and serial number.
  - `CGVirtualDisplaySettings`: Holds display modes and the `hiDPI` flag.
  - `CGVirtualDisplayMode`: Configures pixel resolution and refresh rate.
  - `CGVirtualDisplay`: Manages lifecycle; releasing the Objective-C object causes `WindowServer` to destroy the display.
- **Retina / HiDPI Rule**:
  In Apple's private API, `CGVirtualDisplayMode` **always** receives the physical pixel dimensions (e.g., 2048×1536). When `hiDPI = true` is set on `CGVirtualDisplaySettings`, macOS automatically exposes 2x logical scaling (1024×768 points). **Never** pass halved dimensions to `CGVirtualDisplayMode` with `hiDPI = true`, as this triggers an internal assertion failure in `WindowServer`'s `GenerateModeListForDisplay` and immediately crashes the user session!
- **Mode Switching Invariant**:
  `iPad Display` **never** alters the mode of an active virtual display. Doing so frequently results in orphan displays that macOS cannot tear down. Any modification destroys the display completely, increments a generation counter, and builds a new instance.
- **Serial Number Bitfield Encoding**:
  To ensure macOS treats each recreation as a new hardware identity, serial numbers are generated dynamically:
  ```
  Bit 31-24: Generation counter (8 bits, wrapping)
  Bit 23:    HiDPI flag (1 = retina, 0 = 1x)
  Bit 22:    Refresh rate (1 = 60Hz+, 0 = 30Hz)
  Bit 21-11: Height in pixels (11 bits, 1-4095)
  Bit 10-0:  Width in pixels (11 bits, 1-4095)
  ```

### 1.4 `ScreenRelay` (`ScreenRelay.swift`)
- **Role**: Hardware-accelerated frame capture, rotation, and re-rendering for portrait streaming.
- **Problem**: Moonlight iOS only streams in landscape orientation. If a portrait desktop is captured directly, Moonlight letterboxes the frame with wide black bars on both sides.
- **Solution (Dual Display Pipeline)**:
  1. `VirtualDisplayManager` creates:
     - `iPad Desktop`: 1536 × 2048 (HiDPI) – User-facing display.
     - `iPad Stream`: 2048 × 1536 (1x) – Invisible stream buffer.
  2. `ScreenCaptureKit` (`SCStream`) captures frames from `iPad Desktop`.
  3. `RelayRenderer` receives `CMSampleBuffer`s on a dedicated interactive dispatch queue.
  4. CoreImage transforms the frame with `CIImage.oriented(...)` using Metal shaders:
     - `portDown`: `.left` (270° CCW rotation)
     - `portUp`: `.right` (90° CW rotation)
  5. The oriented buffer is written to a `CAMetalLayer` hosted inside a borderless, transparent `NSWindow` mapped precisely to `iPad Stream`.
  6. Sunshine captures `iPad Stream` directly and encodes it through VideoToolbox.
- **Safety Measures**:
  - Pre-flight checks guarantee `targetDisplayID != CGMainDisplayID()`.
  - Subscribes to `NSApplication.didChangeScreenParametersNotification`; if the target screen disconnects or geometry shifts, the window immediately orders out to prevent covering user screens.

### 1.5 `SunshineProcess` (`SunshineProcess.swift`)
- **Role**: Manages the Sunshine streaming daemon child process and local API.
- **Configuration Sandboxing**:
  All files reside in `~/.config/ipad-display/` to prevent interference with a user's primary Sunshine setup (`~/.config/sunshine`):
  - `sunshine.conf`: Generated config setting `output_name = <displayID>`, resolutions, and restricted options.
  - `api-login.json`: Ephemeral 32-character random credentials with `0600` POSIX file permissions.
  - `sunshine.pid`: Tracks running PID.
  - `sunshine_state.json`: State database holding paired client certificates.
- **Certificate Sanitization**:
  If multiple devices share identical certificate signatures, Sunshine fails with `"Client certificate identity is not enabled"`. `sanitizeStateFile()` deduplicates entries before and after pairing.
- **Stale Process Reaping**:
  Before starting, `reapStaleProcess()` reads the PID file and uses Darwin's `proc_pidpath()` to verify that the PID belongs to Sunshine before sending `SIGTERM` / `SIGKILL`.
- **Local API Communication**:
  Pairs clients using `GET /api/pin` and `POST /api/pin` on `127.0.0.1:47990`. Self-signed HTTPS certificates are trusted strictly for localhost via a custom `URLSessionDelegate` (`LocalTrustDelegate`).

---

## 2. Concurrency and Thread Safety

- **UI Isolation**: `MenuBarController` and `ScreenRelay` window manipulations run on the `@MainActor`.
- **Serial Backend Queue**: Operations in `DisplayStreamBackend` execute in structured Swift concurrency Tasks with state synchronized using `NSLock`.
- **Display Polling**: `VirtualDisplayManager.destroy()` and `create*()` run on background tasks with polling timeouts to prevent blocking UI animations.
- **Real-Time Render Queue**: `ScreenCaptureKit` frame delivery and Metal rendering run on a dedicated queue (`qos: .userInteractive`).
