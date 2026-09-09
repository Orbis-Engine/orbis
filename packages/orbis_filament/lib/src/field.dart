import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// Light stored in the world rather than on the screen.
///
/// A screen-space bounce only knows what is in frame, so turning away from a
/// red wall takes its bounce with it and the room changes colour as the camera
/// moves. A field fixes that by keeping the answer somewhere the camera cannot
/// move: a lattice of probes standing in the world, each holding what light
/// arrives at it from every direction, built up over many frames and read by
/// every surface near it.
///
/// That is the whole difference, and it is worth being precise about. The
/// bounce is *how much light there is here, worked out now*. The field is
/// *how much light there is at that point in the room*, worked out over the
/// last second or two and still there when nothing that lit it is on screen.
///
/// Probes are filled by marching the depth buffer outward from each probe,
/// so the light in the field still had to be on screen at some point — but
/// only *at some point*, not now. What the field adds is memory.
/// {@category Lighting and environment}
class OrbisField {
  OrbisField({
    this.enabled = false,
    Vector3? origin,
    Vector3? spacing,
    Vector3? counts,
    this.from = 'frame',
    this.intensity = 1,
    this.retention = 0.94,
    this.bias = 0.4,
  }) : origin = origin ?? Vector3.zero(),
       // Two metres and a lattice big enough for a room. Light cannot vary
       // faster than the probes are spaced, so this is the scale at which a
       // field says anything at all.
       spacing = spacing ?? Vector3(2, 2, 2),
       counts = counts ?? Vector3(8, 4, 8);

  /// Nothing: the scene is lit as it was before there was a field.
  static final OrbisField none = OrbisField();

  final bool enabled;

  /// Where the probe at the corner of the lattice stands.
  final Vector3 origin;

  /// How far apart the probes are, in metres, along each axis.
  ///
  /// The single most consequential number here. Light cannot vary faster than
  /// the probes are spaced, so a two-metre spacing cannot put a shadow under a
  /// chair. Close spacing costs probes cubed, which is why a field is usually
  /// coarse and the direct light does the fine detail.
  final Vector3 spacing;

  /// How many probes along each axis.
  final Vector3 counts;

  /// The target the probes are filled from.
  ///
  /// A field is built by reading the picture the scene has already drawn, so
  /// there has to be a picture to read: a graph whose scene pass writes a
  /// target, and this is that target's name. A field that names one which does
  /// not exist is reported rather than quietly staying dark.
  final String from;

  /// How much of the stored light reaches surfaces.
  final double intensity;

  /// How much of a probe's stored value survives each frame.
  ///
  /// High is stable and slow: a light switched on takes a moment to arrive.
  /// Low is responsive and noisy. Ninety-four hundredths settles in about
  /// half a second at sixty frames a second, which is the usual compromise.
  final double retention;

  /// How far off a surface a probe is sampled from, as a fraction of the
  /// probe spacing.
  ///
  /// Sampling exactly at the surface makes a surface find itself in its own
  /// probes and light itself, which reads as a glow along every wall. Pushing
  /// the sample along the normal is what stops it.
  final double bias;

  /// How many probes a field may hold, past which it is reported.
  static const int maxProbes = 1024;

  /// How many floats a field occupies.
  static const int stride = 14;

  Float32List get packed {
    final out = Float32List(stride);
    out[0] = enabled ? 1 : 0;
    out[1] = origin.x;
    out[2] = origin.y;
    out[3] = origin.z;
    out[4] = spacing.x;
    out[5] = spacing.y;
    out[6] = spacing.z;
    out[7] = counts.x;
    out[8] = counts.y;
    out[9] = counts.z;
    out[10] = intensity;
    out[11] = retention;
    out[12] = bias;
    out[13] = 0;
    return out;
  }

  OrbisField copyWith({
    bool? enabled,
    Vector3? origin,
    Vector3? spacing,
    Vector3? counts,
    String? from,
    double? intensity,
    double? retention,
    double? bias,
  }) => OrbisField(
    enabled: enabled ?? this.enabled,
    origin: origin ?? this.origin,
    spacing: spacing ?? this.spacing,
    counts: counts ?? this.counts,
    from: from ?? this.from,
    intensity: intensity ?? this.intensity,
    retention: retention ?? this.retention,
    bias: bias ?? this.bias,
  );

  /// How many probes this field asks for.
  int get probeCount => (counts.x.round() * counts.y.round() * counts.z.round())
      .clamp(0, 1 << 20);
}
