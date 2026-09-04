import 'dart:math' as math;

import 'package:orbis_net/orbis_net.dart';
import 'package:orbis_simulation_example/simulation.dart';
import 'package:test/test.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('a hierarchy moves with its parent', () {
    final sim = Simulation();
    addTearDown(sim.dispose);

    final body = sim.spawnBody(x: 0, y: 0, speed: 2);
    final carried = sim.attach(body, offsetY: 1);

    for (var i = 0; i < 10; i++) {
      sim.step(0.1);
    }

    // Two units per second for one second.
    expect(
      worldPositionOf(sim.world, sim.transforms, body)[0],
      closeTo(2, 1e-4),
    );
    final child = worldPositionOf(sim.world, sim.transforms, carried);
    expect(
      child[0],
      closeTo(2, 1e-4),
      reason: 'the attachment should travel with what carries it',
    );
    expect(child[1], closeTo(1, 1e-4));
  });

  test('a parent\'s rotation moves its attachment around it', () {
    final sim = Simulation();
    addTearDown(sim.dispose);

    final body = sim.spawnBody(x: 0, y: 0, speed: 0);
    final carried = sim.attach(body, offsetY: 2);
    sim.setSpin(body, math.pi); // half turn about Y
    sim.step(0);

    final position = worldPositionOf(sim.world, sim.transforms, carried);
    // A turn about Y leaves something directly above unmoved.
    expect(position[1], closeTo(2, 1e-4));
    expect(position[0], closeTo(0, 1e-4));
  });

  test('the whole slice composes: simulate, propagate, replicate', () async {
    final host = Simulation();
    final replica = Simulation();
    addTearDown(host.dispose);
    addTearDown(replica.dispose);

    final link = LoopbackLink();
    final netHost = NetHost(
      world: host.world,
      set: host.replication,
      networkId: host.networkId,
    );
    final netClient = NetClient(
      world: replica.world,
      set: replica.replication,
      networkId: replica.networkId,
      transport: link.client,
    );
    netHost.addClient('player-1', link.host);
    addTearDown(() async {
      await netClient.dispose();
      await netHost.dispose();
      await link.close();
    });

    // A body carrying an attachment. Both replicate, but only by their world
    // transforms — the client is told where things are, not how they got there.
    final body = host.spawnBody(x: 0, y: 0, speed: 3);
    final carried = host.attach(body, offsetY: 1);
    final bodyId = netHost.spawn(body);
    final carriedId = netHost.spawn(carried);

    for (var tick = 0; tick < 20; tick++) {
      host.step(1 / 20);
      netHost.publish();
      await settle();
    }

    expect(netClient.entityCount, 2);

    final hostBody = worldPositionOf(host.world, host.transforms, body);
    final replicaBody = worldPositionOf(
      replica.world,
      replica.transforms,
      netClient.entityFor(bodyId)!,
    );
    expect(replicaBody[0], closeTo(hostBody[0], 1e-4));
    expect(hostBody[0], closeTo(3, 1e-3));

    final hostCarried = worldPositionOf(host.world, host.transforms, carried);
    final replicaCarried = worldPositionOf(
      replica.world,
      replica.transforms,
      netClient.entityFor(carriedId)!,
    );
    expect(replicaCarried[0], closeTo(hostCarried[0], 1e-4));
    expect(
      replicaCarried[1],
      closeTo(1, 1e-4),
      reason:
          'the attachment arrives already in world space, with no '
          'parent link on the client at all',
    );

    expect(
      replica.world.has(
        netClient.entityFor(carriedId)!,
        replica.transforms.parent,
      ),
      isFalse,
      reason:
          'hierarchy is the authority\'s business; a replica needs the '
          'result, not the structure',
    );
  });

  test(
    'a thousand bodies step and replicate without per-entity calls',
    () async {
      final host = Simulation();
      final replica = Simulation();
      addTearDown(host.dispose);
      addTearDown(replica.dispose);

      final link = LoopbackLink();
      final netHost = NetHost(
        world: host.world,
        set: host.replication,
        networkId: host.networkId,
      );
      final netClient = NetClient(
        world: replica.world,
        set: replica.replication,
        networkId: replica.networkId,
        transport: link.client,
      );
      netHost.addClient('player-1', link.host);
      addTearDown(() async {
        await netClient.dispose();
        await netHost.dispose();
        await link.close();
      });

      const count = 1000;
      for (var i = 0; i < count; i++) {
        netHost.spawn(host.spawnBody(x: i.toDouble(), y: 0, speed: 1));
      }

      final stopwatch = Stopwatch()..start();
      for (var tick = 0; tick < 10; tick++) {
        host.step(1 / 60);
        netHost.publish();
        await settle();
      }
      stopwatch.stop();

      expect(netClient.entityCount, count);
      // ignore: avoid_print
      print(
        '  $count bodies, 10 ticks of simulate + propagate + replicate: '
        '${stopwatch.elapsedMilliseconds}ms',
      );
    },
  );
}
