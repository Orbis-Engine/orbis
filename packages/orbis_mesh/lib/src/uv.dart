import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// How a face's texture coordinates fill the space they are given.
enum UvFit {
  /// The face keeps a constant texture density however big it is, so a wall
  /// twice as wide shows twice as much brick. Nearly always what is wanted
  /// for a level: two walls made at different sizes match where they meet.
  tile,

  /// The whole texture, once, across the face — squashed to whatever shape
  /// the face happens to be. For a face that *is* the picture: a sign, a
  /// poster, a screen.
  stretch,

  /// The whole texture once, keeping its proportions, with the spare room
  /// left over. What [stretch] should have been when the picture is not
  /// square and neither is the face.
  fit,
}

/// How a face gets its texture coordinates.
///
/// Two ways rather than one, which is the distinction any modelling tool ends
/// up making. **Automatic** is a rule — project the face flat, then move,
/// turn and scale that — and it survives the face being extruded, moved,
/// resized or cut, because it is recomputed from whatever the face is now.
/// **Manual** is coordinates, one a corner, and it survives nothing except
/// being the exact thing somebody drew.
///
/// Automatic is the default because a level's worth of faces edited by hand
/// is a level's worth of work that has to be redone every time a wall moves.
class FaceUv {
  const FaceUv({
    this.fit = UvFit.tile,
    Vector2? offset,
    Vector2? scale,
    this.rotation = 0,
    this.flipU = false,
    this.flipV = false,
    this.swap = false,
    this.manual,
  })  : _offset = offset,
        _scale = scale;

  /// Explicit coordinates, one a corner, in the face's own order.
  ///
  /// Non-null means this face is no longer automatic. Everything above is
  /// then ignored — kept rather than cleared, so going back to automatic
  /// returns to the settings somebody had rather than to the defaults.
  final List<Vector2>? manual;

  bool get isManual => manual != null;

  final UvFit fit;

  final Vector2? _offset;
  final Vector2? _scale;

  /// Where the texture starts. Animating it scrolls the surface, which is how
  /// a conveyor or a waterfall is usually done.
  Vector2 get offset => _offset ?? Vector2.zero();

  /// How many times it repeats. Under [UvFit.tile] this is metres per repeat
  /// inverted — two means twice as many bricks in the same wall.
  Vector2 get scale => _scale ?? Vector2(1, 1);

  /// How far the texture is turned on the face, in degrees.
  final double rotation;

  final bool flipU;
  final bool flipV;

  /// Whether the two axes are exchanged, which turns a texture on its side
  /// without turning it — for a plank that runs the other way.
  final bool swap;

  FaceUv copyWith({
    UvFit? fit,
    Vector2? offset,
    Vector2? scale,
    double? rotation,
    bool? flipU,
    bool? flipV,
    bool? swap,
    List<Vector2>? manual,
    bool clearManual = false,
  }) =>
      FaceUv(
        fit: fit ?? this.fit,
        offset: offset ?? this.offset,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
        flipU: flipU ?? this.flipU,
        flipV: flipV ?? this.flipV,
        swap: swap ?? this.swap,
        manual: clearManual ? null : (manual ?? this.manual),
      );

  /// The coordinates for a face's corners.
  ///
  /// [points] are the corners in the world, [normal] is the direction the face
  /// points. Manual coordinates are handed straight back when there are the
  /// right number of them — a face that has been cut or extruded since they
  /// were drawn has the wrong number, and falling back to the rule beats
  /// handing out coordinates that belong to corners which are no longer
  /// there.
  List<Vector2> forFace(List<Vector3> points, Vector3 normal) {
    final drawn = manual;
    if (drawn != null && drawn.length == points.length) {
      return [for (final at in drawn) at.clone()];
    }

    final axes = axesFor(normal);
    final flat = [
      for (final at in points) Vector2(at.dot(axes.u), at.dot(axes.v)),
    ];

    switch (fit) {
      case UvFit.tile:
        break;
      case UvFit.stretch:
      case UvFit.fit:
        _normalise(flat, keepShape: fit == UvFit.fit);
    }

    return [for (final at in flat) _place(at)];
  }

  /// Moves and scales coordinates so the face's own bounds fill nought to one.
  static void _normalise(List<Vector2> flat, {required bool keepShape}) {
    if (flat.isEmpty) return;

    var minU = flat.first.x;
    var maxU = flat.first.x;
    var minV = flat.first.y;
    var maxV = flat.first.y;
    for (final at in flat) {
      minU = math.min(minU, at.x);
      maxU = math.max(maxU, at.x);
      minV = math.min(minV, at.y);
      maxV = math.max(maxV, at.y);
    }

    // A face with no width in one direction is edge-on or degenerate.
    // Dividing by that is an infinity that spreads through every vertex.
    var spanU = maxU - minU;
    var spanV = maxV - minV;
    if (spanU < 1e-9) spanU = 1;
    if (spanV < 1e-9) spanV = 1;
    if (keepShape) {
      final most = math.max(spanU, spanV);
      spanU = most;
      spanV = most;
    }

    for (final at in flat) {
      at
        ..x = (at.x - minU) / spanU
        ..y = (at.y - minV) / spanV;
    }
  }

  /// Applies the turn, the scale, the flips and the offset, in that order.
  ///
  /// Order matters and this one is the least surprising: turning then scaling
  /// means the scale is along the texture's axes rather than the face's, so a
  /// texture turned forty-five degrees and stretched sideways stretches
  /// sideways in the picture rather than diagonally across it.
  Vector2 _place(Vector2 at) {
    var u = at.x;
    var v = at.y;

    if (swap) {
      final held = u;
      u = v;
      v = held;
    }
    if (rotation != 0) {
      final radians = rotation * math.pi / 180;
      final cos = math.cos(radians);
      final sin = math.sin(radians);
      final turnedU = u * cos - v * sin;
      v = u * sin + v * cos;
      u = turnedU;
    }
    u *= scale.x;
    v *= scale.y;
    if (flipU) u = -u;
    if (flipV) v = -v;
    return Vector2(u + offset.x, v + offset.y);
  }

  /// Two axes across a face, for a flat projection.
  ///
  /// Whichever world axis the face is least aligned with decides them, so the
  /// pair that comes out is never parallel to the normal — and two faces
  /// pointing the same way always get the same pair, which is what makes a
  /// texture line up across them.
  static ({Vector3 u, Vector3 v}) axesFor(Vector3 normal) {
    final away = normal.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
    final u = normal.cross(away).normalized();
    return (u: u, v: normal.cross(u).normalized());
  }

  Map<String, Object?> toJson() => {
        if (fit != UvFit.tile) 'fit': fit.name,
        if (offset.x != 0 || offset.y != 0) 'offset': [offset.x, offset.y],
        if (scale.x != 1 || scale.y != 1) 'scale': [scale.x, scale.y],
        if (rotation != 0) 'turn': rotation,
        if (flipU) 'flipU': true,
        if (flipV) 'flipV': true,
        if (swap) 'swap': true,
        if (manual != null)
          'uvs': [
            for (final at in manual!) ...[at.x, at.y],
          ],
      };

  static FaceUv? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();

    Vector2? pair(String key) {
      final raw = map[key];
      if (raw is! List || raw.length < 2) return null;
      final x = raw[0], y = raw[1];
      if (x is! num || y is! num) return null;
      return Vector2(x.toDouble(), y.toDouble());
    }

    List<Vector2>? drawn;
    final raw = map['uvs'];
    if (raw is List && raw.length.isEven) {
      drawn = [
        for (var i = 0; i + 1 < raw.length; i += 2)
          if (raw[i] is num && raw[i + 1] is num)
            Vector2((raw[i]! as num).toDouble(), (raw[i + 1]! as num).toDouble()),
      ];
    }

    return FaceUv(
      fit: UvFit.values.firstWhere(
        (one) => one.name == map['fit'],
        orElse: () => UvFit.tile,
      ),
      offset: pair('offset'),
      scale: pair('scale'),
      rotation: map['turn'] is num ? (map['turn']! as num).toDouble() : 0,
      flipU: map['flipU'] == true,
      flipV: map['flipV'] == true,
      swap: map['swap'] == true,
      manual: drawn,
    );
  }
}
