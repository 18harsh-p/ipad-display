// IPDVirtualDisplay.h
//
// Thin Objective-C wrapper around Apple's undocumented CGVirtualDisplay classes.
// Kept in Objective-C on purpose: that is the language these private classes are
// documented in by other open-source projects, and the wrapper looks the classes up
// by name at runtime, so the app still launches (and shows a clear error) if a future
// macOS removes them.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface IPDVirtualDisplay : NSObject

/// The display ID macOS assigned. This is the value Sunshine's `output_name` needs.
@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// YES if this macOS still ships the private classes.
+ (BOOL)isAvailable NS_SWIFT_NAME(isAvailable());

/// Creates a virtual display with exactly one mode.
/// With `hiDPI` the single mode is (pixelWidth/2 x pixelHeight/2) points backed by
/// pixelWidth x pixelHeight pixels ("Retina"); without it the mode is 1x.
/// Releasing or destroying the returned object removes the display.
+ (nullable instancetype)makeWithName:(NSString *)name
                           pixelWidth:(NSUInteger)pixelWidth
                          pixelHeight:(NSUInteger)pixelHeight
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                               serial:(uint32_t)serial
                                error:(NSError **)error
    NS_SWIFT_NAME(make(name:pixelWidth:pixelHeight:refreshRate:hiDPI:serial:));

/// Explicitly tears down the underlying virtual display immediately.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
