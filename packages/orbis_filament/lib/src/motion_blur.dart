import 'dart:math' as math;

import 'graph.dart';

/// The smear a camera's shutter leaves on anything that moved while it was
/// open.
///
/// A film camera does not take an instant: the shutter is open for a length
/// of time, and whatever crosses the frame during it is recorded all along its
/// path. A renderer that draws instants draws a spinning fan as a set of
/// perfectly sharp blades, frozen — which is the single most reliable sign
/// that a moving picture was computed rather than photographed, and the reason
/// a fast pan strobes instead of flowing.
///
/// This is a setting that makes an effect pass rather than a switch on the
/// post-processing. What it needs is the scene's depth and the picture after
/// the scene was drawn, which is exactly what the render graph hands an
/// effect; putting it anywhere else would be a second way to schedule a pass.
///
/// ```dart
/// graph: const OrbisMotionBlur().graph()
/// ```
///
/// The streak is photographic: a thing crossing the picture at so many pixels
/// a second leaves a streak that many pixels long for every second the
/// shutter is open. At 1/1000 s almost nothing moves while the picture is
/// taken; at 1/30 s a car crossing the frame is a smear. Speeds are measured
/// by the renderer on the clocks things actually moved on — the camera
/// between two frames it drew, an object between two scenes its host
/// published — so the same shutter gives the same streak whatever rate either
/// runs at, and there is no frame rate to state.
///
/// Everything it needs to remember between frames — where the camera was and
/// where every object stood — is kept inside the renderer, so a host that
/// simply republishes its scene gets motion blur without tracking anything.
/// Off unless a graph asks for it, and free while off: nothing is remembered
/// and nothing is allocated.
class OrbisMotionBlur {
  const OrbisMotionBlur({
    this.shutter,
    this.maxPixels = 40,
    this.objects = true,
    this.samples = 15,
  });

  /// How long the shutter is open, in seconds, or null for the camera's own.
  ///
  /// The same number the camera's exposure is stated in, and it means the
  /// same thing. Null follows the camera, so the exposure and the blur cannot
  /// disagree — a photographer who slows the shutter to let more light in gets
  /// the blur that comes with it.
  final double? shutter;

  /// The longest a streak may be, in pixels, end to end.
  ///
  /// A clamp rather than a physical quantity. A camera whipped round in one
  /// frame would otherwise blur the whole picture into its average, and a
  /// streak longer than the neighbourhood the filter searches cannot be
  /// reconstructed properly anyway. Held between 1 and 64 by the renderer.
  final double maxPixels;

  /// Whether objects that moved blur by their own motion, or only by the
  /// camera's.
  ///
  /// On, a spinning fan blurs while the wall behind it stays sharp. Off, the
  /// only motion is the camera's, rebuilt from depth — which is right for
  /// everything that stands still, costs a pass fewer, and is what a scene
  /// with nothing moving should use.
  final bool objects;

  /// How many taps each pixel gathers along the motion near it.
  ///
  /// Odd, and held between 3 and 31 by the renderer. More is smoother and
  /// dearer; fifteen is where the jitter between taps reads as fine grain
  /// rather than as ghost copies at the streak lengths the clamp allows.
  final int samples;

  /// How long a streak is, in pixels, for something crossing the picture at
  /// [pixelsPerSecond], under a camera whose own shutter is [cameraShutter].
  ///
  /// The whole of the photographic part: speed times the time the shutter is
  /// open, held to [maxPixels].
  double streak(double pixelsPerSecond, {double cameraShutter = 1 / 125}) =>
      math.min(pixelsPerSecond * (shutter ?? cameraShutter), maxPixels);

  /// The four numbers the pass carries in its plane, in the order the
  /// renderer reads them: the shutter (nought for the camera's own), the
  /// clamp, whether objects blur (minus one for camera only, so that nought
  /// keeps meaning "the default"), and how many taps.
  List<double> get dials => [
    shutter ?? 0,
    maxPixels,
    objects ? 1 : -1,
    samples.toDouble(),
  ];

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

  /// The shortest graph with motion blur in it: the world into a target, and
  /// the blur from there onto the screen.
  OrbisRenderGraph graph() => OrbisRenderGraph(
    targets: const [OrbisTarget(name: 'frame')],
    passes: [
      const OrbisPass(name: 'world', into: 'frame'),
      pass(),
    ],
  );
}
