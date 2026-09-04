import 'dart:math' as math;
import 'dart:typed_data';

import 'package:orbis_core/orbis_core.dart';
import 'package:test/test.dart';

/// A quaternion for a rotation about Y, so a test can express a turn without a
/// maths dependency.
Float32List turnY(double radians) => transform(
      rotationY: math.sin(radians / 2),
      rotationW: math.cos(radians / 2),
    );

/// The translation column of a column-major 4x4.
List<double> translationOf(Float32List matrix) =>
    [matrix[12], matrix[13], matrix[14]];

void main() {
  late World world;
  late TransformComponents t;

  setUp(() {
    world = World();
    t = world.registerTransforms();
  });

  tearDown(() => world.dispose());

  int spawn(Float32List local, {int? parent}) {
    final entity = world.createEntity();
    world.add(entity, t.local, local);
    world.add(entity, t.world);
    if (parent != null) {
      world.add(entity, t.parent, Int64List.fromList([parent]));
    }
    return entity;
  }

  test('registering twice returns the same components', () {
    final again = world.registerTransforms();
    expect(again.local.id, t.local.id);
    expect(again.world.id, t.world.id);
    expect(again.parent.id, t.parent.id);
  });

  test('a root takes its local transform as its world transform', () {
    final entity = spawn(transform(x: 1, y: 2, z: 3));
    expect(world.propagateTransforms(), 1);

    final matrix = world.float32Of(entity, t.world)!;
    expect(translationOf(matrix), [1, 2, 3]);
    // No rotation and unit scale, so the basis is the identity.
    expect(matrix[0], 1);
    expect(matrix[5], 1);
    expect(matrix[10], 1);
    expect(matrix[15], 1);
  });

  test('scale reaches the basis, not the translation', () {
    final entity = spawn(transform(x: 5, scaleX: 2, scaleY: 3, scaleZ: 4));
    world.propagateTransforms();

    final matrix = world.float32Of(entity, t.world)!;
    expect(matrix[0], 2);
    expect(matrix[5], 3);
    expect(matrix[10], 4);
    expect(translationOf(matrix), [5, 0, 0]);
  });

  test('a child is placed in its parent\'s space', () {
    final parent = spawn(transform(x: 10));
    final child = spawn(transform(x: 1), parent: parent);

    expect(world.propagateTransforms(), 2);
    expect(translationOf(world.float32Of(child, t.world)!), [11, 0, 0]);
  });

  test('a parent\'s rotation turns where its child ends up', () {
    // A quarter turn about Y sends local +X to world -Z.
    final parent = spawn(turnY(math.pi / 2));
    final child = spawn(transform(x: 1), parent: parent);
    world.propagateTransforms();

    final position = translationOf(world.float32Of(child, t.world)!);
    expect(position[0], closeTo(0, 1e-5));
    expect(position[2], closeTo(-1, 1e-5));
  });

  test('a chain composes down its whole depth', () {
    var previous = spawn(transform(x: 1));
    for (var i = 0; i < 9; i++) {
      previous = spawn(transform(x: 1), parent: previous);
    }
    expect(world.propagateTransforms(), 10);
    expect(translationOf(world.float32Of(previous, t.world)!)[0], 10);
  });

  test('reparenting is a component write, not a rebuild', () {
    final left = spawn(transform(x: 100));
    final right = spawn(transform(x: 200));
    final child = spawn(transform(x: 1), parent: left);

    world.propagateTransforms();
    expect(translationOf(world.float32Of(child, t.world)!)[0], 101);

    Int64List.sublistView(
        Int64List.view(world.bytesOf(child, t.parent)!.buffer, 0, 1))[0] = right;
    world.propagateTransforms();
    expect(translationOf(world.float32Of(child, t.world)!)[0], 201);
  });

  test('an entity with no parent component is a root', () {
    final entity = spawn(transform(y: 7));
    expect(world.has(entity, t.parent), isFalse);
    world.propagateTransforms();
    expect(translationOf(world.float32Of(entity, t.world)!), [0, 7, 0]);
  });

  test('a parent that has been destroyed is ignored rather than followed', () {
    final parent = spawn(transform(x: 10));
    final child = spawn(transform(x: 1), parent: parent);
    world.destroyEntity(parent);

    world.propagateTransforms();
    expect(translationOf(world.float32Of(child, t.world)!)[0], 1,
        reason: 'a dangling parent handle should leave the child at its local '
            'transform, not crash or inherit a reused slot');
  });

  test('a cycle terminates instead of hanging', () {
    final a = spawn(transform(x: 1));
    final b = spawn(transform(x: 1), parent: a);
    // Close the loop: a's parent becomes b.
    world.add(a, t.parent, Int64List.fromList([b]));

    expect(world.propagateTransforms, returnsNormally);
  });

  test('a deep hierarchy resolves each ancestor once', () {
    // One chain of 200, plus 200 leaves hanging off its end. A naive walk would
    // re-resolve the chain per leaf; memoisation makes it one pass.
    var trunk = spawn(transform(x: 1));
    for (var i = 0; i < 199; i++) {
      trunk = spawn(transform(x: 1), parent: trunk);
    }
    for (var i = 0; i < 200; i++) {
      spawn(transform(y: 1), parent: trunk);
    }

    final stopwatch = Stopwatch()..start();
    expect(world.propagateTransforms(), 400);
    stopwatch.stop();

    // ignore: avoid_print
    print('  400 transforms over a 200-deep chain in '
        '${stopwatch.elapsedMicroseconds}us');
    expect(translationOf(world.float32Of(trunk, t.world)!)[0], 200);
  });

  test('transforms are a query like anything else', () {
    for (var i = 0; i < 5; i++) {
      spawn(transform(x: i.toDouble()));
    }
    world.propagateTransforms();

    final query = world.query([t.world]);
    addTearDown(query.dispose);

    var total = 0.0;
    for (final chunk in query.chunks) {
      final matrices = chunk.float32(0);
      for (var row = 0; row < chunk.length; row++) {
        total += matrices[row * 16 + 12];
      }
    }
    expect(total, 0 + 1 + 2 + 3 + 4);
  });
}
