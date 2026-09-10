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
/// `morphCounts` is `count` shape counts, and `morphWeights` holds them all
/// end to end in the same order — a face rig has dozens of shapes and a crate
/// has none, so a fixed width per object would be wrong for both.
- (void)applyObjects:(const int64_t *)keys
          transforms:(const float *)transforms
             colours:(const float *)colours
              meshes:(const int32_t *)meshes
               flags:(const int32_t *)flags
           materials:(const int32_t *)materials
         morphCounts:(const int32_t *)morphCounts
        morphWeights:(const float *)morphWeights
               paths:(NSArray<NSString *> *)paths
               count:(uint32_t)count;

/// States what every material in the scene is made of.
///
/// Published whole each frame like everything else, and keyed the same way:
/// a material keeps its instance for as long as its key is mentioned, and
/// only the numbers that moved are written. Objects point at these by their
/// position in this list, so this has to be applied before they are.
- (void)applyMaterials:(const int64_t *)keys
                 flags:(const int32_t *)flags
                params:(const float *)params
                  maps:(const int32_t *)maps
          texturePaths:(NSArray<NSString *> *)texturePaths
           textureSrgb:(const int32_t *)textureSrgb
                videos:(const int32_t *)videos
                 count:(uint32_t)count;

/// States how much of the frame's work actually happens.
///
/// One pipeline with dials rather than a choice of pipelines: the order of
/// the passes is fixed, and what this changes is how much of each of them
/// there is. Compared before anything is applied, because half of it
/// reallocates a render target or a shadow map.
- (void)setPipeline:(const float *)params count:(NSUInteger)count;

/// States what every video in the scene is doing.
///
/// A description rather than a command, like everything else: what arrives is
/// the state a video should be in, and the renderer works out what to do
/// about it. Saying "playing, at this rate, from this file" sixty times a
/// second costs one comparison per video. The exception is seeking, which is
/// an event and not a state, so it is reconciled by a token — the target only
/// takes effect when the token beside it has moved.
///
/// Applied before materials, because a screen points at one of these.
- (void)applyVideos:(const int64_t *)keys
              flags:(const int32_t *)flags
             params:(const float *)params
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

/// States what is painted onto the scene's surfaces.
///
/// `params` is `count` decals of twenty-two floats each — the layout is
/// written out in OrbisDecals.h. `images` is `count` indices into `paths`,
/// -1 for a decal that is a tint with no picture. Past the budget of
/// thirty-two, the rest are reported rather than painted.
- (void)applyDecals:(const float *)params
             images:(const int32_t *)images
              paths:(NSArray<NSString *> *)paths
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

/// Everything done to the image after the scene is drawn.
///
/// One flat array of numbers rather than forty named calls: this arrives on
/// every frame, and the renderer only touches the view when something in it
/// has actually changed — Filament rebuilds internal state when an option
/// struct is set, and setting the same bloom sixty times a second is sixty
/// rebuilds to say nothing happened.
- (void)setPostProcess:(const float *)params count:(NSUInteger)count;

/// The reflections the scene takes of itself.
///
/// `params` is seven floats a probe: where it is captured from, how far its
/// influence reaches in metres, the size of one face of the cube, a version,
/// and which layers the capture draws.
///
/// A capture is six renders of the whole scene and a filter over the result,
/// so it happens when a probe is first seen and then only when its version
/// changes. Nothing else can decide that: the renderer cannot tell that the
/// thing which moved was the thing that mattered.
///
/// Whichever probe contains the camera lights the scene, in place of the
/// environment. None containing it leaves the environment as it was.
- (void)applyProbes:(const int64_t *)keys
             params:(const float *)params
              count:(uint32_t)count;
/// The light the scene keeps in the world rather than on the screen.
///
/// `params` is fourteen floats: whether it is on, where the corner probe
/// stands, the metres between probes, how many there are along each axis, how
/// much of it reaches surfaces, how much of a probe survives each frame, and
/// how far off a surface it is sampled from. `from` names the target the
/// probes are filled by reading.
- (void)applyField:(const float *)params from:(NSString *)from;

/// Sets the place the scene is standing in: the light it casts, and the
/// backdrop it is seen against.
///
/// `radiance` is a prefiltered cubemap as `cmgen` writes it — the mip chain is
/// the reflection and the spherical harmonics in its metadata are the diffuse
/// — and `skybox` is the backdrop. Either may be empty. `params` is four
/// floats: how bright it is in lux, how far it is turned about the vertical in
/// radians, whether the backdrop is drawn, and one spare.
///
/// Loaded once per path and kept, because a scene arrives on every frame and
/// reading a cubemap at that rate is not a thing to do twice.
///
/// While one is set it overrules the flat ambient: a scene lit by a photograph
/// of a room *and* by an even grey wash is lit twice, and the wash is the half
/// that flattens it.
- (void)setEnvironmentRadiance:(NSString *)radiance
                        skybox:(NSString *)skybox
                        params:(const float *)params;

/// States how the frame is put together: which passes there are, what they
/// draw into, and which layers of the scene each one draws.
///
/// One pass into the frame is the whole of an ordinary frame and is what
/// arrives when nobody has said otherwise, so a host that has never heard of
/// a graph gets exactly the frame this drew before graphs existed.
///
/// `passes` is `count` rows of twelve floats: the kind, the target it writes
/// as an index into `targets` or -1 for the frame, its layer mask, whether it
/// clears, four target indices it reads, and a plane to reflect in. `targets`
/// is `targetCount` rows of six: width, height, scale, whether it keeps
/// depth, whether it keeps colour, and one spare.
///
/// Already in the order they run: the ordering falls out of what each pass
/// reads, and that is worked out where the graph is written rather than here.
/// A renderer that re-derived it would be a second implementation of the same
/// rule, and the two would disagree the first time either changed.
///
/// Applied before materials, because a material may sample what a pass drew.
- (void)setRenderGraph:(const float *)passes
                 count:(uint32_t)count
               targets:(const float *)targets
           targetCount:(uint32_t)targetCount
                 names:(NSArray<NSString *> *)names;

/// What each pass of the last frame cost, in milliseconds, and how many
/// renderables it submitted — two numbers per pass, in the order they ran.
///
/// Empty before the first frame. The names are not here: they are on the
/// other side already, and sending the same strings sixty times a second to
/// label numbers that arrive in a known order is work for nothing.
@property(nonatomic, readonly) NSArray<NSNumber *> *passTimings;

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

/// What recent frames cost this renderer on the CPU, in milliseconds.
///
/// The GPU number says how expensive the picture is to draw; this says how
/// expensive the renderer is to drive. A change that leaves the picture
/// identical can double this without moving the other at all, which is why
/// both are reported.
- (double)cpuMilliseconds;

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
