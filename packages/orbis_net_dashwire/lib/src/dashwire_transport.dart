import 'dart:async';
import 'dart:typed_data';

import 'package:dashwire/dashwire.dart';
import 'package:orbis_net/orbis_net.dart';

/// Carries Orbis replication over a dashwire connection.
///
/// The adapter is this thin on purpose. dashwire already handles sockets,
/// reliability over UDP, session handshake and clock sync; Orbis handles
/// turning a world into bytes. Neither needs to know much about the other, and
/// the seam being small is what keeps a second transport cheap to add.
class DashwireTransport implements Transport {
  DashwireTransport(
    this._connection, {
    this.channel = Channel.unreliable,
  });

  final WireConnection _connection;

  /// Which dashwire channel snapshots and acknowledgements travel on.
  ///
  /// Unreliable by default, which is safe here rather than merely fast. A lost
  /// snapshot does not break the delta chain, because deltas are built against
  /// the tick a client last acknowledged rather than against the last thing
  /// sent — so loss costs one larger message and nothing desynchronises. A game
  /// sending discrete, non-superseding actions through this transport should
  /// use the reliable channel for those instead.
  final Channel channel;

  bool get isOpen => _connection.isOpen;

  /// Completes when the underlying connection does.
  Future<void> get done => _connection.done;

  @override
  Stream<Uint8List> get inbound =>
      _connection.messages.map((message) => message.payload);

  @override
  void send(Uint8List message) {
    if (!_connection.isOpen) return;
    _connection.send(channel, message);
  }

  @override
  Future<void> close() => _connection.close();
}
