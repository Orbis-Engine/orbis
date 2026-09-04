import 'dart:typed_data';

import 'package:orbis_core/orbis_core.dart';
import 'package:test/test.dart';

void main() {
  late World world;
  late ComponentType position;
  late ComponentType velocity;

  setUp(() {
    world = World();
    position =
        world.registerComponent('Position', kind: ComponentKind.float32, arity: 3);
    velocity =
        world.registerComponent('Velocity', kind: ComponentKind.float32, arity: 3);
  });

  tearDown(() => world.dispose());

  group('components', () {
    test('register with distinct ids', () {
      expect(position.id, isNot(0));
      expect(velocity.id, isNot(position.id));
      expect(world.componentCount, 2);
    });

    test('re-registering an identical layout returns the same type', () {
      final again =
          world.registerComponent('Position', kind: ComponentKind.float32, arity: 3);
      expect(again.id, position.id);
    });

    test('re-registering a different layout is refused', () {
      expect(
        () => world.registerComponent('Position', kind: ComponentKind.int32),
        throwsArgumentError,
      );
    });
  });

  group('entities', () {
    test('are created alive and counted', () {
      final entity = world.createEntity();
      expect(entity, isNot(0));
      expect(world.isAlive(entity), isTrue);
      expect(world.entityCount, 1);
    });

    test('a stale handle stays dead once its slot is reused', () {
      final first = world.createEntity();
      world.destroyEntity(first);
      expect(world.isAlive(first), isFalse);

      final second = world.createEntity();
      expect(world.isAlive(second), isTrue);
      // The generation is what makes this detectable rather than an alias.
      expect(second, isNot(first));
      expect(world.isAlive(first), isFalse,
          reason: 'the old handle must not address the new entity');
    });

    test('using a dead handle is refused rather than silently ignored', () {
      final entity = world.createEntity();
      world.destroyEntity(entity);
      expect(() => world.add(entity, position), throwsA(isA<DeadEntityError>()));
    });
  });

  group('components on entities', () {
    test('add, read back, remove', () {
      final entity = world.createEntity();
      world.add(entity, position, Float32List.fromList([1, 2, 3]));

      expect(world.has(entity, position), isTrue);
      expect(world.float32Of(entity, position), [1, 2, 3]);

      expect(world.remove(entity, position), isTrue);
      expect(world.has(entity, position), isFalse);
      expect(world.float32Of(entity, position), isNull);
    });

    test('a component with no value starts zeroed', () {
      final entity = world.createEntity();
      world.add(entity, position);
      expect(world.float32Of(entity, position), [0, 0, 0]);
    });

    test('adding twice is refused', () {
      final entity = world.createEntity();
      world.add(entity, position);
      expect(() => world.add(entity, position), throwsStateError);
    });

    test('other components survive a removal', () {
      final entity = world.createEntity();
      world.add(entity, position, Float32List.fromList([7, 8, 9]));
      world.add(entity, velocity, Float32List.fromList([1, 1, 1]));

      world.remove(entity, velocity);
      expect(world.float32Of(entity, position), [7, 8, 9],
          reason: 'moving archetypes must carry the shared components across');
    });
  });

  group('queries', () {
    test('match only entities carrying every component', () {
      for (var i = 0; i < 10; i++) {
        final entity = world.createEntity();
        world.add(entity, position);
        if (i.isEven) world.add(entity, velocity);
      }

      final query = world.query([position, velocity]);
      addTearDown(query.dispose);
      expect(query.entityCount, 5);
    });

    test('refresh after a structural change', () {
      final entity = world.createEntity();
      world.add(entity, position);
      world.add(entity, velocity);

      final query = world.query([position, velocity]);
      addTearDown(query.dispose);
      expect(query.entityCount, 1);

      world.remove(entity, velocity);
      expect(query.entityCount, 0,
          reason: 'the query must notice the entity left its archetype');
    });

    test('a write through a column lands on the right entity', () {
      final entities = [
        for (var i = 0; i < 4; i++) world.createEntity(),
      ];
      for (var i = 0; i < entities.length; i++) {
        world.add(entities[i], position,
            Float32List.fromList([i.toDouble(), 0, 0]));
      }

      final query = world.query([position]);
      addTearDown(query.dispose);

      for (final chunk in query.chunks) {
        final values = chunk.float32(0);
        final handles = chunk.entities;
        for (var row = 0; row < chunk.length; row++) {
          // Prove the entity list and the column agree row for row.
          final expected = entities.indexOf(handles[row]).toDouble();
          expect(values[row * 3], expected);
          values[row * 3] = expected + 100;
        }
      }

      for (var i = 0; i < entities.length; i++) {
        expect(world.float32Of(entities[i], position)![0], i + 100);
      }
    });

    test('a chunk reports components the query did not ask for', () {
      final entity = world.createEntity();
      world.add(entity, position, Float32List.fromList([1, 2, 3]));
      world.add(entity, velocity, Float32List.fromList([4, 5, 6]));

      // Queried on position alone, but the run still knows it carries velocity
      // — which is how replication decides what to send.
      final query = world.query([position]);
      addTearDown(query.dispose);

      final chunk = query.chunks.first;
      expect(chunk.componentIds, containsAll([position.id, velocity.id]));
      expect(chunk.float32OfComponent(velocity), [4, 5, 6]);
    });

    test('a component the run does not carry reads as null', () {
      final entity = world.createEntity();
      world.add(entity, position);
      final query = world.query([position]);
      addTearDown(query.dispose);

      expect(query.chunks.first.float32OfComponent(velocity), isNull);
    });

    test('asking for the wrong element type is refused', () {
      final entity = world.createEntity();
      world.add(entity, position);
      final query = world.query([position]);
      addTearDown(query.dispose);

      final chunk = query.chunks.first;
      expect(() => chunk.int32(0), throwsArgumentError);
    });
  });

  group('the M2 exit criterion', () {
    test('a Dart system moves ten thousand entities in one crossing', () {
      const count = 10000;
      final entities = <int>[];
      for (var i = 0; i < count; i++) {
        final entity = world.createEntity();
        world.add(entity, position, Float32List.fromList([i.toDouble(), 0, 0]));
        world.add(entity, velocity, Float32List.fromList([2, 0, 0]));
        entities.add(entity);
      }
      expect(world.entityCount, count);

      final query = world.query([position, velocity]);
      addTearDown(query.dispose);

      // Every entity shares one archetype, so the whole world is one run: the
      // system touches the boundary to fetch the columns and then works
      // entirely in Dart over the engine's own memory.
      expect(query.chunks.length, 1,
          reason: 'entities with identical component sets share an archetype');

      const delta = 0.5;
      final stopwatch = Stopwatch()..start();
      for (final chunk in query.chunks) {
        final positions = chunk.float32(0);
        final velocities = chunk.float32(1);
        for (var i = 0; i < positions.length; i++) {
          positions[i] += velocities[i] * delta;
        }
      }
      stopwatch.stop();

      // Correctness first: x started at i and should have advanced by 1.
      for (var i = 0; i < count; i += 997) {
        expect(world.float32Of(entities[i], position)![0], closeTo(i + 1, 1e-3));
      }

      // Reported rather than asserted — a timing bound would be flaky on
      // shared hardware, but a regression into per-entity calls would show
      // here as orders of magnitude.
      // ignore: avoid_print
      print('  10k entities advanced in ${stopwatch.elapsedMicroseconds}us '
          '(one boundary crossing)');
    });
  });

  group('lifetime', () {
    test('use after dispose is refused rather than crashing', () {
      final other = World()..dispose();
      expect(other.isDisposed, isTrue);
      expect(() => other.createEntity(), throwsStateError);
      expect(other.dispose, returnsNormally);
    });

    test('a disposed query is refused', () {
      final query = world.query([position])..dispose();
      expect(() => query.entityCount, throwsStateError);
    });
  });

  test('tick accumulates elapsed time', () {
    world.tick(0.25);
    world.tick(0.25);
    expect(world.elapsed, closeTo(0.5, 1e-9));
  });
}
