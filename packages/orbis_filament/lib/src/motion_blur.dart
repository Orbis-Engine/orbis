import 'graph.dart';

/// The smear a camera's shutter leaves on anything that moved while it was
/// open.
///
/// A film camera does not take an instant: the shutter is open for a length
/// of time, and whatever crosses the frame during it is recorded all along its
/// path. A renderer that draws instants draws a spinning fan as a set of
/// perfectly sharp blades, frozen — which is the single most reliable sign
/// that a moving picture was computed rather than photographed, and the reason
/// a fast pan at thirty frames a second strobes instead of flowing.
///
/// This is a setting that makes an effect pass rather than a switch on the
/// post-processing. What it needs is the scene's depth and the frame after
/// the scene was drawn, which is exactly what the render graph hands an
/// effect; putting it anywhere else would be a second way to schedule a pass.
///
/// ```dart
/// graph: OrbisMotionBlur(shutter: 1 / 60).graph()
/// ```
///
/// Everything it needs to remember between frames — where the camera was
/// and where every object stood — is kept inside the renderer, so a host that
/// simply republishes its scene gets motion blur without tracking anything.
class OrbisMotionBlur {
  const OrbisMotionBlur({
    this.shutter,
    this.maxPixels = 48,
    this.objects = true,
    this.frameRate = 60,
  });

  /// How long the shutter is open, in seconds, or null for the camera's own.
  ///
  /// The same number the camera's exposure is stated in, and it means the
  /// same thing: at 1/1000 s almost nothing moves while the picture is taken,
  /// and at 1/30 s a car crossing the frame is a streak. Null follows the
  /// camera, so the exposure and the blur cannot disagree — a photographer
  /// who slows the shutter to let more light in gets the blur that comes
  /// with it.
  final double? shutter;

  /// The longest a streak may be, in pixels, end to end.
  ///
  /// A clamp rather than a physical quantity. A camera whipped round in one
  /// frame would otherwise blur the whole picture into its average, and a
  /// streak longer than the neighbourhood the filter searches cannot be
  /// reconstructed properly anyway. Held to 64 by the renderer.
  final double maxPixels;

  /// Whether objects that moved blur by their own motion, or only by the
  /// camera's.
  ///
  /// On, a spinning fan blurs while the wall behind it stays sharp. Off, the
  /// only motion is the camera's, reconstructed from depth — which is right
  /// for everything that stands still, costs one pass fewer, and is what a
  /// scene with nothing moving should use.
  final bool objects;

  /// How many frames a second the scene is drawn and published at.
  ///
  /// Motion is measured as how far things moved since the last frame, and
  /// the streak is that distance scaled by how much of a frame the shutter
  /// was open for: shutter × frame rate. At sixty frames a second a 1/60 s
  /// shutter is open the whole frame, and the streak is exactly the distance
  /// travelled.
  final double frameRate;

  /// The fraction of the distance travelled in one frame that the shutter
  /// records, for a given camera shutter when [shutter] is null.
  double openFor(double cameraShutter) => (shutter ?? cameraShutter) * frameRate;

  /// The four numbers the pass carries in its plane: shutter (nought for the
  /// camera's own), the clamp, whether objects blur (minus one for camera
  /// only, so that nought keeps meaning "the default"), and the frame rate.
  List<double> get dials => [shutter ?? 0, maxPixels, objects ? 1 : -1, frameRate];

  /// The pass that blurs [reads] — a target that kept its depth — into
  /// [into], or into the frame.
  OrbisPass pass({
    String name = 'motion blur',
    String reads = 'frame',
    String? into,
  }) => OrbisPass(
    name: name,
    kind: OrbisPassKind.effect,
    effect: OrbisEffect.motionBlur,
    reads: [reads],
    into: into,
    plane: dials,
  );

  /// The shortest graph with motion blur in it: the world into a target,
  /// and the blur from there onto the screen.
  OrbisRenderGraph graph() => OrbisRenderGraph(
    targets: const [OrbisTarget(name: 'frame')],
    passes: [const OrbisPass(name: 'world', into: 'frame'), pass()],
  );
}
