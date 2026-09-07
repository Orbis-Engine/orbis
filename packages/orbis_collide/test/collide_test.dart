import 'package:orbis_collide/orbis_collide.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart' hide Ray, Sphere;

void main() {
  Vector3 v(double x, [double y = 0, double z = 0]) => Vector3(x, y, z);

  group('shapes touching', () {
    test('two spheres apart are not touching', () {
      expect(contact(Sphere(v(0), 1), Sphere(v(5), 1)), isNull);
    });

    test('two spheres overlapping say how far and which way', () {
      final found = contact(Sphere(v(0), 1), Sphere(v(1.5), 1))!;
      expect(found.depth, closeTo(0.5, 1e-9));
      expect(found.normal.x, closeTo(-1, 1e-9));
    });

    test('two spheres exactly on top of each other pick a stable way out', () {
      // No direction exists, and a random one would jitter for as long as
      // they stayed there.
      final found = contact(Sphere(v(0), 1), Sphere(v(0), 1))!;
      expect(found.normal.length, closeTo(1, 1e-9));
      expect(found.normal, contact(Sphere(v(0), 1), Sphere(v(0), 1))!.normal);
    });

    test('a sphere on a box face comes out through the face', () {
      final found = contact(Sphere(v(0, 1.4), 0.5), Box(v(0), v(2, 2, 2)))!;
      expect(found.normal.y, closeTo(1, 1e-9));
      expect(found.depth, closeTo(0.1, 1e-9));
    });

    test('a sphere inside a box comes out the nearest face', () {
      // The centre is inside, so there is no direction in the offset — the
      // shortest way out has to be found from the faces.
      final found = contact(Sphere(v(0, 0.9), 0.2), Box(v(0), v(4, 2, 4)))!;
      expect(found.normal.y, closeTo(1, 1e-9));
    });

    test('two boxes come apart along the axis they overlap least on', () {
      // Any other axis is a longer way out, and pushing along it is what
      // makes a stack of boxes explode.
      final found = contact(Box(v(0, 1.8), v(2, 2, 2)), Box(v(0), v(6, 2, 6)))!;
      expect(found.normal.y, closeTo(1, 1e-9));
      expect(found.depth, closeTo(0.2, 1e-9));
    });

    test('a capsule standing on a box touches through its foot', () {
      final standing = Capsule(v(0, 1.4), height: 2, radius: 0.4);
      final ground = Box(v(0), v(10, 1, 10));
      final found = contact(standing, ground)!;
      expect(found.normal.y, closeTo(1, 1e-9));
    });

    test('a capsule beside a wall slides rather than catching', () {
      // What a capsule is for: the contact normal is along the wall's own
      // axis whatever height the body is at.
      final wall = Box(v(2, 0), v(1, 10, 10));
      for (final height in [-0.5, 0.0, 0.5, 0.9]) {
        final body = Capsule(v(1.2, height), height: 2, radius: 0.4);
        final found = contact(body, wall);
        expect(found, isNotNull, reason: 'at $height');
        expect(found!.normal.x, closeTo(-1, 1e-6), reason: 'at $height');
      }
    });

    test('two capsules crossing find their nearest points', () {
      final a = Capsule(v(0), height: 4, radius: 0.5);
      final b = Capsule(v(0.8), height: 4, radius: 0.5);
      expect(contact(a, b), isNotNull);
      expect(contact(a, b)!.depth, closeTo(0.2, 1e-6));
    });

    test('the answer is the same whichever way round it is asked', () {
      final a = Sphere(v(0, 1.4), 0.5);
      final b = Box(v(0), v(2, 2, 2));
      final forwards = contact(a, b)!;
      final backwards = contact(b, a)!;

      expect(backwards.depth, closeTo(forwards.depth, 1e-9));
      expect(backwards.normal.y, closeTo(-forwards.normal.y, 1e-9));
    });

    test('overlaps agrees with contact', () {
      final pairs = <(Shape, Shape)>[
        (Sphere(v(0), 1), Sphere(v(1.5), 1)),
        (Sphere(v(0), 1), Sphere(v(9), 1)),
        (Box(v(0), v(2, 2, 2)), Sphere(v(1.2), 0.5)),
        (Capsule(v(0), height: 2, radius: 0.5), Sphere(v(0.8), 0.4)),
      ];
      for (final (a, b) in pairs) {
        expect(overlaps(a, b), contact(a, b) != null);
      }
    });
  });

  group('rays', () {
    test('a ray down an axis hits a sphere where it should', () {
      final hit = raycast(Ray(v(-10), v(1)), Sphere(v(0), 1))!;
      expect(hit.distance, closeTo(9, 1e-9));
      expect(hit.normal.x, closeTo(-1, 1e-9));
      expect(hit.inside, isFalse);
    });

    test('a ray pointing away from a sphere misses it', () {
      expect(raycast(Ray(v(10), v(1)), Sphere(v(0), 1)), isNull);
    });

    test('a ray from inside reports that, and the far wall', () {
      // A camera inside geometry and one looking at it are otherwise the same
      // hit at nothing, and they want opposite handling.
      final hit = raycast(Ray(v(0), v(1)), Sphere(v(0), 2))!;
      expect(hit.inside, isTrue);
      expect(hit.distance, closeTo(2, 1e-9));
    });

    test('a ray past its own reach finds nothing', () {
      expect(raycast(Ray(v(-10), v(1), distance: 5), Sphere(v(0), 1)), isNull);
    });

    test('a box is hit on the face the ray reaches first', () {
      final hit = raycast(Ray(v(-10, 0.2), v(1)), Box(v(0), v(2, 2, 2)))!;
      expect(hit.distance, closeTo(9, 1e-9));
      expect(hit.normal.x, closeTo(-1, 1e-9));
    });

    test('a ray parallel to a box face either misses or passes through', () {
      expect(raycast(Ray(v(-10, 0), v(1)), Box(v(0), v(2, 2, 2))), isNotNull);
      expect(raycast(Ray(v(-10, 5), v(1)), Box(v(0), v(2, 2, 2))), isNull);
    });

    test('a capsule is hit on its side and on its cap', () {
      final body = Capsule(v(0), height: 4, radius: 0.5);
      final side = raycast(Ray(v(-10, 0), v(1)), body)!;
      expect(side.distance, closeTo(9.5, 0.02));

      final cap = raycast(Ray(v(0, 10), v(0, -1)), body)!;
      expect(cap.distance, closeTo(8, 0.02));
    });

    test('a ray with no direction points somewhere rather than at NaN', () {
      final ray = Ray(v(0), Vector3.zero());
      expect(ray.direction.length, closeTo(1, 1e-9));
    });

    test('several shapes come back nearest first', () {
      final shapes = <Shape>[
        Sphere(v(20), 1),
        Sphere(v(5), 1),
        Box(v(12), v(2, 2, 2)),
      ];
      final hits = raycastAll(Ray(v(-10), v(1)), shapes);

      expect(hits.map((h) => h.index), [1, 2, 0]);
      expect(raycastFirst(Ray(v(-10), v(1)), shapes)!.index, 1);
    });
  });

  group('the broadphase', () {
    test('it finds the pairs that a full sweep would', () {
      // The claim of a broadphase: a faster route to the same answer.
      final shapes = <Shape>[
        Sphere(v(0), 1),
        Sphere(v(1.2), 1),
        Sphere(v(40), 1),
        Box(v(1.5, 0.5), v(1, 1, 1)),
      ];
      final grid = Broadphase(cellSize: 4);
      for (final shape in shapes) {
        grid.add(shape);
      }

      final byGrid = grid.pairs().toSet();
      final byHand = <(int, int)>{};
      for (var i = 0; i < shapes.length; i++) {
        for (var j = i + 1; j < shapes.length; j++) {
          if (shapes[i].bounds.overlaps(shapes[j].bounds)) byHand.add((i, j));
        }
      }
      expect(byGrid, byHand);
      expect(byHand, isNotEmpty);
    });

    test(
      'a shape spanning several cells is reported once, not once a cell',
      () {
        // The classic fault, and it reads as being pushed apart four times as
        // hard as it should be.
        final grid = Broadphase(cellSize: 1);
        grid.add(Box(v(0), v(8, 8, 8)));
        grid.add(Box(v(0), v(8, 8, 8)));

        expect(grid.pairs(), hasLength(1));
      },
    );

    test('a query finds what is near a box', () {
      final grid = Broadphase(cellSize: 4);
      grid.add(Sphere(v(0), 1));
      grid.add(Sphere(v(50), 1));

      expect(grid.near(Aabb(v(-2, -2, -2), v(2, 2, 2))), [0]);
    });
  });

  group('layers', () {
    test('either caring is enough', () {
      // A bullet that cares about walls should hit a wall that cares about
      // nothing; requiring both would mean every passive thing listing
      // everything that might touch it.
      const bullet = Layers(is_: 2, cares: 1);
      const wall = Layers(is_: 1, cares: 0);
      expect(Layers.interact(bullet, wall), isTrue);
    });

    test('two things that ignore each other do not interact', () {
      const a = Layers(is_: 2, cares: 4);
      const b = Layers(is_: 8, cares: 16);
      expect(Layers.interact(a, b), isFalse);
    });
  });

  group('two dimensions', () {
    Vector2 p(double x, double y) => Vector2(x, y);

    test('circles and rectangles touch the way their 3D cousins do', () {
      expect(touching(Circle(p(0, 0), 1), Circle(p(5, 0), 1)), isNull);
      expect(
        touching(Circle(p(0, 0), 1), Circle(p(1.5, 0), 1))!.depth,
        closeTo(0.5, 1e-9),
      );
      expect(
        touching(
          Rectangle(p(0, 1.8), p(2, 2)),
          Rectangle(p(0, 0), p(6, 2)),
        )!.normal.y,
        closeTo(1, 1e-9),
      );
    });

    test('a world says what began, what is touching and what ended', () {
      // Only the middle one is easy. A world that reported just the current
      // state would leave every caller keeping its own previous frame.
      final world = World2(cellSize: 8)
        ..add(Body(id: 1, hitbox: Circle(p(0, 0), 1)))
        ..add(Body(id: 2, hitbox: Circle(p(5, 0), 1)));

      var step = world.step();
      expect(step.touching, isEmpty);
      expect(step.began, isEmpty);

      world[2]!.hitbox = Circle(p(1.5, 0), 1);
      step = world.step();
      expect(step.began, hasLength(1));
      expect(step.touching, hasLength(1));

      // Still touching is not beginning again.
      step = world.step();
      expect(step.began, isEmpty);
      expect(step.touching, hasLength(1));

      world[2]!.hitbox = Circle(p(9, 0), 1);
      step = world.step();
      expect(step.ended, [(1, 2)]);
      expect(step.touching, isEmpty);
    });

    test('a passthrough body reports its touch and stops nothing', () {
      final world = World2()
        ..add(Body(id: 1, hitbox: Circle(p(0, 0), 1)))
        ..add(Body(id: 2, hitbox: Circle(p(1.5, 0), 1), passthrough: true));

      final step = world.step();
      expect(step.touching, hasLength(1));

      final before = world[1]!.hitbox.position.clone();
      world.separate(step.touching);
      // A pickup that blocked the player would be the fault this prevents.
      expect(world[1]!.hitbox.position, before);
    });

    test('two solid bodies are pushed apart evenly', () {
      final world = World2()
        ..add(Body(id: 1, hitbox: Circle(p(0, 0), 1)))
        ..add(Body(id: 2, hitbox: Circle(p(1.5, 0), 1)));

      world.separate(world.step().touching);

      // A quarter each, so the order they were added in is not visible.
      expect(world[1]!.hitbox.position.x, closeTo(-0.25, 1e-9));
      expect(world[2]!.hitbox.position.x, closeTo(1.75, 1e-9));
      expect(world.step().touching, isEmpty);
    });

    test('layers keep two things from seeing each other', () {
      final world = World2()
        ..add(Body(id: 1, hitbox: Circle(p(0, 0), 1), is_: 2, cares: 4))
        ..add(Body(id: 2, hitbox: Circle(p(0.5, 0), 1), is_: 8, cares: 16));

      expect(world.step().touching, isEmpty);
    });

    test('a point picks out what is under it', () {
      final world = World2()
        ..add(Body(id: 1, hitbox: Circle(p(0, 0), 1)))
        ..add(Body(id: 2, hitbox: Rectangle(p(10, 0), p(4, 4))));

      expect(world.at(p(0.5, 0)), [1]);
      expect(world.at(p(10, 1)), [2]);
      expect(world.at(p(50, 50)), isEmpty);
    });

    test('a body spanning cells is reported once', () {
      final world = World2(cellSize: 1)
        ..add(Body(id: 1, hitbox: Rectangle(p(0, 0), p(8, 8))))
        ..add(Body(id: 2, hitbox: Rectangle(p(0, 0), p(8, 8))));

      expect(world.step().touching, hasLength(1));
    });
  });
}
