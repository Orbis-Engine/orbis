import 'dart:async';
import 'dart:typed_data';

import 'package:orbis_core/orbis_core.dart';

import 'ack.dart';
import 'codec.dart';
import 'replication.dart';
import 'snapshot.dart';
import 'transport.dart';

/// One connected peer, from the authority's side.
class _Client {
  _Client(this.id, this.transport, this.subscription);

  final String id;
  final Transport transport;
  final StreamSubscription<Uint8List> subscription;

  /// The last tick this client confirmed applying. Deltas are built against it,
  /// so a client that falls silent simply gets larger messages rather than a
  /// world that drifts.
  int acknowledgedTick = 0;
}

/// The authority: it owns the world and tells clients what happened.
class NetHost {
  NetHost({
    required World world,
    required this.set,
    required ComponentType networkId,
    this.historyDepth = 64,
  })  : _world = world,
        _networkId = networkId,
        _capture = SnapshotCapture(
          world: world,
          set: set,
          networkId: networkId,
        );

  final World _world;
  final ReplicationSet set;
  final ComponentType _networkId;
  final SnapshotCapture _capture;
  final SnapshotCodec _codec = const SnapshotCodec();

  /// How many past snapshots to keep for building deltas. A client further
  /// behind than this is sent a full snapshot instead.
  final int historyDepth;

  final Map<String, _Client> _clients = {};
  final Map<int, WorldSnapshot> _history = {};
  final List<int> _historyOrder = [];

  int _nextNetworkId = 1;
  int _tick = 0;

  World get world => _world;
  int get tick => _tick;
  int get clientCount => _clients.length;

  /// Marks [entity] as replicated and gives it a wire identity.
  int spawn(int entity) {
    final id = _nextNetworkId++;
    final value = Uint64List(1)..[0] = id;
    _world.add(entity, _networkId, value);
    return id;
  }

  /// Stops replicating [entity] and destroys it. Clients are told on the next
  /// publish, by its absence from the snapshot.
  void despawn(int entity) => _world.destroyEntity(entity);

  void addClient(String id, Transport transport) {
    if (_clients.containsKey(id)) {
      throw StateError('A client is already connected as "$id".');
    }
    late final _Client client;
    final subscription = transport.inbound.listen((message) {
      final acked = decodeAck(message);
      if (acked != null && acked > client.acknowledgedTick) {
        client.acknowledgedTick = acked;
      }
    });
    client = _Client(id, transport, subscription);
    _clients[id] = client;
  }

  Future<void> removeClient(String id) async {
    final client = _clients.remove(id);
    if (client == null) return;
    await client.subscription.cancel();
  }

  /// Captures the world and sends each client what it has not seen.
  ///
  /// The capture happens once no matter how many clients are connected; only
  /// the diff is per client, and that is a comparison rather than a re-read.
  void publish() {
    _tick++;
    final current = _capture.capture(_tick);

    for (final client in _clients.values) {
      final baseline = _history[client.acknowledgedTick];
      final message = baseline == null
          ? _codec.encodeFull(current)
          : _codec.encodeDelta(current, baseline);
      client.transport.send(message);
    }

    _remember(current);
  }

  void _remember(WorldSnapshot snapshot) {
    _history[snapshot.tick] = snapshot;
    _historyOrder.add(snapshot.tick);
    while (_historyOrder.length > historyDepth) {
      _history.remove(_historyOrder.removeAt(0));
    }
  }

  Future<void> dispose() async {
    for (final client in _clients.values) {
      await client.subscription.cancel();
    }
    _clients.clear();
    _capture.dispose();
  }
}
