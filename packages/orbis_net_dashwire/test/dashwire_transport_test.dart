import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:orbis_core/orbis_core.dart';
import 'package:orbis_net/orbis_net.dart';
import 'package:orbis_net_dashwire/orbis_net_dashwire.dart';
import 'package:test/test.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

/// A world and the components it replicates. Registered in a different order
/// on each side, since the wire must not depend on local ids.
class Peer {
  Peer({required bool reversed}) {
    world = World();
    if (reversed) {
      velocity = world.registerComponent(
        'Velocity',
        kind: ComponentKind.float32,
        arity: 3,
      );
      position = world.registerComponent(
        'Position',
        kind: ComponentKind.float32,
        arity: 3,
      );
      networkId = world.registerComponent(
        'NetworkId',
        kind: ComponentKind.int64,
      );
    } else {
      networkId = world.registerComponent(
        'NetworkId',
        kind: ComponentKind.int64,
      );
      position = world.registerComponent(
        'Position',
        kind: ComponentKind.float32,
        arity: 3,
      );
      velocity = world.registerComponent(
        'Velocity',
        kind: ComponentKind.float32,
        arity: 3,
      );
    }
    set = ReplicationSet([position, velocity]);
  }

  late final World world;
  late final ComponentType networkId;
  late final ComponentType position;
  late final ComponentType velocity;
  late final ReplicationSet set;

  void dispose() => world.dispose();
}

void main() {
  test('a session replicates over a dashwire connection', () async {
    final (hostWire, clientWire) = LoopbackConnection.pair();
    final host = Peer(reversed: false);
    final client = Peer(reversed: true);
    addTearDown(host.dispose);
    addTearDown(client.dispose);

    final hostTransport = DashwireTransport(hostWire);
    final clientTransport = DashwireTransport(clientWire);

    final netHost = NetHost(
      world: host.world,
      set: host.set,
      networkId: host.networkId,
    );
    final netClient = NetClient(
      world: client.world,
      set: client.set,
      networkId: client.networkId,
      transport: clientTransport,
    );
    netHost.addClient('player-1', hostTransport);
    addTearDown(() async {
      await netClient.dispose();
      await netHost.dispose();
    });

    final entity = host.world.createEntity();
    final networkId = netHost.spawn(entity);
    host.world.add(entity, host.position, Float32List.fromList([1, 2, 3]));

    netHost.publish();
    await settle();

    final replica = netClient.entityFor(networkId);
    expect(replica, isNotNull);
    expect(client.world.float32Of(replica!, client.position), [1, 2, 3]);

    // The acknowledgement made it back, so the next publish is a delta.
    expect(netClient.lastAppliedTick, 1);
    host.world.float32Of(entity, host.position)![0] = 9;
    netHost.publish();
    await settle();
    expect(client.world.float32Of(replica, client.position)![0], 9);
  });

  test('defaults to the unreliable channel', () {
    final (a, _) = LoopbackConnection.pair();
    expect(
      DashwireTransport(a).channel,
      Channel.unreliable,
      reason:
          'acknowledged baselines make loss survivable, so snapshots do '
          'not need the reliable channel',
    );
    expect(
      DashwireTransport(a, channel: Channel.reliable).channel,
      Channel.reliable,
    );
  });

  test('a closed connection swallows sends rather than throwing', () async {
    final (a, _) = LoopbackConnection.pair();
    final transport = DashwireTransport(a);
    await transport.close();
    expect(transport.isOpen, isFalse);
    expect(() => transport.send(Uint8List(4)), returnsNormally);
  });
}
