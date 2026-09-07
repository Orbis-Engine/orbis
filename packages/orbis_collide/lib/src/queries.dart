import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' hide Ray, Sphere;

import 'shapes.dart';

/// A line with a start and a direction.
class Ray {
  Ray(this.from, Vector3 direction, {this.distance = double.infinity})
    : direction = direction.length2 < 1e-24
          ? Vector3(0, 0, -1)
          : direction.normalized();

  final Vector3 from;

  /// Unit length, always — a ray built from a zero vector points forwards
  /// rather than producing NaN at every step downstream.
  final Vector3 direction;

  /// How far it reaches.
  final double distance;

  Vector3 at(double along) => from + direction * along;
}

/// Where a ray met something.
class Hit {
  const Hit({
    required this.distance,
    required this.point,
    required this.normal,
    this.inside = false,
  });

  /// How far along the ray, in metres.
  final double distance;
  final Vector3 point;

  /// The surface normal where it landed, pointing back towards the ray.
  final Vector3 normal;

  /// Whether the ray began inside the shape.
  ///
  /// Worth reporting rather than hiding: a camera inside geometry and a camera
  /// looking at it from outside are the same "hit at distance nought"
  /// otherwise, and they want opposite handling.
  final bool inside;
}

/// Where [ray] meets [shape], or null.
Hit? raycast(Ray ray, Shape shape) => switch (shape) {
  final Sphere s => _raySphere(ray, s),
  final Box b => _rayBox(ray, b),
  final Capsule c => _rayCapsule(ray, c),
};

Hit? _raySphere(Ray ray, Sphere sphere) {
  final offset = ray.from - sphere.position;
  final b = offset.dot(ray.direction);
  final c = offset.length2 - sphere.radius * sphere.radius;

  // Pointing away from a sphere it is already outside.
  if (c > 0 && b > 0) return null;

  final discriminant = b * b - c;
  if (discriminant < 0) return null;

  final root = math.sqrt(discriminant);
  var along = -b - root;
  final inside = along < 0;
  if (inside) along = -b + root;
  if (along < 0 || along > ray.distance) return null;

  final point = ray.at(along);
  final normal = (point - sphere.position).normalized();
  return Hit(
    distance: along,
    point: point,
    normal: inside ? -normal : normal,
    inside: inside,
  );
}

Hit? _rayBox(Ray ray, Box box) {
  final bounds = box.box;
  var near = 0.0;
  var far = ray.distance;
  var axis = 0;
  var sign = 1.0;

  for (var i = 0; i < 3; i++) {
    final origin = ray.from[i];
    final along = ray.direction[i];
    final low = bounds.minimum[i];
    final high = bounds.maximum[i];

    if (along.abs() < 1e-12) {
      // Parallel to this pair of faces: either between them the whole way or
      // never. Infinity would compare correctly but a divide by nothing is
      // not worth relying on.
      if (origin < low || origin > high) return null;
      continue;
    }

    var first = (low - origin) / along;
    var second = (high - origin) / along;
    var face = -1.0;
    if (first > second) {
      final swap = first;
      first = second;
      second = swap;
      face = 1.0;
    }
    if (first > near) {
      near = first;
      axis = i;
      sign = face;
    }
    if (second < far) far = second;
    if (near > far) return null;
  }

  final inside = bounds.contains(ray.from);
  if (near > ray.distance) return null;

  final normal = Vector3.zero();
  normal[axis] = inside ? -sign : sign;
  return Hit(
    distance: inside ? 0 : near,
    point: ray.at(inside ? 0 : near),
    normal: normal,
    inside: inside,
  );
}

Hit? _rayCapsule(Ray ray, Capsule capsule) {
  // Marched rather than solved. The closed form is a quartic once the ends
  // are included, and the cases where it is ill-conditioned — a ray almost
  // along the axis — are exactly the ones a character controller asks about
  // constantly. This is bounded, monotone and never wrong by more than the
  // tolerance.
  const steps = 64;
  final reach = ray.distance.isFinite
      ? ray.distance
      : capsule.bounds.size.length + (ray.from - capsule.position).length;

  if (capsule.contains(ray.from)) {
    return Hit(
      distance: 0,
      point: ray.from.clone(),
      normal: -ray.direction,
      inside: true,
    );
  }

  var previous = 0.0;
  for (var i = 1; i <= steps; i++) {
    final along = reach * i / steps;
    if (capsule.contains(ray.at(along))) {
      // Bisect between the last step outside and this one inside.
      var low = previous;
      var high = along;
      for (var j = 0; j < 24; j++) {
        final middle = (low + high) * 0.5;
        if (capsule.contains(ray.at(middle))) {
          high = middle;
        } else {
          low = middle;
        }
      }
      final point = ray.at(high);
      final (a, b) = capsule.segment;
      final axis = nearestOnSegment(a, b, point);
      final offset = point - axis;
      return Hit(
        distance: high,
        point: point,
        normal: offset.length2 < 1e-18 ? -ray.direction : offset.normalized(),
      );
    }
    previous = along;
  }
  return null;
}

/// Everything in [shapes] that [ray] meets, nearest first.
List<({int index, Hit hit})> raycastAll(Ray ray, List<Shape> shapes) {
  final found = <({int index, Hit hit})>[];
  for (var i = 0; i < shapes.length; i++) {
    final hit = raycast(ray, shapes[i]);
    if (hit != null) found.add((index: i, hit: hit));
  }
  found.sort((a, b) => a.hit.distance.compareTo(b.hit.distance));
  return found;
}

/// The first thing [ray] meets, or null.
({int index, Hit hit})? raycastFirst(Ray ray, List<Shape> shapes) {
  ({int index, Hit hit})? best;
  for (var i = 0; i < shapes.length; i++) {
    final hit = raycast(ray, shapes[i]);
    if (hit == null) continue;
    if (best == null || hit.distance < best.hit.distance) {
      best = (index: i, hit: hit);
    }
  }
  return best;
}

/// A grid of buckets, for finding which shapes are near enough to test
/// properly.
///
/// Every pair is what a scene of a thousand shapes cannot afford: half a
/// million tests to find the four that touch. A grid turns that into "look in
/// my own cell and its neighbours", which is a handful.
///
/// A grid rather than a tree because the things in it move. A tree has to be
/// rebuilt or refitted when they do; a grid is rebuilt by dropping every
/// shape into a bucket, which is one pass and no allocation per shape beyond
/// the bucket lists.
class Broadphase {
  Broadphase({this.cellSize = 4});

  /// How wide a bucket is. About the size of the largest common shape: much
  /// smaller and a big shape lands in dozens of buckets, much larger and
  /// every bucket holds everything.
  final double cellSize;

  final Map<int, List<int>> _buckets = {};
  final List<Aabb> _bounds = [];

  int get length => _bounds.length;

  void clear() {
    _buckets.clear();
    _bounds.clear();
  }

  /// Puts [shape] in, under the index it will be reported by.
  int add(Shape shape) => addBounds(shape.bounds);

  int addBounds(Aabb bounds) {
    final index = _bounds.length;
    _bounds.add(bounds);
    _forEachCell(bounds, (key) {
      (_buckets[key] ??= <int>[]).add(index);
    });
    return index;
  }

  /// Every pair whose boxes overlap, each reported once.
  ///
  /// A shape that spans several buckets meets the same neighbour in each of
  /// them, so pairs are kept in a set — reporting a collision four times
  /// because the two things were large is the classic fault here, and it
  /// shows up as objects being pushed apart four times as hard.
  List<(int, int)> pairs() {
    final seen = <int>{};
    final found = <(int, int)>[];

    for (final bucket in _buckets.values) {
      for (var i = 0; i < bucket.length; i++) {
        for (var j = i + 1; j < bucket.length; j++) {
          if (bucket[i] == bucket[j]) continue;
          final a = bucket[i] < bucket[j] ? bucket[i] : bucket[j];
          final b = bucket[i] < bucket[j] ? bucket[j] : bucket[i];
          if (!seen.add(a * 1000003 + b)) continue;
          if (_bounds[a].overlaps(_bounds[b])) found.add((a, b));
        }
      }
    }
    return found;
  }

  /// Everything whose box overlaps [box].
  List<int> near(Aabb box) {
    final found = <int>{};
    _forEachCell(box, (key) {
      for (final index in _buckets[key] ?? const <int>[]) {
        if (_bounds[index].overlaps(box)) found.add(index);
      }
    });
    return found.toList()..sort();
  }

  void _forEachCell(Aabb box, void Function(int key) visit) {
    final x0 = (box.minimum.x / cellSize).floor();
    final x1 = (box.maximum.x / cellSize).floor();
    final y0 = (box.minimum.y / cellSize).floor();
    final y1 = (box.maximum.y / cellSize).floor();
    final z0 = (box.minimum.z / cellSize).floor();
    final z1 = (box.maximum.z / cellSize).floor();

    for (var z = z0; z <= z1; z++) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          visit(_key(x, y, z));
        }
      }
    }
  }

  /// Three cell coordinates as one integer.
  ///
  /// Not a string. A grid is rebuilt every frame and every shape hashes at
  /// least one of these; building strings for that is most of the frame.
  ///
  /// Mixed in sequence rather than XORed together, which is how this is
  /// usually written and is wrong: `x*a ^ y*b ^ z*c` collides constantly on
  /// the symmetric coordinates a grid is full of, so one shape lands in the
  /// same bucket several times and is paired with itself. Caught by the test
  /// that says a shape spanning cells is reported once.
  static int _key(int x, int y, int z) {
    var h = x * 73856093;
    h = (h ^ (h >> 15)) * 2246822519 + y * 19349663;
    h = (h ^ (h >> 13)) * 3266489917 + z * 83492791;
    return h ^ (h >> 16);
  }
}

/// What a body is allowed to touch.
///
/// Two masks rather than one: what something *is*, and what it *cares about*.
/// A bullet is on the bullet layer and cares about walls and people; a wall is
/// on the wall layer and cares about nothing, because a wall does not initiate
/// anything. One mask forces every pair to be described twice and the two
/// descriptions drift apart.
class Layers {
  const Layers({this.is_ = 1, this.cares = 0xFFFFFFFF});

  /// The layers this belongs to.
  final int is_;

  /// The layers it wants to be told about.
  final int cares;

  /// Whether either of the pair cares about the other.
  ///
  /// Either, not both: a bullet that cares about walls should hit a wall that
  /// cares about nothing, and requiring both would mean every passive thing
  /// in the world listing everything that might touch it.
  static bool interact(Layers a, Layers b) =>
      (a.cares & b.is_) != 0 || (b.cares & a.is_) != 0;
}
