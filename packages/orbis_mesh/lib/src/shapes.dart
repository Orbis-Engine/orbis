import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';

/// The shapes somebody starts from.
///
/// Parametric on purpose: a box is a width, a height and a depth until
/// somebody pulls a face off it, and until then changing its size should
/// change its size rather than move eight corners. What makes it worth having
/// an editor at all is that the moment they do pull a face, it stops being a
/// box and becomes geometry — and nothing here has to know about that.
enum ShapeKind {
  plane('Plane'),
  cube('Cube'),
  cylinder('Cylinder'),
  cone('Cone'),
  sphere('Sphere'),
  stairs('Stairs'),
  arch('Arch');

  const ShapeKind(this.label);

  final String label;

  static ShapeKind? named(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// What a shape is made of, before it is made.
///
/// One class for every kind rather than one per kind: the fields that mean
/// nothing to a plane cost a few bytes, and the alternative is a sealed
/// hierarchy that every caller has to switch over to read a width.
class Shape {
  const Shape({
    required this.kind,
    this.width = 1,
    this.height = 1,
    this.depth = 1,
    this.sides = 16,
    this.rings = 8,
    this.steps = 8,
    this.capped = true,
  });

  final ShapeKind kind;

  final double width;
  final double height;
  final double depth;

  /// How many faces go round a cylinder, a cone or a sphere.
  final int sides;

  /// How many go from top to bottom of a sphere or an arch.
  final int rings;

  /// How many steps a staircase has.
  final int steps;

  /// Whether a cylinder has ends on it. Off for a tube or a length of pipe,
  /// which is the shape a wall of them is made from.
  final bool capped;

  Shape copyWith({
    ShapeKind? kind,
    double? width,
    double? height,
    double? depth,
    int? sides,
    int? rings,
    int? steps,
    bool? capped,
  }) =>
      Shape(
        kind: kind ?? this.kind,
        width: width ?? this.width,
        height: height ?? this.height,
        depth: depth ?? this.depth,
        sides: sides ?? this.sides,
        rings: rings ?? this.rings,
        steps: steps ?? this.steps,
        capped: capped ?? this.capped,
      );

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'width': width,
        'height': height,
        'depth': depth,
        'sides': sides,
        'rings': rings,
        'steps': steps,
        'capped': capped,
      };

  static Shape? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();
    final kind = ShapeKind.named(map['kind']);
    if (kind == null) return null;

    double number(String key, double fallback) =>
        map[key] is num ? (map[key]! as num).toDouble() : fallback;
    int count(String key, int fallback) =>
        map[key] is int ? map[key]! as int : fallback;

    return Shape(
      kind: kind,
      width: number('width', 1),
      height: number('height', 1),
      depth: number('depth', 1),
      sides: count('sides', 16),
      rings: count('rings', 8),
      steps: count('steps', 8),
      capped: map['capped'] != false,
    );
  }

  /// The geometry this shape describes.
  ///
  /// Centred on the origin and standing on the ground, which is where somebody
  /// putting a box in a scene expects it: a shape whose middle is its centre
  /// sinks half into the floor the moment it is placed.
  Mesh build() {
    // Clamped rather than trusted. A cylinder with two sides is a flat sheet
    // and one with two thousand is a frame nobody asked to lose; both are what
    // a dragged slider produces on the way to the number somebody wanted.
    final around = sides.clamp(3, 256);
    final up = rings.clamp(2, 128);
    final flights = steps.clamp(1, 128);

    return switch (kind) {
      ShapeKind.plane => _plane(),
      ShapeKind.cube => _cube(),
      ShapeKind.cylinder => _cylinder(around),
      ShapeKind.cone => _cone(around),
      ShapeKind.sphere => _sphere(around, up),
      ShapeKind.stairs => _stairs(flights),
      ShapeKind.arch => _arch(around),
    };
  }

  Mesh _plane() {
    final x = width / 2;
    final z = depth / 2;
    final mesh = Mesh(positions: [
      Vector3(-x, 0, -z),
      Vector3(x, 0, -z),
      Vector3(x, 0, z),
      Vector3(-x, 0, z),
    ]);
    // Wound so it faces up, which is the only way a floor is any use.
    mesh.addFace([0, 3, 2, 1]);
    return mesh;
  }

  Mesh _cube() {
    final x = width / 2;
    final z = depth / 2;
    final mesh = Mesh(positions: [
      Vector3(-x, 0, -z),
      Vector3(x, 0, -z),
      Vector3(x, 0, z),
      Vector3(-x, 0, z),
      Vector3(-x, height, -z),
      Vector3(x, height, -z),
      Vector3(x, height, z),
      Vector3(-x, height, z),
    ]);

    // Every one wound counter-clockwise seen from outside, which is what
    // decides whether a face is there or whether the shape has a hole in it.
    mesh
      ..addFace([0, 1, 2, 3]) // bottom, facing down
      ..addFace([4, 7, 6, 5]) // top
      ..addFace([0, 4, 5, 1]) // back
      ..addFace([3, 2, 6, 7]) // front
      ..addFace([1, 5, 6, 2]) // right
      ..addFace([0, 3, 7, 4]); // left
    return mesh;
  }

  Mesh _cylinder(int around) {
    final mesh = Mesh();
    final radiusX = width / 2;
    final radiusZ = depth / 2;

    for (var i = 0; i < around; i++) {
      final angle = i / around * math.pi * 2;
      final x = math.cos(angle) * radiusX;
      final z = math.sin(angle) * radiusZ;
      mesh
        ..addVertex(Vector3(x, 0, z))
        ..addVertex(Vector3(x, height, z));
    }

    for (var i = 0; i < around; i++) {
      final here = i * 2;
      final next = ((i + 1) % around) * 2;
      // Up the near edge, along the top, down the far one: the other order
      // winds the side inwards and the cylinder is invisible from outside.
      mesh.addFace([here, here + 1, next + 1, next], smooth: true);
    }

    if (capped) {
      // Round one way for the bottom and the other for the top. Going round
      // in increasing angle is clockwise seen from above, which faces down —
      // right for the bottom and exactly wrong for the top.
      mesh
        ..addFace([for (var i = 0; i < around; i++) i * 2])
        ..addFace([for (var i = around - 1; i >= 0; i--) i * 2 + 1]);
    }
    return mesh;
  }

  Mesh _cone(int around) {
    final mesh = Mesh();
    final radiusX = width / 2;
    final radiusZ = depth / 2;

    final tip = mesh.addVertex(Vector3(0, height, 0));
    for (var i = 0; i < around; i++) {
      final angle = i / around * math.pi * 2;
      mesh.addVertex(Vector3(
        math.cos(angle) * radiusX,
        0,
        math.sin(angle) * radiusZ,
      ));
    }

    for (var i = 0; i < around; i++) {
      final here = 1 + i;
      final next = 1 + (i + 1) % around;
      mesh.addFace([here, tip, next], smooth: true);
    }
    if (capped) {
      // Forward, in increasing angle, which is clockwise from above and so
      // faces down — which is what the underside of a cone wants.
      mesh.addFace([for (var i = 1; i <= around; i++) i]);
    }
    return mesh;
  }

  Mesh _sphere(int around, int up) {
    final mesh = Mesh();
    final radiusX = width / 2;
    final radiusY = height / 2;
    final radiusZ = depth / 2;

    // One vertex at each pole rather than a ring of them in the same place:
    // a ring collapsed to a point is a fan of zero-area triangles, and every
    // one of them has a normal of nothing.
    final bottom = mesh.addVertex(Vector3(0, 0, 0));
    for (var ring = 1; ring < up; ring++) {
      final phi = ring / up * math.pi;
      final y = -math.cos(phi);
      final r = math.sin(phi);
      for (var i = 0; i < around; i++) {
        final angle = i / around * math.pi * 2;
        mesh.addVertex(Vector3(
          math.cos(angle) * r * radiusX,
          (y + 1) * radiusY,
          math.sin(angle) * r * radiusZ,
        ));
      }
    }
    final top = mesh.addVertex(Vector3(0, radiusY * 2, 0));

    int at(int ring, int i) => 1 + (ring - 1) * around + i % around;

    for (var i = 0; i < around; i++) {
      mesh.addFace([bottom, at(1, i), at(1, i + 1)], smooth: true);
    }
    for (var ring = 1; ring < up - 1; ring++) {
      for (var i = 0; i < around; i++) {
        mesh.addFace([
          at(ring, i),
          at(ring + 1, i),
          at(ring + 1, i + 1),
          at(ring, i + 1),
        ], smooth: true);
      }
    }
    for (var i = 0; i < around; i++) {
      mesh.addFace([top, at(up - 1, i + 1), at(up - 1, i)], smooth: true);
    }
    return mesh;
  }

  Mesh _stairs(int flights) {
    final mesh = Mesh();
    final rise = height / flights;
    final run = depth / flights;
    final x = width / 2;

    // Each step is a box, and the boxes share nothing: a staircase somebody is
    // about to pull a step off is easier to work with than one welded solid,
    // and welding is an operation they can ask for.
    for (var i = 0; i < flights; i++) {
      final z0 = -depth / 2 + i * run;
      final step = Shape(
        kind: ShapeKind.cube,
        width: width,
        height: rise * (i + 1),
        depth: run,
      ).build();
      step.transform(Matrix4.translationValues(0, 0, z0 + run / 2));
      mesh.merge(step);
    }
    // Nothing about x is per-step; it is here so the local is used and the
    // intent is on the page: a staircase is as wide as it was asked to be.
    assert(x > 0 || width <= 0);
    return mesh;
  }

  Mesh _arch(int around) {
    final mesh = Mesh();
    final outerX = width / 2;
    final thickness = math.min(width, height) / 4;
    final z = depth / 2;

    final segments = math.max(2, around ~/ 2);
    for (var i = 0; i <= segments; i++) {
      final angle = math.pi - i / segments * math.pi;
      final outer = Vector3(
        math.cos(angle) * outerX,
        math.sin(angle) * height,
        0,
      );
      final inner = Vector3(
        math.cos(angle) * (outerX - thickness),
        math.sin(angle) * (height - thickness),
        0,
      );
      mesh
        ..addVertex(Vector3(outer.x, outer.y, -z))
        ..addVertex(Vector3(inner.x, inner.y, -z))
        ..addVertex(Vector3(outer.x, outer.y, z))
        ..addVertex(Vector3(inner.x, inner.y, z));
    }

    for (var i = 0; i < segments; i++) {
      final a = i * 4;
      final b = (i + 1) * 4;
      mesh
        // The outside, the inside, and the two flat sides.
        ..addFace([a, b, b + 2, a + 2], smooth: true)
        ..addFace([a + 1, a + 3, b + 3, b + 1], smooth: true)
        ..addFace([a, a + 1, b + 1, b])
        ..addFace([a + 2, b + 2, b + 3, a + 3]);
    }
    return mesh;
  }
}
