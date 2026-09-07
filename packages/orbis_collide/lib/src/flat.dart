import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// A box in two dimensions, lined up with the axes.
class Rect2 {
  const Rect2(this.minimum, this.maximum);

  factory Rect2.around(Vector2 centre, Vector2 size) =>
      Rect2(centre - size * 0.5, centre + size * 0.5);

  final Vector2 minimum;
  final Vector2 maximum;

  Vector2 get centre => (minimum + maximum) * 0.5;
  Vector2 get size => maximum - minimum;

  bool overlaps(Rect2 other) =>
      minimum.x <= other.maximum.x &&
      maximum.x >= other.minimum.x &&
      minimum.y <= other.maximum.y &&
      maximum.y >= other.minimum.y;

  bool contains(Vector2 point) =>
      point.x >= minimum.x &&
      point.x <= maximum.x &&
      point.y >= minimum.y &&
      point.y <= maximum.y;

  Vector2 nearestTo(Vector2 to) => Vector2(
    to.x.clamp(minimum.x, maximum.x),
    to.y.clamp(minimum.y, maximum.y),
  );
}

/// A hitbox: a circle or a rectangle.
///
/// Two shapes, and that is the whole list on purpose. Every 2D game's
/// collision is these plus a tile grid, and the third shape anybody asks for
/// — a rotated rectangle — is better served by a circle for the body and a
/// separate test for the swing.
sealed class Hitbox {
  const Hitbox();

  Rect2 get bounds;
  Vector2 get position;
  bool contains(Vector2 point);
}

class Circle extends Hitbox {
  const Circle(this.position, this.radius);

  @override
  final Vector2 position;
  final double radius;

  @override
  Rect2 get bounds =>
      Rect2(position - Vector2.all(radius), position + Vector2.all(radius));

  @override
  bool contains(Vector2 point) => (point - position).length2 <= radius * radius;
}

class Rectangle extends Hitbox {
  Rectangle(this.position, Vector2 size) : half = size * 0.5;

  @override
  final Vector2 position;
  final Vector2 half;

  Vector2 get size => half * 2;
  Rect2 get rect => Rect2(position - half, position + half);

  @override
  Rect2 get bounds => rect;

  @override
  bool contains(Vector2 point) => rect.contains(point);
}

/// Two hitboxes touching, and the way out.
class Touch {
  const Touch({required this.point, required this.normal, required this.depth});

  final Vector2 point;
  final Vector2 normal;
  final double depth;
}

/// Whether two hitboxes touch, and where.
Touch? touching(Hitbox a, Hitbox b) => switch ((a, b)) {
  (final Circle x, final Circle y) => _circles(x, y),
  (final Circle x, final Rectangle y) => _circleRect(x, y),
  (final Rectangle x, final Circle y) => _flip(_circleRect(y, x)),
  (final Rectangle x, final Rectangle y) => _rects(x, y),
};

Touch? _flip(Touch? found) => found == null
    ? null
    : Touch(point: found.point, normal: -found.normal, depth: found.depth);

Touch? _circles(Circle a, Circle b) {
  final offset = a.position - b.position;
  final distance = offset.length;
  final reach = a.radius + b.radius;
  if (distance >= reach) return null;

  final normal = distance < 1e-9 ? Vector2(0, 1) : offset / distance;
  return Touch(
    point: b.position + normal * b.radius,
    normal: normal,
    depth: reach - distance,
  );
}

Touch? _circleRect(Circle a, Rectangle b) {
  final near = b.rect.nearestTo(a.position);
  final offset = a.position - near;
  final distance = offset.length;
  if (distance >= a.radius) return null;

  if (distance > 1e-9) {
    return Touch(
      point: near,
      normal: offset / distance,
      depth: a.radius - distance,
    );
  }

  // Centre inside: out through the nearest edge.
  final local = a.position - b.position;
  final across = b.half.x - local.x.abs();
  final up = b.half.y - local.y.abs();
  final normal = across < up
      ? Vector2(local.x.sign == 0 ? 1 : local.x.sign, 0)
      : Vector2(0, local.y.sign == 0 ? 1 : local.y.sign);
  return Touch(
    point: a.position,
    normal: normal,
    depth: math.min(across, up) + a.radius,
  );
}

Touch? _rects(Rectangle a, Rectangle b) {
  final offset = a.position - b.position;
  final across = a.half.x + b.half.x - offset.x.abs();
  if (across <= 0) return null;
  final up = a.half.y + b.half.y - offset.y.abs();
  if (up <= 0) return null;

  final normal = across < up
      ? Vector2(offset.x.sign == 0 ? 1 : offset.x.sign, 0)
      : Vector2(0, offset.y.sign == 0 ? 1 : offset.y.sign);
  return Touch(
    point: b.rect.nearestTo(a.position),
    normal: normal,
    depth: math.min(across, up),
  );
}

/// One thing in a 2D world.
class Body {
  Body({
    required this.id,
    required this.hitbox,
    this.passthrough = false,
    this.is_ = 1,
    this.cares = 0xFFFFFFFF,
  });

  /// Whatever the game calls it.
  final int id;

  Hitbox hitbox;

  /// Whether things pass through it.
  ///
  /// A trigger: it reports touches and resolves none of them. A door's
  /// threshold, a pickup, the bottom of a pit. Distinguished from a solid
  /// body rather than left to the callback, because "did it touch" and "did
  /// it stop" are separate questions and a game that answers them in one
  /// place gets a pickup that blocks the player.
  final bool passthrough;

  /// What it is, and what it wants to be told about.
  final int is_;
  final int cares;
}

/// A touch between two bodies, as reported.
class Collision {
  const Collision(this.a, this.b, this.touch);

  final int a;
  final int b;
  final Touch touch;
}

/// A 2D world that says what is touching what, and when it started and
/// stopped.
///
/// The three events are the whole of what a game asks for, and only the first
/// is easy. *Started* and *stopped* need the previous frame remembered — a
/// world that only reports what is touching now leaves every caller keeping
/// its own set of what was touching before, and every caller keeps it
/// slightly differently.
class World2 {
  World2({this.cellSize = 8});

  final double cellSize;
  final Map<int, Body> _bodies = {};
  Set<int> _touching = {};

  int get length => _bodies.length;

  void add(Body body) => _bodies[body.id] = body;
  void remove(int id) => _bodies.remove(id);
  Body? operator [](int id) => _bodies[id];
  void clear() {
    _bodies.clear();
    _touching = {};
  }

  /// Works out what is touching, and reports the three events.
  ///
  /// Called once a frame. Everything it reports is about this call: `began`
  /// is what was not touching last time, `ended` is what was and is not now,
  /// and `touching` is everything, so a caller that only wants the current
  /// state does not have to add the first two together.
  ({List<Collision> touching, List<Collision> began, List<(int, int)> ended})
  step() {
    final buckets = <int, List<int>>{};
    final ids = _bodies.keys.toList()..sort();

    for (final id in ids) {
      final bounds = _bodies[id]!.hitbox.bounds;
      _forEachCell(bounds, (key) => (buckets[key] ??= <int>[]).add(id));
    }

    final now = <int>{};
    final found = <Collision>[];
    final began = <Collision>[];
    final seen = <int>{};

    for (final bucket in buckets.values) {
      for (var i = 0; i < bucket.length; i++) {
        for (var j = i + 1; j < bucket.length; j++) {
          if (bucket[i] == bucket[j]) continue;
          final a = math.min(bucket[i], bucket[j]);
          final b = math.max(bucket[i], bucket[j]);
          final key = _pair(a, b);
          // A body spanning several cells meets the same neighbour in each of
          // them; reporting that four times is the classic fault, and it
          // reads as a pickup collected four times.
          if (!seen.add(key)) continue;

          final one = _bodies[a]!;
          final two = _bodies[b]!;
          if ((one.cares & two.is_) == 0 && (two.cares & one.is_) == 0) {
            continue;
          }
          if (!one.hitbox.bounds.overlaps(two.hitbox.bounds)) continue;

          final touch = touching(one.hitbox, two.hitbox);
          if (touch == null) continue;

          final collision = Collision(a, b, touch);
          found.add(collision);
          now.add(key);
          if (!_touching.contains(key)) began.add(collision);
        }
      }
    }

    final ended = <(int, int)>[];
    for (final key in _touching) {
      if (!now.contains(key)) ended.add(_unpair(key));
    }

    _touching = now;
    return (touching: found, began: began, ended: ended);
  }

  /// Pushes solid bodies apart, leaving passthrough ones alone.
  ///
  /// Half the depth each, which is the honest answer when neither has a mass:
  /// moving one all the way makes the order they were added in visible.
  void separate(List<Collision> collisions) {
    for (final collision in collisions) {
      final a = _bodies[collision.a];
      final b = _bodies[collision.b];
      if (a == null || b == null) continue;
      if (a.passthrough || b.passthrough) continue;

      final push = collision.touch.normal * (collision.touch.depth * 0.5);
      a.hitbox = _moved(a.hitbox, push);
      b.hitbox = _moved(b.hitbox, -push);
    }
  }

  /// Everything whose hitbox contains [point].
  List<int> at(Vector2 point) => [
    for (final entry in _bodies.entries)
      if (entry.value.hitbox.contains(point)) entry.key,
  ]..sort();

  /// Everything overlapping [area].
  List<int> inside(Rect2 area) => [
    for (final entry in _bodies.entries)
      if (entry.value.hitbox.bounds.overlaps(area)) entry.key,
  ]..sort();

  static Hitbox _moved(Hitbox hitbox, Vector2 by) => switch (hitbox) {
    final Circle c => Circle(c.position + by, c.radius),
    final Rectangle r => Rectangle(r.position + by, r.size),
  };

  void _forEachCell(Rect2 box, void Function(int key) visit) {
    final x0 = (box.minimum.x / cellSize).floor();
    final x1 = (box.maximum.x / cellSize).floor();
    final y0 = (box.minimum.y / cellSize).floor();
    final y1 = (box.maximum.y / cellSize).floor();
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        // Mixed rather than XORed: XOR collides on the symmetric coordinates
        // a grid is full of, and a body that lands in one bucket twice is a
        // body paired with itself.
        var h = x * 73856093;
        h = (h ^ (h >> 15)) * 2246822519 + y * 19349663;
        visit(h ^ (h >> 16));
      }
    }
  }

  static int _pair(int a, int b) => a * 1000003 + b;
  static (int, int) _unpair(int key) => (key ~/ 1000003, key % 1000003);
}
