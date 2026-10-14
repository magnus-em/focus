#import "VirtualDisplay.h"

// Private CoreGraphics classes (macOS 11+). Looked up by name so a missing
// class fails at runtime with nil instead of at link time.
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation FocusVirtualDisplay {
    CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height {
    self = [super init];
    if (!self) return nil;
    Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descClass || !displayClass || !settingsClass || !modeClass) return nil;

    CGVirtualDisplayDescriptor *desc = [[descClass alloc] init];
    desc.queue = dispatch_get_main_queue();
    desc.name = name;
    desc.maxPixelsWide = (unsigned int)(width * 2);
    desc.maxPixelsHigh = (unsigned int)(height * 2);
    desc.sizeInMillimeters = CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0);
    desc.vendorID = 0xF0C5;
    desc.productID = 0x0001;
    desc.serialNum = 0x0001;
    desc.terminationHandler = ^(id a, id b) {};

    _display = [[displayClass alloc] initWithDescriptor:desc];
    if (!_display) return nil;
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[[[modeClass alloc] initWithWidth:width height:height refreshRate:60]];
    if (![_display applySettings:settings]) return nil;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
