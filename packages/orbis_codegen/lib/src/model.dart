/// What the generator learned about one component class.
class ComponentDeclaration {
  const ComponentDeclaration({
    required this.name,
    required this.className,
    required this.kind,
    required this.fields,
    required this.replicated,
    required this.ownerWritable,
    required this.source,
  });

  /// The name that crosses the wire and keys the manifest.
  final String name;

  /// The Dart class it was declared on.
  final String className;

  /// Storage kind, as an Orbis component kind name.
  final String kind;

  /// Field names, in declaration order — which is also their order in memory.
  final List<String> fields;

  final bool replicated;
  final bool ownerWritable;

  /// Where it was declared, relative to the package root.
  final String source;

  int get arity => fields.length;

  Map<String, Object?> toJson() => {
    'name': name,
    'class': className,
    'kind': kind,
    'arity': arity,
    'fields': fields,
    'replicated': replicated,
    if (replicated) 'ownerWritable': ownerWritable,
    'source': source,
  };
}

/// A problem with a declaration, reported with enough context to fix it.
class ComponentError {
  const ComponentError(this.source, this.className, this.message);

  final String source;
  final String className;
  final String message;

  @override
  String toString() => '$source: $className — $message';
}

/// Everything found in one package.
///
/// Ordered by name on the way in rather than by whichever entry point built it,
/// so a manifest is reproducible and two scans of the same sources compare
/// equal.
class ScanResult {
  ScanResult(List<ComponentDeclaration> found, this.errors)
    // Annotated because List.unmodifiable takes a bare Iterable, which
    // gives the literal no type context and infers dynamic elements.
    : components = List.unmodifiable(
        <ComponentDeclaration>[...found]
          ..sort((a, b) => a.name.compareTo(b.name)),
      );

  final List<ComponentDeclaration> components;
  final List<ComponentError> errors;

  bool get hasErrors => errors.isNotEmpty;
}
