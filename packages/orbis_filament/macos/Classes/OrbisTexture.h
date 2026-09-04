#import <FlutterMacOS/FlutterMacOS.h>
#import <Foundation/Foundation.h>

#import "OrbisRenderer.h"

NS_ASSUME_NONNULL_BEGIN

/// Adapts a renderer to Flutter's texture registry.
///
/// `copyPixelBuffer` is the whole integration: Flutter asks for the latest
/// frame and gets the IOSurface-backed buffer Filament drew into, which the
/// compositor wraps as a Metal texture rather than reading back through the
/// CPU.
@interface OrbisTexture : NSObject <FlutterTexture>

- (instancetype)initWithRenderer:(OrbisRenderer *)renderer;

@end

NS_ASSUME_NONNULL_END
