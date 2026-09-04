/// Annotations a game puts on its component classes.
///
/// Kept in their own library with no dependencies, so declaring a component
/// costs a game nothing at run time — the generator reads these, the built
/// program does not.
library;

/// How a component's fields are stored.
enum OrbisKind { float32, float64, int32, uint32, int64, uint8 }

/// Marks a class as a component.
///
/// Every field must have the same type. That is a real constraint and a
/// deliberate one: a component is one contiguous column, and a struct mixing a
/// double with an int would have to be stored as opaque bytes, losing the typed
/// views that make a system cheap. Splitting `Body { mass, layer }` into `Mass`
/// and `Layer` is also the more idiomatic shape — entities compose from small
/// components rather than carrying wide ones.
class OrbisComponent {
  const OrbisComponent({
    this.name,
    this.kind,
    this.replicated = false,
    this.ownerWritable = false,
  });

  /// The name both ends of a network session agree on. Defaults to the class
  /// name; worth setting explicitly if the class is ever renamed, since the
  /// name is what crosses the wire.
  final String? name;

  /// Overrides the storage inferred from the field types — `double` becomes
  /// float32 and `int` becomes int32 unless this says otherwise.
  final OrbisKind? kind;

  /// Whether this component takes part in network replication.
  final bool replicated;

  /// Whether the client owning an entity may write this component. Meaningless
  /// unless [replicated]; see the networking notes on why this is a security
  /// surface rather than bookkeeping.
  final bool ownerWritable;
}
