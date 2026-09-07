/// What a bone is for.
///
/// A generated rig holds far more bones than a skeleton does, and they are
/// told apart by a prefix rather than by a flag. That looks like a hack until
/// you have to debug one: every bone announces its job in the outliner, in an
/// error message, and in a file diff, without anything having to be loaded.
enum BoneRole {
  /// What an animator grabs. No prefix.
  control,

  /// The original skeleton, copied from the source rig. Drives nothing on its
  /// own; exists so a generated rig can be regenerated against what it came
  /// from.
  original,

  /// What the mesh is bound to. The only bones skinning ever sees.
  deform,

  /// Hidden plumbing — the bones that wire a control to a deform without
  /// either knowing about the other.
  mechanism;

  /// The prefix a bone of this role carries.
  String get prefix => switch (this) {
    BoneRole.control => '',
    BoneRole.original => 'ORG-',
    BoneRole.deform => 'DEF-',
    BoneRole.mechanism => 'MCH-',
  };
}

/// Which side of the body a bone is on.
enum Side {
  left('.L'),
  right('.R');

  const Side(this.suffix);

  final String suffix;

  Side get opposite => this == Side.left ? Side.right : Side.left;
}

/// Reading and writing the names a generated rig uses.
///
/// Conventions rather than data, so two tools that never speak can still agree
/// — which is the point of a convention.
abstract final class BoneNaming {
  static final RegExp _numeric = RegExp(r'\.\d{3}$');

  /// What a bone is for, from its prefix.
  static BoneRole roleOf(String name) {
    for (final role in BoneRole.values) {
      if (role.prefix.isNotEmpty && name.startsWith(role.prefix)) return role;
    }
    return BoneRole.control;
  }

  /// Which side a bone is on, or null if it is on the midline.
  ///
  /// A duplicate suffix is stripped first, so `hand.L.001` is still a left
  /// hand — Blender appends the number after the side and something that only
  /// checked the end of the string would call it sideless.
  static Side? sideOf(String name) {
    final trimmed = name.replaceAll(_numeric, '');
    for (final side in Side.values) {
      if (trimmed.endsWith(side.suffix)) return side;
    }
    return null;
  }

  /// The name with its role prefix and side suffix taken off.
  static String baseOf(String name) {
    var result = name.replaceAll(_numeric, '');

    final role = roleOf(result);
    if (role.prefix.isNotEmpty) {
      result = result.substring(role.prefix.length);
    }

    final side = sideOf(result);
    if (side != null) {
      result = result.substring(0, result.length - side.suffix.length);
    }
    return result;
  }

  /// Builds a name from its parts.
  static String compose(
    String base, {
    BoneRole role = BoneRole.control,
    Side? side,
  }) => '${role.prefix}$base${side?.suffix ?? ''}';

  /// The same bone, in the other role.
  static String asRole(String name, BoneRole role) =>
      compose(baseOf(name), role: role, side: sideOf(name));

  /// The bone on the other side of the body, or null for one on the midline.
  ///
  /// What every mirroring tool needs, and the reason sides are a suffix rather
  /// than a naming habit.
  static String? mirror(String name) {
    final side = sideOf(name);
    if (side == null) return null;
    return compose(baseOf(name), role: roleOf(name), side: side.opposite);
  }

  /// Whether two names describe the same bone on opposite sides.
  static bool areMirrors(String a, String b) => a != b && mirror(a) == b;
}
