/// Orbis replication over [dashwire](https://pub.dev/packages/dashwire).
///
/// Kept out of `orbis_net` so the replication layer depends on nothing but the
/// engine core, and a project that wants a different transport pays nothing
/// for this one.
library;

export 'src/dashwire_transport.dart' show DashwireTransport;
