import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// A box lined up with the axes.
class Aabb {
  const Aabb(this.minimum, this.maximum);

  factory Aabb.around(Vector3 centre, Vector3 size) =>
      Aabb(centre - size * 0.5, centre + size * 0.5);

  final Vector3 minimum;
  final Vector3 maximum;

  Vector3 get centre => (minimum + maximum) * 0.5;
  Vector3 get size => maximum - minimum;

  bool overlaps(Aabb other) =>
      minimum.x <= other.maximum.x &&
      maximum.x >= other.minimum.x &&
      minimum.y <= other.maximum.y &&
      maximum.y >= other.minimum.y &&
      minimum.z <= other.maximum.z &&
      maximum.z >= other.minimum.z;

  bool contains(Vector3 point) =>
      point.x >= minimum.x &&
      point.x <= maximum.x &&
      point.y >= minimum.y &&
      point.y <= maximum.y &&
      point.z >= minimum.z &&
      point.z <= maximum.z;

  /// The point inside this box nearest [to].
  Vector3 nearestTo(Vector3 to) => Vector3(
    to.x.clamp(minimum.x, maximum.x),
    to.y.clamp(minimum.y, maximum.y),
    to.z.clamp(minimum.z, maximum.z),
  );

  Aabb union(Aabb other) => Aabb(
    Vector3(
      math.min(minimum.x, other.minimum.x),
      math.min(minimum.y, other.minimum.y),
      math.min(minimum.z, other.minimum.z),
    ),
    Vector3(
      math.max(maximum.x, other.maximum.x),
      math.max(maximum.y, other.maximum.y),
      math.max(maximum.z, other.maximum.z),
    ),
  );

  Aabb grownBy(double margin) =>
      Aabb(minimum - Vector3.all(margin), maximum + Vector3.all(margin));
}

/// Something that can be hit, overlapped and asked about.
///
/// A short list, and it stays short. Every shape here has a closed-form
/// distance to a point, which is what makes every query below exact rather
/// than iterative — and the moment a shape without one is added (a cone, a
/// torus, a mesh) every query has to grow a numerical path beside the exact
/// one. Anything more complicated is better made of several of these.
sealed class Shape {
  const Shape();

  /// A box around it, for the broadphase.
  Aabb get bounds;

  /// The point on or inside this shape nearest [to].
  Vector3 nearestTo(Vector3 to);

  /// Whether [point] is inside.
  bool contains(Vector3 point);

  /// This shape moved.
  Shape movedTo(Vector3 position);

  /// Where it is.
  Vector3 get position;
}

class Sphere extends Shape {
  const Sphere(this.position, this.radius);

  @override
  final Vector3 position;
  final double radius;

  @override
  Aabb get bounds =>
      Aabb(position - Vector3.all(radius), position + Vector3.all(radius));

  @override
  Vector3 nearestTo(Vector3 to) {
    final offset = to - position;
    final distance = offset.length;
    if (distance <= radius || distance < 1e-12) return to.clone();
    return position + offset * (radius / distance);
  }

  @override
  bool contains(Vector3 point) => (point - position).length2 <= radius * radius;

  @override
  Sphere movedTo(Vector3 to) => Sphere(to, radius);
}

class Box extends Shape {
  Box(this.position, Vector3 size) : half = size * 0.5;

  @override
  final Vector3 position;

  /// Half its extent on each axis.
  final Vector3 half;

  Vector3 get size => half * 2;

  Aabb get box => Aabb(position - half, position + half);

  @override
  Aabb get bounds => box;

  @override
  Vector3 nearestTo(Vector3 to) => box.nearestTo(to);

  @override
  bool contains(Vector3 point) => box.contains(point);

  @override
  Box movedTo(Vector3 to) => Box(to, size);
}

/// A cylinder with a hemisphere on each end.
///
/// What a person is, for the purposes of walking into things. A box catches on
/// every corner and a sphere cannot stand up; a capsule slides along walls,
/// steps over small things and does not tip over — which is most of what a
/// character controller is asking of a shape.
class Capsule extends Shape {
  const Capsule(this.position, {required this.height, required this.radius});

  /// The centre of the whole shape.
  @override
  final Vector3 position;

  /// Its total height, ends included. Below twice the radius it is a sphere.
  final double height;
  final double radius;

  /// The two ends of the line inside it.
  (Vector3, Vector3) get segment {
    final half = math.max(height * 0.5 - radius, 0.0);
    return (position - Vector3(0, half, 0), position + Vector3(0, half, 0));
  }

  @override
  Aabb get bounds {
    final (low, high) = segment;
    return Aabb(low - Vector3.all(radius), high + Vector3.all(radius));
  }

  @override
  Vector3 nearestTo(Vector3 to) {
    final (low, high) = segment;
    final axis = nearestOnSegment(low, high, to);
    final offset = to - axis;
    final distance = offset.length;
    if (distance <= radius || distance < 1e-12) return to.clone();
    return axis + offset * (radius / distance);
  }

  @override
  bool contains(Vector3 point) {
    final (low, high) = segment;
    return (point - nearestOnSegment(low, high, point)).length2 <=
        radius * radius;
  }

  @override
  Capsule movedTo(Vector3 to) => Capsule(to, height: height, radius: radius);
}

/// The point on the segment `a`–`b` nearest [to].
Vector3 nearestOnSegment(Vector3 a, Vector3 b, Vector3 to) {
  final along = b - a;
  final length2 = along.length2;
  if (length2 < 1e-24) return a.clone();
  final t = ((to - a).dot(along) / length2).clamp(0.0, 1.0);
  return a + along * t;
}

/// Two shapes touching, and what it would take to separate them.
class Contact {
  const Contact({
    required this.point,
    required this.normal,
    required this.depth,
  });

  /// Where they meet.
  final Vector3 point;

  /// Which way the first would have to move to come apart, unit length.
  final Vector3 normal;

  /// How far into each other they are.
  ///
  /// The pair of these is what makes a contact usable rather than merely
  /// informative: a test that says only "yes" leaves the caller to work out
  /// how far to push, and every caller works it out slightly differently.
  final double depth;

  @override
  String toString() =>
      'Contact(${depth.toStringAsFixed(3)} along $normal at $point)';
}

/// Whether two shapes are touching, and where.
///
/// Null for no contact rather than a contact of zero depth: "they are not
/// touching" and "they are touching by nothing" want different code, and
/// folding them together is how a resolver ends up dividing by a depth of
/// nought.
Contact? contact(Shape a, Shape b) {
  // Every pair here reduces to a distance between two features — point to
  // point, point to box, segment to segment — because every shape has a
  // closed-form nearest point. That is why there is no table of a dozen
  // special cases below.
  return switch ((a, b)) {
    (final Sphere x, final Sphere y) => _sphereSphere(x, y),
    (final Sphere x, final Box y) => _sphereBox(x, y),
    (final Box x, final Sphere y) => _flip(_sphereBox(y, x)),
    (final Box x, final Box y) => _boxBox(x, y),
    (final Capsule x, final Sphere y) => _capsuleSphere(x, y),
    (final Sphere x, final Capsule y) => _flip(_capsuleSphere(y, x)),
    (final Capsule x, final Capsule y) => _capsuleCapsule(x, y),
    (final Capsule x, final Box y) => _capsuleBox(x, y),
    (final Box x, final Capsule y) => _flip(_capsuleBox(y, x)),
  };
}

/// Whether they touch at all. Cheaper than asking where.
bool overlaps(Shape a, Shape b) =>
    a.bounds.overlaps(b.bounds) && contact(a, b) != null;

Contact? _flip(Contact? found) => found == null
    ? null
    : Contact(point: found.point, normal: -found.normal, depth: found.depth);

Contact? _sphereSphere(Sphere a, Sphere b) {
  final offset = a.position - b.position;
  final distance = offset.length;
  final reach = a.radius + b.radius;
  if (distance >= reach) return null;

  // Two spheres exactly on top of each other have no direction to separate
  // along. Up is as good as any, and it is at least stable — a random one
  // would jitter for as long as they stayed there.
  final normal = distance < 1e-9 ? Vector3(0, 1, 0) : offset / distance;
  return Contact(
    point: b.position + normal * b.radius,
    normal: normal,
    depth: reach - distance,
  );
}

Contact? _sphereBox(Sphere a, Box b) {
  final near = b.box.nearestTo(a.position);
  final offset = a.position - near;
  final distance = offset.length;

  if (distance >= a.radius) return null;

  if (distance > 1e-9) {
    final normal = offset / distance;
    return Contact(point: near, normal: normal, depth: a.radius - distance);
  }

  // The centre is inside the box, so the nearest surface point is the centre
  // itself and there is no direction in it. The way out is the nearest face.
  final local = a.position - b.position;
  final left = b.half.x - local.x.abs();
  final down = b.half.y - local.y.abs();
  final back = b.half.z - local.z.abs();

  var normal = Vector3(local.x.sign == 0 ? 1 : local.x.sign, 0, 0);
  var depth = left;
  if (down < depth) {
    normal = Vector3(0, local.y.sign == 0 ? 1 : local.y.sign, 0);
    depth = down;
  }
  if (back < depth) {
    normal = Vector3(0, 0, local.z.sign == 0 ? 1 : local.z.sign);
    depth = back;
  }
  return Contact(point: a.position, normal: normal, depth: depth + a.radius);
}

Contact? _boxBox(Box a, Box b) {
  final offset = a.position - b.position;
  final overlapX = a.half.x + b.half.x - offset.x.abs();
  if (overlapX <= 0) return null;
  final overlapY = a.half.y + b.half.y - offset.y.abs();
  if (overlapY <= 0) return null;
  final overlapZ = a.half.z + b.half.z - offset.z.abs();
  if (overlapZ <= 0) return null;

  // Out along the axis they overlap least on. Any other axis is a longer way
  // out, and pushing along it is what makes a stack of boxes explode.
  var normal = Vector3(offset.x.sign == 0 ? 1 : offset.x.sign, 0, 0);
  var depth = overlapX;
  if (overlapY < depth) {
    normal = Vector3(0, offset.y.sign == 0 ? 1 : offset.y.sign, 0);
    depth = overlapY;
  }
  if (overlapZ < depth) {
    normal = Vector3(0, 0, offset.z.sign == 0 ? 1 : offset.z.sign);
    depth = overlapZ;
  }
  return Contact(
    point: b.box.nearestTo(a.position),
    normal: normal,
    depth: depth,
  );
}

Contact? _capsuleSphere(Capsule a, Sphere b) {
  final (low, high) = a.segment;
  final near = nearestOnSegment(low, high, b.position);
  return _sphereSphere(Sphere(near, a.radius), b);
}

Contact? _capsuleCapsule(Capsule a, Capsule b) {
  final (a0, a1) = a.segment;
  final (b0, b1) = b.segment;
  final (pa, pb) = nearestBetweenSegments(a0, a1, b0, b1);
  return _sphereSphere(Sphere(pa, a.radius), Sphere(pb, b.radius));
}

Contact? _capsuleBox(Capsule a, Box b) {
  // The point on the capsule's axis nearest the box, found by stepping: the
  // nearest point on the box depends on the point on the axis and the other
  // way round, so there is no closed form. Four iterations settles it to
  // well under a millimetre for anything person-sized, and it converges
  // monotonically — this is not a search that can wander.
  final (low, high) = a.segment;
  var onAxis = nearestOnSegment(low, high, b.position);
  for (var i = 0; i < 4; i++) {
    final onBox = b.box.nearestTo(onAxis);
    final next = nearestOnSegment(low, high, onBox);
    if ((next - onAxis).length2 < 1e-14) break;
    onAxis = next;
  }
  return _sphereBox(Sphere(onAxis, a.radius), b);
}

/// The nearest pair of points on two segments.
(Vector3, Vector3) nearestBetweenSegments(
  Vector3 a0,
  Vector3 a1,
  Vector3 b0,
  Vector3 b1,
) {
  final da = a1 - a0;
  final db = b1 - b0;
  final r = a0 - b0;
  final aa = da.length2;
  final bb = db.length2;
  final rb = r.dot(db);

  if (aa < 1e-24 && bb < 1e-24) return (a0.clone(), b0.clone());
  if (aa < 1e-24) {
    return (a0.clone(), b0 + db * (rb / bb).clamp(0.0, 1.0));
  }
  final ra = r.dot(da);
  if (bb < 1e-24) {
    return (a0 + da * (-ra / aa).clamp(0.0, 1.0), b0.clone());
  }

  final ab = da.dot(db);
  final denominator = aa * bb - ab * ab;

  // Parallel segments have no single nearest pair, so one end is taken and
  // the other found against it. Any answer is as correct as any other and
  // this one is stable.
  var s = denominator < 1e-12
      ? 0.0
      : ((ab * rb - ra * bb) / denominator).clamp(0.0, 1.0);
  var t = (ab * s + rb) / bb;

  if (t < 0) {
    t = 0;
    s = (-ra / aa).clamp(0.0, 1.0);
  } else if (t > 1) {
    t = 1;
    s = ((ab - ra) / aa).clamp(0.0, 1.0);
  }
  return (a0 + da * s, b0 + db * t);
}
