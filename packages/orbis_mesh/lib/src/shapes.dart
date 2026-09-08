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
  cube('Cube'),
  sprite('Sprite'),
  prism('Prism'),
  plane('Plane'),
  sphere('Sphere'),
  cylinder('Cylinder'),
  cone('Cone'),
  pipe('Pipe'),
  torus('Torus'),
  arch('Arch'),
  door('Door'),
  stairs('Stairs');

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
    this.sides = 6,
    this.rings = 16,
    this.columns = 24,
    this.steps = 10,
    this.subdivisions = 3,
    this.widthCuts = 1,
    this.heightCuts = 0,
    this.thickness = 0.25,
    this.tubeRadius = 0.1,
    this.circumference = 360,
    this.pedimentHeight = 0.5,
    this.sideWidth = 0.75,
    this.capped = true,
    this.smooth = true,
    this.byCount = true,
    this.stepHeight = 0.2,
  });

  final ShapeKind kind;

  final double width;
  final double height;
  final double depth;

  /// How many faces go round a cylinder, a cone, a pipe or an arch.
  final int sides;

  /// How many rows a torus has round its main circle.
  final int rings;

  /// How many columns a torus has round its tube.
  final int columns;

  /// How many steps a staircase has, when it is counted rather than measured.
  final int steps;

  /// How many times a sphere is divided. An icosphere rather than a globe of
  /// latitude lines: the faces are all about the same size, which is what
  /// makes it deform evenly and shade without pinching at the poles.
  final int subdivisions;

  /// How many extra cuts a plane has across it, and how many a plane, a
  /// cylinder or a pipe has up it. A cut is where an edge loop can be pulled
  /// from later, which is the reason to put one in before it is needed.
  final int widthCuts;
  final int heightCuts;

  /// How thick the wall of a pipe, an arch or a door is.
  final double thickness;

  /// How fat a torus's tube is.
  final double tubeRadius;

  /// How far round an arch or a staircase goes, in degrees. A hundred and
  /// eighty is a semicircle; zero on a staircase is a straight flight.
  final double circumference;

  /// A door's parts: how tall the piece over the opening is, and how wide the
  /// two uprights are.
  final double pedimentHeight;
  final double sideWidth;

  /// Whether a cylinder, a pipe or an arch has ends on it.
  final bool capped;

  /// Whether the curved parts shade round rather than faceted.
  final bool smooth;

  /// Whether a staircase is given a number of steps or a step height.
  ///
  /// The two answer different questions. A number of steps fits a flight to a
  /// gap; a height makes every step the one a building code allows, and the
  /// flight is however long it needs to be.
  final bool byCount;
  final double stepHeight;

  Shape copyWith({
    ShapeKind? kind,
    double? width,
    double? height,
    double? depth,
    int? sides,
    int? rings,
    int? columns,
    int? steps,
    int? subdivisions,
    int? widthCuts,
    int? heightCuts,
    double? thickness,
    double? tubeRadius,
    double? circumference,
    double? pedimentHeight,
    double? sideWidth,
    bool? capped,
    bool? smooth,
    bool? byCount,
    double? stepHeight,
  }) => Shape(
    kind: kind ?? this.kind,
    width: width ?? this.width,
    height: height ?? this.height,
    depth: depth ?? this.depth,
    sides: sides ?? this.sides,
    rings: rings ?? this.rings,
    columns: columns ?? this.columns,
    steps: steps ?? this.steps,
    subdivisions: subdivisions ?? this.subdivisions,
    widthCuts: widthCuts ?? this.widthCuts,
    heightCuts: heightCuts ?? this.heightCuts,
    thickness: thickness ?? this.thickness,
    tubeRadius: tubeRadius ?? this.tubeRadius,
    circumference: circumference ?? this.circumference,
    pedimentHeight: pedimentHeight ?? this.pedimentHeight,
    sideWidth: sideWidth ?? this.sideWidth,
    capped: capped ?? this.capped,
    smooth: smooth ?? this.smooth,
    byCount: byCount ?? this.byCount,
    stepHeight: stepHeight ?? this.stepHeight,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'width': width,
    'height': height,
    'depth': depth,
    'sides': sides,
    'rings': rings,
    'columns': columns,
    'steps': steps,
    'subdivisions': subdivisions,
    'widthCuts': widthCuts,
    'heightCuts': heightCuts,
    'thickness': thickness,
    'tubeRadius': tubeRadius,
    'circumference': circumference,
    'pedimentHeight': pedimentHeight,
    'sideWidth': sideWidth,
    'capped': capped,
    'smooth': smooth,
    'byCount': byCount,
    'stepHeight': stepHeight,
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
      sides: count('sides', 6),
      rings: count('rings', 16),
      columns: count('columns', 24),
      steps: count('steps', 10),
      subdivisions: count('subdivisions', 3),
      widthCuts: count('widthCuts', 1),
      heightCuts: count('heightCuts', 0),
      thickness: number('thickness', 0.25),
      tubeRadius: number('tubeRadius', 0.1),
      circumference: number('circumference', 360),
      pedimentHeight: number('pedimentHeight', 0.5),
      sideWidth: number('sideWidth', 0.75),
      capped: map['capped'] != false,
      smooth: map['smooth'] != false,
      byCount: map['byCount'] != false,
      stepHeight: number('stepHeight', 0.2),
    );
  }

  /// A shape of this kind, with the defaults that kind wants.
  ///
  /// One set of defaults for twelve primitives would be twelve compromises: an
  /// arch is a semicircle and a torus is a whole one, a cone wants six sides
  /// and a sphere wants three divisions. What somebody gets when they ask for
  /// a shape should be the shape, not a starting point they have to correct.
  factory Shape.of(ShapeKind kind) => switch (kind) {
    ShapeKind.arch => Shape(kind: kind, circumference: 180, thickness: 0.1),
    ShapeKind.torus => Shape(kind: kind, circumference: 360),
    ShapeKind.cone => Shape(kind: kind, sides: 6),
    ShapeKind.sphere => Shape(kind: kind, subdivisions: 3),
    ShapeKind.pipe => Shape(kind: kind, thickness: 0.25),
    ShapeKind.plane => Shape(kind: kind, widthCuts: 1, heightCuts: 1),
    _ => Shape(kind: kind),
  };

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
    final up = rings.clamp(3, 64);
    // Counted, or worked out from how tall each step is — either way at least
    // one, because a flight of no steps is a gap.
    final flights = byCount
        ? steps.clamp(1, 256)
        : (height / (stepHeight <= 0.01 ? 0.01 : stepHeight)).round().clamp(
            1,
            256,
          );

    final mesh = switch (kind) {
      ShapeKind.cube => _cube(),
      // A plane with all three sides at one unit, which is what a sprite is:
      // somewhere to put a picture.
      ShapeKind.sprite => Shape(
        kind: ShapeKind.plane,
        width: 1,
        depth: 1,
        widthCuts: 0,
        heightCuts: 0,
      )._plane(0, 0),
      ShapeKind.prism => _prism(),
      ShapeKind.plane => _plane(
        widthCuts.clamp(0, 128),
        heightCuts.clamp(0, 128),
      ),
      ShapeKind.sphere => _sphere(subdivisions.clamp(1, 5)),
      ShapeKind.cylinder => _cylinder(around, heightCuts.clamp(0, 64)),
      ShapeKind.cone => _cone(around),
      ShapeKind.pipe => _pipe(around, heightCuts.clamp(0, 31)),
      ShapeKind.torus => _torus(up, columns.clamp(3, 64)),
      ShapeKind.arch => _arch(sides.clamp(2, 200)),
      ShapeKind.door => _door(),
      ShapeKind.stairs => _stairs(flights),
    };

    // Stood on the ground, once, here. Somebody putting a shape in a scene
    // expects it on the floor, and a shape centred on its middle sinks half
    // into it — leaving each of the twelve builders to remember that is
    // leaving eleven of them to forget.
    final floor = mesh.bounds.min.y;
    if (floor.abs() > 1e-12) {
      mesh.transform(Matrix4.translationValues(0, -floor, 0));
    }
    return mesh;
  }

  /// A grid of quads, so there are edges to pull on later.
  Mesh _plane(int across, int along) {
    final columns = across + 1;
    final rows = along + 1;
    final mesh = Mesh();

    for (var z = 0; z <= rows; z++) {
      for (var x = 0; x <= columns; x++) {
        mesh.addVertex(
          Vector3((x / columns - 0.5) * width, 0, (z / rows - 0.5) * depth),
        );
      }
    }

    int at(int x, int z) => z * (columns + 1) + x;
    for (var z = 0; z < rows; z++) {
      for (var x = 0; x < columns; x++) {
        // Wound so it faces up, which is the only way a floor is any use.
        mesh.addFace([at(x, z), at(x, z + 1), at(x + 1, z + 1), at(x + 1, z)]);
      }
    }
    return mesh;
  }

  Mesh _cube() {
    final x = width / 2;
    final z = depth / 2;
    final mesh = Mesh(
      positions: [
        Vector3(-x, 0, -z),
        Vector3(x, 0, -z),
        Vector3(x, 0, z),
        Vector3(-x, 0, z),
        Vector3(-x, height, -z),
        Vector3(x, height, -z),
        Vector3(x, height, z),
        Vector3(-x, height, z),
      ],
    );

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

  /// A box with a roof: a triangular prism lying along Z.
  Mesh _prism() {
    final x = width / 2;
    final z = depth / 2;
    final mesh = Mesh(
      positions: [
        Vector3(-x, 0, -z),
        Vector3(x, 0, -z),
        Vector3(x, 0, z),
        Vector3(-x, 0, z),
        Vector3(0, height, -z),
        Vector3(0, height, z),
      ],
    );

    mesh
      ..addFace([0, 1, 2, 3]) // bottom
      ..addFace([0, 3, 5, 4]) // left slope
      ..addFace([1, 4, 5, 2]) // right slope
      ..addFace([0, 4, 1]) // the gable at the back
      ..addFace([3, 2, 5]); // and at the front
    return mesh;
  }

  /// A ball made by dividing an icosahedron.
  ///
  /// Not latitude and longitude: those crowd every face into the poles, where
  /// a texture pinches and a deformation bunches. An icosphere's faces are all
  /// about the same size, everywhere.
  Mesh _sphere(int times) {
    // The twelve corners of an icosahedron, from the golden ratio.
    const t = 1.618033988749895;
    final mesh = Mesh(
      positions: [
        Vector3(-1, t, 0),
        Vector3(1, t, 0),
        Vector3(-1, -t, 0),
        Vector3(1, -t, 0),
        Vector3(0, -1, t),
        Vector3(0, 1, t),
        Vector3(0, -1, -t),
        Vector3(0, 1, -t),
        Vector3(t, 0, -1),
        Vector3(t, 0, 1),
        Vector3(-t, 0, -1),
        Vector3(-t, 0, 1),
      ],
    );

    for (final face in const [
      [0, 11, 5],
      [0, 5, 1],
      [0, 1, 7],
      [0, 7, 10],
      [0, 10, 11],
      [1, 5, 9],
      [5, 11, 4],
      [11, 10, 2],
      [10, 7, 6],
      [7, 1, 8],
      [3, 9, 4],
      [3, 4, 2],
      [3, 2, 6],
      [3, 6, 8],
      [3, 8, 9],
      [4, 9, 5],
      [2, 4, 11],
      [6, 2, 10],
      [8, 6, 7],
      [9, 8, 1],
    ]) {
      mesh.addFace([...face], smooth: smooth);
    }

    // Each pass splits every triangle into four and pushes the new corners
    // out onto the sphere.
    for (var pass = 1; pass < times; pass++) {
      final split = <String, int>{};
      final grown = Mesh(
        positions: [for (final at in mesh.positions) at.clone()],
      );

      int between(int a, int b) {
        final key = a < b ? '$a/$b' : '$b/$a';
        return split[key] ??= grown.addVertex(
          (grown.positions[a] + grown.positions[b]).normalized(),
        );
      }

      for (final face in mesh.faces) {
        final a = face.vertices[0];
        final b = face.vertices[1];
        final c = face.vertices[2];
        final ab = between(a, b);
        final bc = between(b, c);
        final ca = between(c, a);
        grown
          ..addFace([a, ab, ca], smooth: smooth)
          ..addFace([b, bc, ab], smooth: smooth)
          ..addFace([c, ca, bc], smooth: smooth)
          ..addFace([ab, bc, ca], smooth: smooth);
      }
      mesh.positions
        ..clear()
        ..addAll(grown.positions);
      mesh.faces
        ..clear()
        ..addAll(grown.faces);
    }

    // Onto the sphere, then scaled to the box asked for and stood on the
    // ground like every other shape.
    for (final at in mesh.positions) {
      at
        ..normalize()
        ..multiply(Vector3(width / 2, height / 2, depth / 2))
        ..y += height / 2;
    }
    return mesh;
  }

  Mesh _cylinder(int around, int cuts) {
    final mesh = Mesh();
    final radiusX = width / 2;
    final radiusZ = depth / 2;
    final levels = cuts + 1;

    for (var i = 0; i < around; i++) {
      final angle = i / around * math.pi * 2;
      final x = math.cos(angle) * radiusX;
      final z = math.sin(angle) * radiusZ;
      for (var level = 0; level <= levels; level++) {
        mesh.addVertex(Vector3(x, height * level / levels, z));
      }
    }

    int at(int segment, int level) => (segment % around) * (levels + 1) + level;

    for (var i = 0; i < around; i++) {
      for (var level = 0; level < levels; level++) {
        // Up the near edge, along the top, down the far one: the other order
        // winds the side inwards and the cylinder is invisible from outside.
        mesh.addFace([
          at(i, level),
          at(i, level + 1),
          at(i + 1, level + 1),
          at(i + 1, level),
        ], smooth: smooth);
      }
    }

    if (capped) {
      // Round one way for the bottom and the other for the top. Going round
      // in increasing angle is clockwise seen from above and so faces down —
      // right for the bottom and exactly wrong for the top.
      mesh
        ..addFace([for (var i = 0; i < around; i++) at(i, 0)])
        ..addFace([for (var i = around - 1; i >= 0; i--) at(i, levels)]);
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
      mesh.addVertex(
        Vector3(math.cos(angle) * radiusX, 0, math.sin(angle) * radiusZ),
      );
    }

    for (var i = 0; i < around; i++) {
      final here = 1 + i;
      final next = 1 + (i + 1) % around;
      mesh.addFace([here, tip, next], smooth: smooth);
    }
    if (capped) {
      // Forward, in increasing angle, which is clockwise from above and so
      // faces down — which is what the underside of a cone wants.
      mesh.addFace([for (var i = 1; i <= around; i++) i]);
    }
    return mesh;
  }

  /// A cylinder with the middle taken out.
  Mesh _pipe(int around, int cuts) {
    final mesh = Mesh();
    final outerX = width / 2;
    final outerZ = depth / 2;
    final wall = thickness.clamp(0.01, math.min(outerX, outerZ) * 0.99);
    final levels = cuts + 1;

    for (var i = 0; i < around; i++) {
      final angle = i / around * math.pi * 2;
      final cos = math.cos(angle);
      final sin = math.sin(angle);
      for (var level = 0; level <= levels; level++) {
        final y = height * level / levels;
        mesh
          ..addVertex(Vector3(cos * outerX, y, sin * outerZ))
          ..addVertex(Vector3(cos * (outerX - wall), y, sin * (outerZ - wall)));
      }
    }

    final perSegment = (levels + 1) * 2;
    int outer(int i, int level) => (i % around) * perSegment + level * 2;
    int inner(int i, int level) => outer(i, level) + 1;

    for (var i = 0; i < around; i++) {
      for (var level = 0; level < levels; level++) {
        mesh
          // Outside, and the inside wound the other way so it faces inwards.
          ..addFace([
            outer(i, level),
            outer(i, level + 1),
            outer(i + 1, level + 1),
            outer(i + 1, level),
          ], smooth: smooth)
          ..addFace([
            inner(i, level),
            inner(i + 1, level),
            inner(i + 1, level + 1),
            inner(i, level + 1),
          ], smooth: smooth);
      }
      if (capped) {
        mesh
          ..addFace([
            outer(i, 0),
            inner(i, 0),
            inner(i + 1, 0),
            outer(i + 1, 0),
          ])
          ..addFace([
            outer(i, levels),
            outer(i + 1, levels),
            inner(i + 1, levels),
            inner(i, levels),
          ]);
      }
    }
    return mesh;
  }

  /// A ring with a round section.
  Mesh _torus(int rows, int columns) {
    final mesh = Mesh();
    final ringX = width / 2 - tubeRadius;
    final ringZ = depth / 2 - tubeRadius;
    final tube = tubeRadius.clamp(0.001, math.min(width, depth) / 2);

    final sweep = circumference.clamp(1.0, 360.0) / 360 * math.pi * 2;
    final closed = circumference >= 359.999;
    final steps = closed ? rows : rows + 1;

    for (var row = 0; row < steps; row++) {
      final around = row / rows * sweep;
      final cos = math.cos(around);
      final sin = math.sin(around);
      for (var column = 0; column < columns; column++) {
        final through = column / columns * math.pi * 2;
        final out = math.cos(through) * tube;
        mesh.addVertex(
          Vector3(
            cos * (ringX + out),
            math.sin(through) * tube + tube,
            sin * (ringZ + out),
          ),
        );
      }
    }

    int at(int row, int column) => (row % steps) * columns + column % columns;
    for (var row = 0; row < (closed ? steps : steps - 1); row++) {
      for (var column = 0; column < columns; column++) {
        mesh.addFace([
          at(row, column),
          at(row, column + 1),
          at(row + 1, column + 1),
          at(row + 1, column),
        ], smooth: smooth);
      }
    }
    return mesh;
  }

  /// A doorway: two uprights and a piece across the top.
  Mesh _door() {
    final side = sideWidth.clamp(0.01, width / 2 - 0.01);
    final pediment = pedimentHeight.clamp(0.01, height - 0.01);
    final mesh = Mesh();

    for (final part in [
      // Left upright, right upright, and the lintel over the gap.
      (w: side, h: height - pediment, x: -(width - side) / 2, y: 0.0),
      (w: side, h: height - pediment, x: (width - side) / 2, y: 0.0),
      (w: width, h: pediment, x: 0.0, y: height - pediment),
    ]) {
      final piece = Shape(
        kind: ShapeKind.cube,
        width: part.w,
        height: part.h,
        depth: depth,
      ).build()..transform(Matrix4.translationValues(part.x, part.y, 0));
      mesh.merge(piece);
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

  /// A curved wall: an arc swept through a thickness, with a flat end at each
  /// side.
  Mesh _arch(int segments) {
    final mesh = Mesh();
    final outerX = width / 2;
    final wall = thickness.clamp(0.01, math.min(outerX, height) * 0.99);
    final z = depth / 2;
    final sweep = circumference.clamp(1.0, 360.0) / 360 * math.pi * 2;
    final closed = circumference >= 359.999;

    // Measured from one side round to the other, so a hundred and eighty
    // degrees is a semicircle standing on its ends.
    final start = math.pi - (sweep - math.pi) / 2;

    for (var i = 0; i <= segments; i++) {
      final angle = start - i / segments * sweep;
      final cos = math.cos(angle);
      final sin = math.sin(angle);
      for (final side in [-z, z]) {
        mesh
          ..addVertex(Vector3(cos * outerX, sin * height, side))
          ..addVertex(
            Vector3(cos * (outerX - wall), sin * (height - wall), side),
          );
      }
    }

    // Four points a step: outer-back, inner-back, outer-front, inner-front.
    int at(int step, int which) => step * 4 + which;

    for (var i = 0; i < segments; i++) {
      final a = i;
      final b = i + 1;
      mesh
        // The outside of the curve, and the inside wound the other way.
        ..addFace([at(a, 0), at(b, 0), at(b, 2), at(a, 2)], smooth: smooth)
        ..addFace([at(a, 1), at(a, 3), at(b, 3), at(b, 1)], smooth: smooth)
        // And the two flat sides.
        ..addFace([at(a, 0), at(a, 1), at(b, 1), at(b, 0)])
        ..addFace([at(a, 2), at(b, 2), at(b, 3), at(a, 3)]);
    }

    // The two cut ends, unless it goes all the way round and meets itself.
    if (capped && !closed) {
      mesh
        ..addFace([at(0, 0), at(0, 2), at(0, 3), at(0, 1)])
        ..addFace([
          at(segments, 0),
          at(segments, 1),
          at(segments, 3),
          at(segments, 2),
        ]);
    }
    return mesh;
  }
}
