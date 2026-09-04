import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// The outline drawn in place of a control bone.
///
/// A generated rig has more bones than a viewport can show as bones, and most
/// of them are machinery. Shapes are how an animator tells the controls apart
/// at a glance: a ring is something that turns, a box is something that moves,
/// and neither looks like the stick that a bone draws as.
enum WidgetShape {
  /// A ring lying flat across the bone. The default for anything rotated.
  circle,

  /// Three rings at right angles — a control free to turn any way.
  sphere,

  /// A box. Something dragged about: a hand or foot goal.
  cube,

  /// A flat square. A plane of movement, and the usual pole vector.
  square,

  /// The stick a bone draws as, in outline. For originals kept visible.
  bone,

  /// A flat chevron pointing along the bone. Direction, and root controls.
  arrow,
}

/// The shape drawn for a control, and how it sits.
///
/// Kept beside the rig rather than on the bone: a shape is how a rig is
/// *presented*, and a renderer that never draws controls should not have to
/// carry them through skinning.
class BoneWidget {
  const BoneWidget({
    this.shape = WidgetShape.circle,
    this.size = 1,
    Vector3? offset,
    this.roll = 0,
  }) : _offset = offset;

  final WidgetShape shape;

  /// A multiplier on the bone's own length, so a widget stays in proportion
  /// when a character is rebuilt at a different scale.
  final double size;

  final Vector3? _offset;

  /// Where the shape sits along the bone, in bone lengths. Zero is the head.
  Vector3 get offset => _offset?.clone() ?? Vector3.zero();

  /// Twist about the bone's own length, in radians.
  final double roll;

  /// The shape as polylines in bone space, scaled for a bone of [boneLength].
  ///
  /// Polylines rather than triangles because a control is drawn as an outline
  /// over the character — a solid one hides the thing being animated, which is
  /// the only reason to be looking.
  List<List<Vector3>> outline(double boneLength) {
    final scale = boneLength * size;
    final twist = roll == 0
        ? null
        : Quaternion.axisAngle(Vector3(0, 1, 0), roll);
    final shift = offset * boneLength;

    return [
      for (final line in _shapeOutline(shape))
        [
          for (final point in line)
            (twist?.rotated(point) ?? point) * scale + shift,
        ],
    ];
  }

  BoneWidget copyWith({WidgetShape? shape, double? size, double? roll}) =>
      BoneWidget(
        shape: shape ?? this.shape,
        size: size ?? this.size,
        offset: _offset?.clone(),
        roll: roll ?? this.roll,
      );
}

/// Unit outlines, before a bone's length is applied.
///
/// All of them span roughly -0.5 to 0.5 across, and sit at the head rather
/// than straddling it, except [WidgetShape.bone] which runs the bone's length
/// because that is the thing it is drawing.
List<List<Vector3>> _shapeOutline(WidgetShape shape) => switch (shape) {
  WidgetShape.circle => [_ring(_Plane.xz, 0.5, 24)],
  WidgetShape.sphere => [
    _ring(_Plane.xz, 0.5, 24),
    _ring(_Plane.xy, 0.5, 24),
    _ring(_Plane.yz, 0.5, 24),
  ],
  WidgetShape.cube => _box(0.5),
  WidgetShape.square => [
    [
      Vector3(-0.5, 0, -0.5),
      Vector3(0.5, 0, -0.5),
      Vector3(0.5, 0, 0.5),
      Vector3(-0.5, 0, 0.5),
      Vector3(-0.5, 0, -0.5),
    ],
  ],
  // The octahedron a bone draws as: a narrow waist near the head, tapering to
  // a point at the tail, which is what makes a bone's direction readable.
  WidgetShape.bone => _octahedron(),
  WidgetShape.arrow => [
    [
      Vector3(-0.35, 0, -0.2),
      Vector3(0, 0, 0.45),
      Vector3(0.35, 0, -0.2),
      Vector3(0, 0, -0.05),
      Vector3(-0.35, 0, -0.2),
    ],
  ],
};

enum _Plane { xy, xz, yz }

List<Vector3> _ring(_Plane plane, double radius, int segments) => [
  for (var i = 0; i <= segments; i++)
    () {
      final angle = i / segments * math.pi * 2;
      final a = math.cos(angle) * radius;
      final b = math.sin(angle) * radius;
      return switch (plane) {
        _Plane.xy => Vector3(a, b, 0),
        _Plane.xz => Vector3(a, 0, b),
        _Plane.yz => Vector3(0, a, b),
      };
    }(),
];

List<List<Vector3>> _box(double half) {
  Vector3 corner(int x, int y, int z) => Vector3(x * half, y * half, z * half);

  return [
    // The two faces, then the four struts between them: six polylines rather
    // than twelve separate edges, which halves the vertices a viewport sends.
    [
      corner(-1, -1, -1),
      corner(1, -1, -1),
      corner(1, -1, 1),
      corner(-1, -1, 1),
      corner(-1, -1, -1),
    ],
    [
      corner(-1, 1, -1),
      corner(1, 1, -1),
      corner(1, 1, 1),
      corner(-1, 1, 1),
      corner(-1, 1, -1),
    ],
    [corner(-1, -1, -1), corner(-1, 1, -1)],
    [corner(1, -1, -1), corner(1, 1, -1)],
    [corner(1, -1, 1), corner(1, 1, 1)],
    [corner(-1, -1, 1), corner(-1, 1, 1)],
  ];
}

List<List<Vector3>> _octahedron() {
  const waist = 0.1;
  final ring = [
    Vector3(-waist, waist, 0),
    Vector3(0, waist, waist),
    Vector3(waist, waist, 0),
    Vector3(0, waist, -waist),
  ];

  return [
    [...ring, ring.first],
    for (final point in ring) [Vector3.zero(), point],
    for (final point in ring) [point, Vector3(0, 1, 0)],
  ];
}
