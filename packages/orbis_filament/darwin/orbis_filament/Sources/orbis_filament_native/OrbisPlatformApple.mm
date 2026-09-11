#include "OrbisPlatform.h"

// The platform layer's answers on macOS and iOS: the frameworks the renderer
// has always used, moved here from OrbisRenderer.mm unchanged so that what an
// Apple build does is exactly what it did before the renderer was portable.

#if ORBIS_PLATFORM_APPLE

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

#include <filament/Engine.h>
#include <filament/Texture.h>

/// What the end-of-file observer needs in order to loop a video.
///
/// Its own object rather than the decoder, so the observer's block can hold
/// it without holding the decoder: the block runs on the main queue and may
/// arrive after the decoder has gone.
@interface OrbisVideoLoop : NSObject
@property(nonatomic, weak) AVPlayer *player;
@property(nonatomic) BOOL looping;
@property(nonatomic) BOOL playing;
@property(nonatomic) float rate;
@end

@implementation OrbisVideoLoop
@end

namespace orbis {

void log(const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  const std::string line = vformat(format, arguments);
  va_end(arguments);
  NSString *text = [NSString stringWithUTF8String:line.c_str()];
  // Bytes that are not UTF-8 — a path off a disk that never promised it —
  // are still worth seeing, so they go through as Latin-1 rather than as
  // nothing at all.
  if (text == nil) {
    text = [NSString stringWithCString:line.c_str()
                              encoding:NSISOLatin1StringEncoding];
  }
  NSLog(@"%@", text);
}

double now() { return CFAbsoluteTimeGetCurrent(); }

void parallelFor(size_t count, const std::function<void(size_t)> &body) {
  if (count == 0) return;
  // The block captures a pointer to the function, not the function: a
  // captured std::function is copied into the block, once per block.
  const std::function<void(size_t)> *run = &body;
  dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                 ^(size_t i) { (*run)(i); });
}

/// ImageIO and Core Graphics, which is the one piece of decals that another
/// platform writes again: every other port has its own way to read a PNG. The
/// draw into the bitmap resamples to the square on the way, and premultiplies,
/// which is what the shader's blend expects. Empty on failure.
std::vector<uint8_t> readPicture(const std::string &path, uint32_t side) {
  std::vector<uint8_t> pixels;
  NSString *native = [NSString stringWithUTF8String:path.c_str()];
  if (native == nil) return pixels;
  NSURL *url = [NSURL fileURLWithPath:native];
  CGImageSourceRef source =
      CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
  if (source == nullptr) return pixels;
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  CFRelease(source);
  if (image == nullptr) return pixels;

  pixels.assign(size_t(side) * side * 4, 0);
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(
      pixels.data(), side, side, 8, size_t(side) * 4, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (context != nullptr) {
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    // Row nought of the bitmap is the top of the picture, and row nought of
    // the texture is v nought, which is the far edge of the box's z — so the
    // top of a poster is at the top of the wall it is thrown onto.
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), image);
    CGContextRelease(context);
  } else {
    pixels.clear();
  }
  CGImageRelease(image);
  return pixels;
}

namespace {

/// AVFoundation, decoding into IOSurface-backed buffers that Filament's Metal
/// backend takes as an external image without a copy.
///
/// The frame never becomes an ordinary texture. It stays the buffer the
/// decoder wrote and is handed to the GPU where it lies, which is the whole
/// reason a screen in the scene costs about as much as a flat colour.
class AppleVideoDecoder final : public VideoDecoder {
 public:
  ~AppleVideoDecoder() override {
    stop();
    // The buffer last on the GPU, released after the texture that showed it
    // has been destroyed — which the renderer does before destroying this.
    if (_showing != nullptr) {
      CVPixelBufferRelease(_showing);
      _showing = nullptr;
    }
  }

  /// The pixel format is asked for explicitly: Filament's external images
  /// take 32-bit BGRA or biplanar YUV and nothing else, and a decoder left to
  /// choose will happily hand back something neither of them.
  bool open(const std::string &path) override {
    NSString *text = [NSString stringWithUTF8String:path.c_str()];
    if (text == nil) return false;
    NSURL *url = [text hasPrefix:@"http"] ? [NSURL URLWithString:text]
                                          : [NSURL fileURLWithPath:text];
    if (url == nil) return false;

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    _output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
      (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (id)kCVPixelBufferMetalCompatibilityKey : @YES,
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    }];
    [item addOutput:_output];

    _player = [AVPlayer playerWithPlayerItem:item];
    // Without this the player pauses itself the moment a buffer runs short,
    // and a file on the local disk stutters for no reason a viewer can see.
    _player.automaticallyWaitsToMinimizeStalling = NO;

    _loop = [[OrbisVideoLoop alloc] init];
    _loop.player = _player;
    OrbisVideoLoop *loop = _loop;
    _endObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                  // Looping is done here rather than with a queue player,
                  // because a queue restarts by loading the file again and
                  // the gap that leaves is exactly what a loop is meant to
                  // hide.
                  AVPlayer *player = loop.player;
                  if (player == nil || !loop.looping) return;
                  [player seekToTime:kCMTimeZero
                      toleranceBefore:kCMTimeZero
                       toleranceAfter:kCMTimeZero];
                  if (loop.playing) [player playImmediatelyAtRate:loop.rate];
                }];
    return true;
  }

  void seek(double seconds) override {
    [_player seekToTime:CMTimeMakeWithSeconds(seconds, 600)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero];
  }

  void setVolume(float volume) override { _player.volume = volume; }

  void play(float rate) override {
    _loop.playing = YES;
    _loop.rate = rate;
    [_player playImmediatelyAtRate:rate];
  }

  void pause() override {
    _loop.playing = NO;
    [_player pause];
  }

  void setLooping(bool looping) override { _loop.looping = looping; }

  /// A video that has not advanced hands back nothing and costs a single
  /// comparison; the picture already on the texture stays.
  bool pump(filament::Engine &engine, filament::Texture *texture) override {
    if (_output == nil || texture == nullptr) return false;

    const CMTime at = [_output itemTimeForHostTime:CACurrentMediaTime()];
    if (![_output hasNewPixelBufferForItemTime:at]) return false;
    CVPixelBufferRef buffer = [_output copyPixelBufferForItemTime:at
                                               itemTimeForDisplay:nullptr];
    if (buffer == nullptr) return false;

    texture->setExternalImage(engine, buffer);
    // The one just replaced, not the one just set: the new buffer is what the
    // next draw reads, and releasing it here would pull the picture out from
    // under a frame that has not happened yet.
    if (_showing != nullptr) CVPixelBufferRelease(_showing);
    _showing = buffer;
    return true;
  }

  void stop() override {
    if (_endObserver != nil) {
      [[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
      _endObserver = nil;
    }
    if (_player != nil) {
      [_player pause];
      _player = nil;
    }
    _output = nil;
  }

 private:
  AVPlayer *_player = nil;
  AVPlayerItemVideoOutput *_output = nil;
  OrbisVideoLoop *_loop = nil;
  id _endObserver = nil;

  /// The buffer currently on the GPU. Held until the next one replaces it:
  /// releasing it at the end of the frame that showed it would pull the
  /// picture out from under a draw that has not happened yet.
  CVPixelBufferRef _showing = nullptr;
};

}  // namespace

std::unique_ptr<VideoDecoder> createVideoDecoder() {
  return std::make_unique<AppleVideoDecoder>();
}

}  // namespace orbis

#endif  // ORBIS_PLATFORM_APPLE
