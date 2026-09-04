import 'package:orbis_codegen/annotations.dart';

/// How fast a body is moving, in world units per second.
///
/// Owner-writable: a client drives its own body, and the authority decides
/// where that got it.
@OrbisComponent(replicated: true, ownerWritable: true)
class Velocity {
  double x = 0;
  double y = 0;
  double z = 0;
}

/// A replicated entity's stable identity on the wire.
///
/// Declared int64 rather than left to infer: `int` defaults to a 32-bit
/// column, and identities outlive that.
@OrbisComponent(kind: OrbisKind.int64)
class NetworkId {
  int value = 0;
}
