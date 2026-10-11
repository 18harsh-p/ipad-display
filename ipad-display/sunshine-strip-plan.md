# Sunshine fork: strip-down plan

Goal: fork LizardByte/Sunshine and cut it down to a macOS-only streaming host that the combined FluffyDisplay + Sunshine app builds on. Upstream base commit: 31da0d8 (9 Oct 2026). Sunshine is GPL-3.0-only, FluffyDisplay is Apache-2.0.

## Facts that shape the design
- On macOS, `output_name` is parsed as a real CGDirectDisplayID (src/platform/macos/display.mm). A value that does not parse falls back to the main display. Index values like 0/1/2/3 are not valid, and 0 is not a valid display ID.
- The captured frame size is set from the size the Moonlight client requests, so portrait support will need either a client-requested portrait size or host-side rotation. Deferred until the client side shows a problem.
- FFmpeg comes as a prebuilt archive from LizardByte/build-deps releases; the macOS capture path is AVFoundation, encoding goes through VideoToolbox/FFmpeg.

## Stage 1 (done): delete everything that is not macOS, no C++ changes
Script: stage1.sh (run from the fork root on a clean tree; it stages, does not commit).
- Removes Windows/Linux/BSD platform code and assets, other-OS packaging, docs, website template, upstream tests and CI, Docker, and the submodules only those platforms used.
- CMake simplified to macOS only. Tray and Homebrew options now default to OFF.
- Repo goes from about 34 MB to about 5 MB of source.
- Not yet built on a Mac. Dead `#ifdef _WIN32` / `__linux__` branches remain in C++ files and a few WIN32/FREEBSD branches remain in Boost_Sunshine.cmake and ffmpeg.cmake.

## Stage 2 (next, needs a Mac build after each step)
1. Remove system tray (system_tray.*, third-party/tray, Qt), UPnP (upnp.*, miniupnpc), nvenc/ and the leftover platform branches.
2. Remove the web UI and config HTTP server (confighttp.*, package.json, vite, src_assets/common/assets/web); replace pairing/PIN entry with a small direct call the app makes. NOTE: the backend currently pairs through confighttp's /api/pin, so do this only together with a replacement.
3. Remove app launching (process.*, apps.json) in favour of one fixed entry.
4. Remove libdisplaydevice and its config; capture takes the display ID from the app.
5. Decide on audio (microphone.mm, av_audio.*, TPCircularBuffer), gamepad/touch input via libvirtualhid, and software encoders. Defaults: drop audio and gamepad at first, keep mouse and keyboard, keep VideoToolbox H.264.
6. Shrink config.cpp to the few options still used.

## Menu-bar app (Swift shell around Sunshine)
The menu replaces the Qt tray and the web UI, so it is the only UI. File: MenuBarController.swift (AppKit, macOS 13+).
- Status line, Orientation (Landscape/Portrait, default Portrait) plus quick Rotate, Size presets (2048×1536, 1600×1200, 1024×768; stored landscape, swapped for portrait), Refresh rate (30/60), Sharp text (HiDPI, default on), Restart display, Pair new iPad (PIN), Open at login, Quit and remove display.
- Settings saved in UserDefaults.
- Rule: any orientation/size/refresh/HiDPI change destroys and recreates the virtual display, then points Sunshine at the new display ID and restarts it. Never switch the mode of a live virtual display.

## StreamBackend (written, nothing compiled on a Mac yet)
Files: IPDVirtualDisplay.h/.m (ObjC wrapper for the private CGVirtualDisplay classes, looked up by name at runtime), VirtualDisplayManager.swift, SunshineProcess.swift, DisplayStreamBackend.swift, main.swift, iPadDisplay-Bridging-Header.h.
- Order for every change: stop Sunshine, destroy old display, create new display, write config with new display ID, start Sunshine, wait until ready.
- The display has exactly one mode (HiDPI: half the pixel size in points). Serial number encodes size, refresh rate and HiDPI, because macOS remembers a mode per monitor identity.
- Sunshine runs as a child process with its own folder ~/.config/ipad-display (config, state, keys, log, apps, API login), separate from any existing ~/.config/sunshine. The path has no spaces because Sunshine's config has no quoting.
- Pairing: Sunshine's local HTTPS API (GET/POST /api/pin, Basic auth, port 47990, localhost only, random password in a 0600 file). Requests without Origin/Referer skip CSRF.
- State: parsed from Sunshine's console output ("Configuration UI available", "CLIENT CONNECTED", "CLIENT DISCONNECTED").
- A leftover Sunshine from a killed app (Xcode Stop) is found through its pid file and stopped before the next start.
- Not sandboxed (sandbox blocks the private API and child processes). Needs Screen Recording and Accessibility permission.

## Open risks to check on the first Mac run
1. HiDPI: confirm System Settings > Displays shows 2048×1536 HiDPI. If it shows a 1024×768 low-resolution display, turn off Sharp text and report back (the private API's HiDPI behaviour is from memory of other projects, not verified).
2. Stage 1 fork has never been built on a Mac.
3. Moonlight portrait handling (stream size requested by the iPad client) is untested and deferred.
4. Old Sunshine / BetterDisplay virtual display must be quit before running, or ports and display IDs clash.
