/// Multiplayer for Orbis.
///
/// Replication reads component columns rather than walking entities, so
/// capturing a world costs a handful of contiguous copies instead of a lookup
/// per entity. Transport is deliberately not included: Dart already has
/// [dashwire](https://pub.dev/packages/dashwire) for sockets, reliability and
/// session handshake, and [Transport] is the seam to it.
library;

export 'src/ack.dart' show decodeAck, encodeAck;
export 'src/client.dart' show NetClient;
export 'src/codec.dart'
    show DecodedSnapshot, SnapshotCodec, SnapshotFormatError;
export 'src/host.dart' show InputRejection, NetHost;
export 'src/input.dart' show InputEntry, InputMessage, decodeInput, encodeInput;
export 'src/replication.dart' show ReplicatedComponent, ReplicationSet;
export 'src/snapshot.dart'
    show SnapshotCapture, SnapshotGroup, SnapshotRow, WorldSnapshot;
export 'src/transport.dart' show LoopbackLink, Transport;
