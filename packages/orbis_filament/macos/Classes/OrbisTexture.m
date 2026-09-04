#import "OrbisTexture.h"

@implementation OrbisTexture {
  OrbisRenderer *_renderer;
}

- (instancetype)initWithRenderer:(OrbisRenderer *)renderer {
  if ((self = [super init])) {
    _renderer = renderer;
  }
  return self;
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  // Named "copy" by the protocol, but what is copied is the reference: the
  // pixels stay in the IOSurface Filament rendered into.
  return [_renderer copyPresentedBuffer];
}

@end
