// IPDVirtualDisplay.m

#import "IPDVirtualDisplay.h"

// Declarations of the undocumented CoreGraphics classes. They are never referenced as
// symbols: instances are created through NSClassFromString, so there is no link-time
// dependency on them.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static NSString *const IPDErrorDomain = @"IPDVirtualDisplay";

static void IPDFail(NSError **error, NSInteger code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:IPDErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

@interface IPDVirtualDisplay ()
@property (nonatomic, strong, nullable) id display;  // the CGVirtualDisplay; releasing it removes the display
@property (nonatomic, readwrite) CGDirectDisplayID displayID;
@end

@implementation IPDVirtualDisplay

+ (BOOL)isAvailable {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

+ (instancetype)makeWithName:(NSString *)name
                  pixelWidth:(NSUInteger)pixelWidth
                 pixelHeight:(NSUInteger)pixelHeight
                 refreshRate:(double)refreshRate
                       hiDPI:(BOOL)hiDPI
                      serial:(uint32_t)serial
                       error:(NSError **)error {
    if (![self isAvailable]) {
        IPDFail(error, 1, @"This version of macOS does not provide virtual displays to apps.");
        return nil;
    }
    if (pixelWidth < 2 || pixelHeight < 2) {
        IPDFail(error, 2, @"The display size is invalid.");
        return nil;
    }

    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)pixelWidth;
    descriptor.maxPixelsHigh = (unsigned int)pixelHeight;
    // Roughly 264 pixels per inch (iPad Air 1st gen), so macOS chooses sensible UI sizes.
    descriptor.sizeInMillimeters = CGSizeMake(pixelWidth / 264.0 * 25.4, pixelHeight / 264.0 * 25.4);
    // macOS 14 and later want a non-zero vendor ID and a distinct serial per display identity.
    descriptor.vendorID = 0x4950;
    descriptor.productID = 0x4944;
    descriptor.serialNum = serial;
    if ([descriptor respondsToSelector:@selector(setDispatchQueue:)]) {
        [descriptor setDispatchQueue:dispatch_get_main_queue()];
    }

    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) {
        IPDFail(error, 3, @"macOS refused to create the virtual display.");
        return nil;
    }

    // In Apple's private CGVirtualDisplay API, CGVirtualDisplayMode width and height
    // are the physical pixel dimensions. When settings.hiDPI is enabled, macOS
    // automatically provisions the 2x Retina logical point scaling. Passing halved dimensions
    // creates an invalid mode configuration that causes WindowServer's GenerateModeListForDisplay
    // to abort and crash the entire user session.
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:pixelWidth height:pixelHeight refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[mode];

    if (![display applySettings:settings]) {
        IPDFail(error, 4, @"macOS did not accept the display settings.");
        return nil;
    }

    IPDVirtualDisplay *result = [[IPDVirtualDisplay alloc] init];
    result.display = display;
    result.displayID = display.displayID;
    return result;
}

- (void)destroy {
    self.display = nil;
    self.displayID = 0;
}

- (void)dealloc {
    [self destroy];
}

@end
