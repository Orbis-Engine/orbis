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

/// States what the scene contains.
///
/// A complete description every time, because a message that says everything
/// cannot go stale: there is no state on the wire to fall out of step, and no
/// way to believe nothing changed when something did — which looks exactly
/// like a frozen viewport.
///
/// Complete on the way in, incremental on the way through. `keys` identify the
/// objects, so this works out what actually changed and pays for that alone: a
/// moved object is a transform written, not an entity destroyed and rebuilt.
/// It matters because a scene arrives on every frame of a drag, and rebuilding
/// a scene sixty times a second is most of a frame's budget spent on work that
/// was already done.
///
/// `transforms` is `count` column-major 4x4 matrices; `colours` is `count`
/// linear RGB triples; `meshes` is `count` indices into `paths`, where -1
/// means the built-in cube; `flags` is `count` bitfields — 1 casts shadows,
/// 2 receives them, 4 is drawn at all.
///
/// Meshes named here are loaded once and kept, and the instances made from
/// them are pooled rather than destroyed: a scene arrives on every drag of a
/// slider, and re-reading a glTF file at that rate would make an editor
/// unusable.
- (void)applyObjects:(const int64_t *)keys
          transforms:(const float *)transforms
             colours:(const float *)colours
              meshes:(const int32_t *)meshes
               flags:(const int32_t *)flags
               paths:(NSArray<NSString *> *)paths
               count:(uint32_t)count;

/// States what is lighting the scene.
///
/// Keyed and reconciled the same way objects are, and for the same reason: a
/// light being dragged is a position written rather than a light destroyed and
/// remade, which would drop its shadow map and flicker.
///
/// `kinds` is one per light — 0 directional, 1 point, 2 spot. `params` is
/// eighteen floats each: colour, intensity, position, direction, falloff
/// radius, inner and outer cone in radians, the body's angular radius in
/// degrees, the source radius in metres, and the size and falloff of the halo
/// around the disk a directional light draws in the sky. `flags` bit 1 casts
/// shadows.
- (void)applyLights:(const int64_t *)keys
              kinds:(const int32_t *)kinds
              flags:(const int32_t *)flags
             params:(const float *)params
              count:(uint32_t)count;

/// Sets the air the scene is seen through.
///
/// `params` is sixteen floats: colour, density, distance, cut-off distance,
/// maximum opacity, height, height falloff, how much structure the air has,
/// the wind across the ground in metres a second, how large its features are,
/// how thick the bank is in metres, and two spare.
///
/// Structure is what turns fog into weather. Even fog is right for distance
/// and cannot look like anything in particular; above zero, a stack of noise
/// sheets is drawn through the same air, and that is what gives it the shape
/// of cloud lying in a valley. Disabled skips both.
- (void)setFogEnabled:(BOOL)enabled params:(const float *)params;

/// What recent frames cost the GPU, in milliseconds, or zero when the backend
/// has not reported any yet.
///
/// The median of what Filament's own frame history holds, because a mean is
/// dragged about by the one frame in thirty that hit a hitch — and what
/// anybody wants to know is what a frame usually costs.
///
/// This rather than how often a frame is presented: presentation is the
/// display's business, and a renderer with twice the headroom it needs looks
/// exactly the same there.
- (double)gpuMilliseconds;

/// Whether anything is holding population buffers, so a scene that has just
/// dropped its last one still gets the call that clears them.
@property(nonatomic, readonly) BOOL hasPopulations;

/// States the scene's populations: many copies of one mesh, drawn in one call.
///
/// Everything travels as parallel arrays of `count` entries — the key each
/// population is kept against, how many members it has, which mesh, its flags,
/// its revision and its bounding box. `changed` names the populations whose
/// `transforms` and `colours` are actually present, packed end to end in the
/// order they are named.
///
/// The split is the whole point. A hundred thousand transforms is six
/// megabytes, and a scene that is standing still sends none of it: the
/// renderer keeps the buffers it built and draws them again.
- (void)applyPopulations:(const int32_t *)keys
                  counts:(const int32_t *)counts
                  meshes:(const int32_t *)meshes
                   flags:(const int32_t *)flags
               revisions:(const int32_t *)revisions
                  ranges:(const float *)ranges
                  bounds:(const float *)bounds
                   paths:(NSArray<NSString *> *)paths
                 changed:(const int32_t *)changed
            changedCount:(uint32_t)changedCount
              transforms:(const float *)transforms
                 colours:(const float *)colours
                   count:(uint32_t)count;

/// Sets the sky: its gradient, the body in it, its cloud, and its lightning.
///
/// `params` is thirty-one floats, in the order `OrbisSky` packs them: the
/// zenith and horizon colours, the body's direction, colour, angular size and
/// whether to draw it, then the cloud's own sky-light, cover, base altitude,
/// depth, feature size, density, billow and extinction, the wind carrying it,
/// and finally the strike — how bright, which way, and which strike.
///
/// All of it is one shader on one dome because all of it is one question:
/// what is along this view ray. Answering it once is what lets the cloud
/// cover the sun, the sun light the cloud, and a strike light both.
- (void)setSkyEnabled:(BOOL)enabled params:(const float *)params;

/// Sets the rain or snow falling through the scene.
///
/// `params` is twelve floats: colour, how much of it there is, how fast it
/// falls in metres a second, the wind carrying it, drops per metre, how far a
/// drop is smeared along its fall, how much of the field is drop rather than
/// air, and two spare.
///
/// Rain and snow are the same curtain at different settings: what separates
/// them is how far a drop travels while the shutter is open.
- (void)setPrecipitationEnabled:(BOOL)enabled params:(const float *)params;

/// What a scene asked for that could not be given, and why.
///
/// Reported back rather than logged, so an editor can name the asset it could
/// not find or say which light it had to drop, instead of drawing something
/// quietly wrong and leaving somebody to wonder.
@property(nonatomic, readonly) NSDictionary<NSString *, NSString *> *notes;

/// Sets the sky's colour, how much light it casts in lux, and whether the
/// disk of whatever is lighting the scene is drawn in it.
///
/// The sky and the ambient are one setting because they are one thing: a
/// backdrop that lights nothing reads as a photograph behind the scene rather
/// than the sky the scene is standing under.
///
/// A colour is written into the sky that is already there. Only a change to
/// the disk builds a new one, because that is fixed when a sky is made — and
/// a day cycle moves the colour on every single frame.
- (void)setSkyColour:(const float *)colour
             ambient:(float)ambient
            showBody:(BOOL)showBody;

/// Places the camera, looking at a point, with a vertical field of view in
/// degrees.
/// States where the camera is, and when the application reckons that was.
///
/// Recorded rather than applied. The picture is drawn on the display's clock
/// and told things on the application's, and the two are neither the same rate
/// nor in step — so where the camera is at the moment of drawing is worked out
/// then, from the last two things it was told. `at` is what makes that
/// possible: the speed comes from the application's own seconds rather than
/// from when the messages happened to arrive.
- (void)setCameraPosition:(const float *)position
                   target:(const float *)target
              fieldOfView:(float)fieldOfView
             orthographic:(BOOL)orthographic
               viewHeight:(float)viewHeight
                       at:(double)at;

/// Sets how much light reaches the camera: the f-number, the shutter speed in
/// seconds, and the sensitivity in ISO.
///
/// Not decoration. A day is about seventeen stops brighter than a night lit by
/// the moon, and on one fixed exposure either the night is black or the day is
/// white. Every camera and every eye answers this the same way, and so does
/// this one.
- (void)setExposure:(float)aperture
            shutter:(float)shutter
        sensitivity:(float)sensitivity;

/// Requests new dimensions. Safe from any thread — the work happens at the
/// top of the next frame, on the thread that owns the engine.
- (void)resizeToWidth:(uint32_t)width height:(uint32_t)height;

/// The most recently presented frame, retained, or NULL before the first one.
- (nullable CVPixelBufferRef)copyPresentedBuffer CF_RETURNS_RETAINED;

/// Tears down Filament. Idempotent; the renderer is inert afterwards.
- (void)dispose;

@end

NS_ASSUME_NONNULL_END
