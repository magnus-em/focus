#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// An extra display that exists only in WindowServer (CoreGraphics' private
/// CGVirtualDisplay, as used by DeskPad). Removed when this object is freed.
@interface FocusVirtualDisplay : NSObject
@property (readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithName:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height;
@end

NS_ASSUME_NONNULL_END
