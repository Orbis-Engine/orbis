import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// A bone in its rest pose.
///
/// Described by where it starts, where it ends, and how it is twisted about
/// its own length — head, tail and roll. Not by a matrix: a matrix is the
/// answer, and an artist adjusting a skeleton is moving endpoints.
///
/// A bone's own Y axis runs from head to tail. That is Blender's convention
/// rather than an arbitrary one, and it is worth matching exactly, because a
/// rig authored in one and evaluated in the other is wrong in a way that only
/// shows up when a limb twists.
class Bone {
  Bone({
    required this.name,
    required Vector3 head,
    required Vector3 tail,
    this.roll = 0,
    this.parent,
    this.connected = false,
    this.deform = true,
  }) : head = head.clone(),
       tail = tail.clone();

  final String name;

  /// Where the bone starts, in armature space.
  Vector3 head;

  /// Where it ends. The direction between them is the bone's Y axis, and the
  /// distance is its length.
  Vector3 tail;

  /// Twist about the bone's own length, in radians.
  ///
  /// Two bones can point the same way and still be rotated differently around
  /// that direction, and which one you have decides where a knee bends.
  double roll;

  /// The bone this one hangs from, by name.
  String? parent;

  /// Whether the head is glued to the parent's tail.
  ///
  /// A connected bone cannot be moved independently in the rest pose, which is
  /// right for a forearm and wrong for a finger that should sit off the palm.
  bool connected;

  /// Whether a mesh is bound to this bone.
  ///
  /// A generated rig has far more bones than it has deforming ones: controls
  /// an animator grabs and hidden mechanisms that wire them together do not
  /// touch the mesh at all.
  bool deform;

  double get length => (tail - head).length;

  /// The bone's Y axis: the direction it points.
  Vector3 get direction {
    final delta = tail - head;
    final length = delta.length;
    // A zero-length bone has no direction to speak of; +Y is the identity
    // orientation and keeps the matrix well-formed rather than full of NaNs.
    if (length < 1e-9) return Vector3(0, 1, 0);
    return delta / length;
  }

  /// The bone's orientation in armature space.
  ///
  /// Built from the direction and then twisted by the roll, rather than from
  /// three Euler angles, so there is no order to get wrong and no gimbal to
  /// fall into.
  Quaternion get orientation {
    final aligned = _shortestArc(Vector3(0, 1, 0), direction);
    if (roll == 0) return aligned;
    return Quaternion.axisAngle(direction, roll) * aligned;
  }

  /// Where the bone sits, and how it is turned, in armature space.
  Matrix4 get restMatrix =>
      Matrix4.compose(head, orientation, Vector3(1, 1, 1));

  Bone copy() => Bone(
    name: name,
    head: head.clone(),
    tail: tail.clone(),
    roll: roll,
    parent: parent,
    connected: connected,
    deform: deform,
  );

  @override
  String toString() => 'Bone($name, ${length.toStringAsFixed(3)})';
}

/// The rotation taking one direction to another by the shortest path.
///
/// Written out rather than taken from the library, whose matrix conversions
/// have been unreliable in this codebase before.
Quaternion _shortestArc(Vector3 from, Vector3 to) {
  final a = from.normalized();
  final b = to.normalized();
  final dot = a.dot(b);

  if (dot > 0.999999) return Quaternion.identity();

  if (dot < -0.999999) {
    // Exactly opposed. Any perpendicular axis gives a valid half turn; pick
    // one that is definitely not parallel to the input.
    var axis = a.cross(Vector3(1, 0, 0));
    if (axis.length2 < 1e-6) axis = a.cross(Vector3(0, 0, 1));
    return Quaternion.axisAngle(axis.normalized(), math.pi);
  }

  final axis = a.cross(b);
  return Quaternion(axis.x, axis.y, axis.z, 1 + dot)..normalize();
}
