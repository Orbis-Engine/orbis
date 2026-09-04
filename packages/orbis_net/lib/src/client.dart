import 'dart:async';
import 'dart:typed_data';

import 'package:orbis_core/orbis_core.dart';

import 'ack.dart';
import 'codec.dart';
import 'replication.dart';
import 'transport.dart';

/// The replica side: it receives what the authority did and reproduces it.
///
/// The client's world is its own, with its own component ids. Nothing on the
/// wire refers to those — components are identified by their position in the
/// replication set, which is derived from their names. Two builds that declare
/// the same components therefore agree without exchanging a schema, even if
/// they registered them in different orders.
class NetClient {
  NetClient({
    required World world,
    required this.set,
    required ComponentType networkId,
    required Transport transport,
    this.onSpawn,
    this.onDespawn,
  })  : _world = world,
        _networkId = networkId,
        _transport = transport {
    _subscription = transport.inbound.listen(_receive);
  }

  final World _world;
  final ReplicationSet set;
  final ComponentType _networkId;
  final Transport _transport;
  final SnapshotCodec _codec = const SnapshotCodec();

  /// Called after an entity appears, with its local handle.
  final void Function(int networkId, int entity)? onSpawn;

  /// Called before an entity is destroyed locally.
  final void Function(int networkId, int entity)? onDespawn;

  late final StreamSubscription<Uint8List> _subscription;
  final Map<int, int> _entities = {};

  int _lastAppliedTick = 0;

  World get world => _world;

  /// The last tick applied in full. Sent back to the authority so its deltas
  /// are built against something this client has actually seen.
  int get lastAppliedTick => _lastAppliedTick;

  int get entityCount => _entities.length;

  /// The local entity standing in for a network id, if it is present.
  int? entityFor(int networkId) => _entities[networkId];

  Iterable<int> get networkIds => _entities.keys;

  void _receive(Uint8List message) {
    final snapshot = _codec.decode(message);

    // A delta against a tick this client never applied would leave the world
    // partly stale in a way nothing later corrects. Acknowledging honestly
    // instead makes the authority send a full snapshot next time.
    if (snapshot.isDelta && snapshot.baselineTick != _lastAppliedTick) {
      _transport.send(encodeAck(_lastAppliedTick));
      return;
    }

    final seen = <int>{};
    for (final group in snapshot.groups) {
      for (var i = 0; i < group.length; i++) {
        final networkId = group.networkIds[i];
        seen.add(networkId);
        _applyRow(networkId, group.mask, group.rowAt(i));
      }
    }

    for (final networkId in snapshot.despawned) {
      _despawn(networkId);
    }

    // A full snapshot is the whole truth, so anything absent from it is gone —
    // a delta says nothing about the entities it omits.
    if (!snapshot.isDelta) {
      for (final networkId in _entities.keys.toList()) {
        if (!seen.contains(networkId)) _despawn(networkId);
      }
    }

    _lastAppliedTick = snapshot.tick;
    _transport.send(encodeAck(_lastAppliedTick));
  }

  void _applyRow(int networkId, int mask, Uint8List row) {
    var entity = _entities[networkId];
    final isNew = entity == null;
    if (entity == null) {
      entity = _world.createEntity();
      _world.add(entity, _networkId, Uint64List(1)..[0] = networkId);
      _entities[networkId] = entity;
    }

    // The component set is reconciled before anything is written, because
    // adding or removing one moves the entity between archetypes and
    // invalidates every view taken before the move.
    for (final component in set.components) {
      final wanted = mask & (1 << component.bit) != 0;
      final present = _world.has(entity, component.type);
      if (wanted && !present) {
        _world.add(entity, component.type);
      } else if (!wanted && present) {
        _world.remove(entity, component.type);
      }
    }

    var offset = 0;
    for (final bit in set.bitsOf(mask)) {
      final type = set.atBit(bit).type;
      final size = type.byteSize;
      _world.bytesOf(entity, type)!.setRange(0, size, row, offset);
      offset += size;
    }

    if (isNew) onSpawn?.call(networkId, entity);
  }

  void _despawn(int networkId) {
    final entity = _entities.remove(networkId);
    if (entity == null) return;
    onDespawn?.call(networkId, entity);
    _world.destroyEntity(entity);
  }

  Future<void> dispose() => _subscription.cancel();
}
