import 'dart:async';
import 'dart:typed_data';

/// A duplex link to one peer.
///
/// Orbis does not ship a transport. Dart already has good ones —
/// [dashwire](https://pub.dev/packages/dashwire) covers sockets, reliability
/// over UDP, and session handshake — and rebuilding that would be the same
/// mistake as rebuilding Filament. What Orbis contributes is the layer above:
/// turning a world into bytes and back. This interface is the seam between
/// them, small enough that adapting any transport is a morning's work.
abstract interface class Transport {
  /// Messages from the peer, already framed. A transport that cannot preserve
  /// message boundaries has to add framing before satisfying this.
  Stream<Uint8List> get inbound;

  /// Sends one message. Ordering and delivery guarantees are the transport's
  /// to state; replication is written to survive loss and reordering.
  void send(Uint8List message);

  Future<void> close();
}

/// Two transports wired to each other in this process.
///
/// Useful well beyond tests: a single-player build and a listen server can run
/// the real replication path over a loopback link, so the networked code path
/// is the only code path and does not rot when nobody is testing multiplayer.
class LoopbackLink {
  LoopbackLink({this.latency = Duration.zero}) {
    final left = _LoopbackTransport(latency);
    final right = _LoopbackTransport(latency);
    left._peer = right;
    right._peer = left;
    host = left;
    client = right;
  }

  /// Delay applied to every message in each direction, for exercising
  /// interpolation and reconciliation without a network.
  final Duration latency;

  late final Transport host;
  late final Transport client;

  Future<void> close() async {
    await host.close();
    await client.close();
  }
}

class _LoopbackTransport implements Transport {
  _LoopbackTransport(this._latency);

  final Duration _latency;
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  late final _LoopbackTransport _peer;
  bool _closed = false;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  void send(Uint8List message) {
    if (_closed) return;
    // Copied on the way out: the caller is free to reuse its buffer, which the
    // capture path does on every tick.
    final copy = Uint8List.fromList(message);
    if (_latency == Duration.zero) {
      scheduleMicrotask(() => _peer._deliver(copy));
    } else {
      Timer(_latency, () => _peer._deliver(copy));
    }
  }

  void _deliver(Uint8List message) {
    if (_closed || _inbound.isClosed) return;
    _inbound.add(message);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inbound.close();
  }
}
