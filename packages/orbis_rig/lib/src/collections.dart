import 'naming.dart';

/// A named group of bones, shown or hidden together.
///
/// A generated rig runs to hundreds of bones and an animator wants a dozen of
/// them at a time. Collections are how the rest get out of the way — the face
/// while animating a walk, the machinery always.
class BoneCollection {
  const BoneCollection({required this.name, this.visible = true, this.colour});

  final String name;

  /// Whether the collection starts shown.
  ///
  /// Machinery starts hidden. It is not an animator's to touch, and a rig that
  /// opens showing every mechanism bone reads as broken.
  final bool visible;

  /// A colour for the controls in this collection, as 0xRRGGBB.
  ///
  /// Left and right get different colours in every rig anyone actually uses,
  /// because telling them apart in a mirrored pose is otherwise guesswork.
  final int? colour;

  @override
  String toString() => 'BoneCollection($name)';
}

/// Which bones are in which collections.
///
/// Many-to-many: a left arm's inverse controls belong to both "Arm.L" and
/// "IK", and being able to hide either is the point.
class BoneCollections {
  BoneCollections();

  final Map<String, BoneCollection> _collections = {};
  final Map<String, Set<String>> _members = {};

  /// The colours sides are drawn in. Warm on the left, cool on the right,
  /// which is the convention nearly every rig follows.
  static const leftColour = 0xE5893F;
  static const rightColour = 0x4F86C6;
  static const centreColour = 0x8FB84F;

  Iterable<BoneCollection> get all => _collections.values;

  BoneCollection? operator [](String name) => _collections[name];

  bool contains(String name) => _collections.containsKey(name);

  /// Declares a collection, or leaves an existing one alone.
  ///
  /// Idempotent because rig types declare the collections they use as they
  /// generate, and both arms declare "IK" — the second one saying so is not a
  /// mistake worth reporting.
  BoneCollection declare(String name, {bool visible = true, int? colour}) =>
      _collections[name] ??= BoneCollection(
        name: name,
        visible: visible,
        colour: colour,
      );

  /// Puts a bone in a collection, declaring the collection if it is new.
  void add(String bone, String collection, {bool visible = true, int? colour}) {
    declare(collection, visible: visible, colour: colour);
    (_members[collection] ??= <String>{}).add(bone);
  }

  Set<String> membersOf(String collection) =>
      Set.unmodifiable(_members[collection] ?? const <String>{});

  /// Every collection a bone is in, sorted so the answer is stable.
  List<String> collectionsOf(String bone) {
    final found = [
      for (final entry in _members.entries)
        if (entry.value.contains(bone)) entry.key,
    ]..sort();
    return found;
  }

  /// Collections in a stable order, so a rig generated twice reads the same.
  List<BoneCollection> get sorted {
    final list = _collections.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  /// The name a limb's controls go under: "Arm.L (IK)" and the like.
  ///
  /// Built here rather than spelled out at each call site so every rig type
  /// produces the same shape of name, which is what makes the list readable
  /// once there are twenty of them.
  static String limbCollection(String base, Side? side, String? kind) {
    final sided = side == null ? base : '$base${side.suffix}';
    return kind == null ? sided : '$sided ($kind)';
  }

  /// The colour for a side.
  static int colourFor(Side? side) => switch (side) {
    Side.left => leftColour,
    Side.right => rightColour,
    null => centreColour,
  };
}
