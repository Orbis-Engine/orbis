#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Filament rendering into CVPixelBuffers that Flutter composites.
///
/// Deliberately free of C++ in its header so the Swift plugin can see it
/// without C++ interop. Everything Filament is on the other side of the .mm.
///
/// Two buffers, not one: rendering happens on a display-link thread while
/// Flutter samples on its raster thread, and handing out the buffer being
/// drawn into would tear.
@interface OrbisRenderer : NSObject

/// Starts Filament and allocates buffers. Nil if Metal is unavailable.
- (nullable instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height;

/// Draws one frame at `time` seconds and presents it. Render thread only.
- (void)renderAtTime:(double)time;

/// Replaces everything in the scene.
///
/// Whole-scene rather than incremental, because an editor's scene is small and
/// a diff is a bug surface: a renderer that believes it knows what changed and
/// is wrong shows the last correct frame forever, which is the hardest kind of
/// wrong to notice.
///
/// `transforms` is `count` column-major 4x4 matrices; `colours` is `count`
/// linear RGB triples; `meshes` is `count` indices into `paths`, where -1
/// means the built-in cube.
///
/// Meshes named here are loaded once and kept. A scene arrives on every drag
/// of a slider, and re-reading a glTF file at that rate would make the editor
/// unusable — so the parsed asset outlives the scene that mentioned it.
- (void)setObjects:(const float *)transforms
           colours:(const float *)colours
            meshes:(const int32_t *)meshes
             paths:(NSArray<NSString *> *)paths
             count:(uint32_t)count;

/// Files named by a scene that could not be loaded, and why.
///
/// Reported back rather than logged, so an editor can say which asset is
/// missing instead of drawing a placeholder and leaving somebody to wonder.
@property(nonatomic, readonly) NSDictionary<NSString *, NSString *> *meshErrors;

/// Sets the sky's colour and how much light it casts, in lux.
///
/// The sky and the ambient are one setting because they are one thing: a
/// backdrop that lights nothing reads as a photograph behind the scene rather
/// than the sky the scene is standing under.
- (void)setSkyColour:(const float *)colour ambient:(float)ambient;

/// Sets the sun's direction, colour and illuminance in lux.
- (void)setSunDirection:(const float *)direction
                 colour:(const float *)colour
             illuminance:(float)illuminance;

/// Places the camera, looking at a point, with a vertical field of view in
/// degrees.
- (void)setCameraPosition:(const float *)position
                   target:(const float *)target
              fieldOfView:(float)fieldOfView;

/// Requests new dimensions. Safe from any thread — the work happens at the
/// top of the next frame, on the thread that owns the engine.
- (void)resizeToWidth:(uint32_t)width height:(uint32_t)height;

/// The most recently presented frame, retained, or NULL before the first one.
- (nullable CVPixelBufferRef)copyPresentedBuffer CF_RETURNS_RETAINED;

/// Tears down Filament. Idempotent; the renderer is inert afterwards.
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
