#import "OrbisSurface.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <filament/Engine.h>
#include <filament/SwapChain.h>

/// Presentation on macOS and iOS: IOSurface-backed CVPixelBuffers.
///
/// The buffer format is not a preference. BGRA in an IOSurface is what
/// Filament's Apple swap chain requires, and it is also the one thing
/// Flutter's compositor can adopt as a Metal texture without reading the
/// pixels back through the CPU — which is the entire reason the 3D content
/// can take part in Flutter's layout rather than floating over it in a
/// window of its own.
namespace {

constexpr int kMaxBuffers = 4;

class AppleSurface final : public OrbisSurface {
 public:
  bool allocate(filament::Engine* engine, uint32_t width, uint32_t height,
                filament::SwapChain** chains, int count) override {
    if (count > kMaxBuffers) return false;
    _count = count;
    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    bool whole = true;
    for (int i = 0; i < count; i++) {
      CVPixelBufferRef buffer = nullptr;
      const CVReturn made = CVPixelBufferCreate(
          kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
          (__bridge CFDictionaryRef)attributes, &buffer);
      _buffers[i] = made == kCVReturnSuccess ? buffer : nullptr;

      // Painted opaque black before anybody can see it.
      //
      // A fresh buffer's contents are whatever the memory held, and a buffer
      // is handed to Flutter the moment it is presented — so a frame that is
      // interrupted, or a resize that reallocates while something is still
      // reading, can put uninitialised memory on screen. It arrives as flat
      // white with magenta through it, which looks exactly like a texture
      // failing to load and is not.
      //
      // Costs one clear per buffer, three times, when a viewport is made or
      // resized. Nothing per frame.
      if (_buffers[i] &&
          CVPixelBufferLockBaseAddress(_buffers[i], 0) == kCVReturnSuccess) {
        uint8_t *pixels =
            (uint8_t *)CVPixelBufferGetBaseAddress(_buffers[i]);
        const size_t stride = CVPixelBufferGetBytesPerRow(_buffers[i]);
        const size_t rows = CVPixelBufferGetHeight(_buffers[i]);
        if (pixels) {
          // Opaque rather than clear: a transparent frame lets whatever is
          // behind the texture show through, which is its own confusion.
          memset(pixels, 0, stride * rows);
          for (size_t row = 0; row < rows; row++) {
            uint8_t *line = pixels + row * stride;
            for (size_t x = 3; x < stride; x += 4) line[x] = 0xFF;
          }
        }
        CVPixelBufferUnlockBaseAddress(_buffers[i], 0);
      }
      chains[i] = _buffers[i] ? engine->createSwapChain(
                                    (void*)_buffers[i],
                                    filament::SwapChain::CONFIG_APPLE_CVPIXELBUFFER)
                              : nullptr;
      if (!chains[i]) whole = false;
    }
    return whole;
  }

  void release(filament::Engine* engine, filament::SwapChain** chains,
               int count) override {
    for (int i = 0; i < count; i++) {
      if (chains[i]) {
        engine->destroy(chains[i]);
        chains[i] = nullptr;
      }
      if (i < kMaxBuffers && _buffers[i]) {
        CVPixelBufferRelease(_buffers[i]);
        _buffers[i] = nullptr;
      }
    }
  }

  void* retainPresented(int index) override {
    if (index < 0 || index >= _count) return nullptr;
    CVPixelBufferRef buffer = _buffers[index];
    if (buffer) CVPixelBufferRetain(buffer);
    return buffer;
  }

  void writeFrame(int index) override {
    if (index < 0 || index >= _count) return;
    CVPixelBufferRef buffer = _buffers[index];
    if (!buffer) return;

    // The application is sandboxed, so this goes to its own temporary
    // directory rather than anywhere a caller might name.
    NSString* where =
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"orbis_frame.png"];
    const char* path = where.UTF8String;

    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetWidth(buffer),
        CVPixelBufferGetHeight(buffer), 8, CVPixelBufferGetBytesPerRow(buffer),
        space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        nullptr, (const UInt8*)path, strlen(path), false);
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(destination, image, nullptr);
    const BOOL wrote = CGImageDestinationFinalize(destination);
    // The line ci_draw_frame.sh waits for. It is printed after the readback
    // rather than before, so it is evidence that a frame exists and not
    // merely that one was asked for.
    NSLog(@"[orbis] frame (%zux%zu) -> %s : %@", CVPixelBufferGetWidth(buffer),
          CVPixelBufferGetHeight(buffer), path, wrote ? @"written" : @"REFUSED");
    CFRelease(destination);
    CFRelease(url);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  }

 private:
  CVPixelBufferRef _buffers[kMaxBuffers] = {};
  int _count = 0;
};

}  // namespace

OrbisSurface* OrbisCreateSurface() { return new AppleSurface(); }
