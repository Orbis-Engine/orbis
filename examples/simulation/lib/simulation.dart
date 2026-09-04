import 'dart:math' as math;
import 'dart:typed_data';

import 'package:orbis_core/orbis_core.dart';
import 'package:orbis_net/orbis_net.dart';

/// A small world that exercises the parts of the engine that have to agree:
/// storage, the transform hierarchy, a system written in Dart over views, and
/// replication of the result.
///
/// Deliberately headless. The renderer is a separate concern with its own
/// proof, and a simulation that only runs inside a window cannot be tested.
class Simulation {
  Simulation() {
    world = World();
    transforms = world.registerTransforms();
    velocity = world.registerComponent(
      'Velocity',
      kind: ComponentKind.float32,
      arity: 3,
    );
    networkId = world.registerComponent('NetworkId', kind: ComponentKind.int64);

    // The world transform is what replicates: a client needs where things
    // ended up, not the parent links that got them there.
    replication = ReplicationSet([transforms.world, velocity]);
    _movers = world.query([transforms.local, velocity]);
  }

  late final World world;
  late final TransformComponents transforms;
  late final ComponentType velocity;
  late final ComponentType networkId;
  late final ReplicationSet replication;
  late final Query _movers;

  /// A body that moves under its own velocity.
  int spawnBody({required double x, required double y, required double speed}) {
    final entity = world.createEntity();
    world.add(entity, transforms.local, transform(x: x, y: y));
    world.add(entity, transforms.world);
    world.add(entity, velocity, Float32List.fromList([speed, 0, 0]));
    return entity;
  }

  /// Something carried by another entity, in its parent's space.
  int attach(int parent, {required double offsetY}) {
    final entity = world.createEntity();
    world.add(entity, transforms.local, transform(y: offsetY));
    world.add(entity, transforms.world);
    world.add(entity, transforms.parent, Int64List.fromList([parent]));
    return entity;
  }

  /// Turns an entity about Y, in place.
  void setSpin(int entity, double radians) {
    final local = world.float32Of(entity, transforms.local)!;
    local[4] = math.sin(radians / 2); // quaternion y
    local[6] = math.cos(radians / 2); // quaternion w
  }

  /// One step of the simulation.
  ///
  /// The movement pass is the shape every Dart system should have: fetch the
  /// columns once, then loop entirely in Dart. Nothing here calls into the
  /// engine per entity.
  void step(double delta) {
    for (final chunk in _movers.chunks) {
      final locals = chunk.float32(0);
      final velocities = chunk.float32(1);
      for (var row = 0; row < chunk.length; row++) {
        final l = row * 10;
        final v = row * 3;
        locals[l] += velocities[v] * delta;
        locals[l + 1] += velocities[v + 1] * delta;
        locals[l + 2] += velocities[v + 2] * delta;
      }
    }

    // Children follow their parents only once the parents have moved, so this
    // runs after the movement pass rather than beside it.
    world.propagateTransforms();
  }

  void dispose() {
    _movers.dispose();
    world.dispose();
  }
}

/// Where an entity ended up, read out of its world matrix.
List<double> worldPositionOf(World world, TransformComponents t, int entity) {
  final matrix = world.float32Of(entity, t.world)!;
  return [matrix[12], matrix[13], matrix[14]];
}
