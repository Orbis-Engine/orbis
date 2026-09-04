import 'package:vector_math/vector_math_64.dart';

import 'bone.dart';
import 'constraints.dart';

/// Thrown when a skeleton describes something that is not a tree.
class ArmatureError extends StateError {
  ArmatureError(super.message);
}

/// A skeleton in its rest pose.
///
/// The rest pose is the shape the mesh was bound in. Everything an animator
/// does is expressed as a departure from it, which is why it is stored
/// separately rather than being wherever the bones happen to be.
class Armature {
  Armature([Iterable<Bone> bones = const []]) {
    for (final bone in bones) {
      add(bone);
    }
  }

  final Map<String, Bone> _bones = {};
  List<String>? _order;

  Iterable<Bone> get bones => _bones.values;

  int get length => _bones.length;

  Bone? operator [](String name) => _bones[name];

  bool contains(String name) => _bones.containsKey(name);

  void add(Bone bone) {
    if (_bones.containsKey(bone.name)) {
      throw ArmatureError('There is already a bone called "${bone.name}".');
    }
    _bones[bone.name] = bone;
    _order = null;
  }

  void remove(String name) {
    if (_bones.remove(name) == null) return;
    // Orphaned children become roots rather than dangling: a rig that loses a
    // bone should keep evaluating, so the mistake is visible as a limb in the
    // wrong place rather than as an exception during playback.
    for (final bone in _bones.values) {
      if (bone.parent == name) bone.parent = null;
    }
    _order = null;
  }

  /// Bones with no parent.
  Iterable<Bone> get roots =>
      _bones.values.where((bone) => bone.parent == null);

  Iterable<Bone> childrenOf(String name) =>
      _bones.values.where((bone) => bone.parent == name);

  /// Bone names with every parent before every child.
  ///
  /// Computed once and kept, because evaluation runs every frame and the
  /// hierarchy changes when a rig is built rather than when it is played.
  List<String> get evaluationOrder => _order ??= _sortByDepth();

  List<String> _sortByDepth() {
    final visited = <String>{};
    final visiting = <String>{};
    final order = <String>[];

    void visit(Bone bone) {
      if (visited.contains(bone.name)) return;
      if (!visiting.add(bone.name)) {
        throw ArmatureError(
          'Bone "${bone.name}" is its own ancestor. A skeleton has to be a '
          'tree, and a loop here would evaluate forever.',
        );
      }

      final parentName = bone.parent;
      if (parentName != null) {
        final parent = _bones[parentName];
        if (parent == null) {
          throw ArmatureError(
            'Bone "${bone.name}" names a parent "$parentName" that is not in '
            'this armature.',
          );
        }
        visit(parent);
      }

      visiting.remove(bone.name);
      visited.add(bone.name);
      order.add(bone.name);
    }

    for (final bone in _bones.values) {
      visit(bone);
    }
    return order;
  }

  /// Where a bone rests, in armature space.
  Matrix4 restOf(String name) {
    final bone = _bones[name];
    if (bone == null) throw ArmatureError('No bone called "$name".');
    return bone.restMatrix;
  }

  /// Where a bone rests relative to its parent.
  ///
  /// This is what a pose is applied on top of. Storing it relative means a
  /// bone keeps its offset from its parent when the parent moves, which is
  /// the entire point of a hierarchy.
  Matrix4 restLocalOf(String name) {
    final bone = _bones[name];
    if (bone == null) throw ArmatureError('No bone called "$name".');

    final parentName = bone.parent;
    if (parentName == null) return bone.restMatrix;

    final parent = _bones[parentName];
    if (parent == null) return bone.restMatrix;

    return Matrix4.inverted(parent.restMatrix).multiplied(bone.restMatrix);
  }

  /// Every bone the mesh is actually bound to.
  Iterable<Bone> get deformingBones => _bones.values.where((b) => b.deform);

  Armature copy() => Armature([for (final bone in _bones.values) bone.copy()]);
}

/// A bone's departure from its rest pose.
///
/// Local to the rest, not to the armature: a rotation here turns the bone
/// about its own joint, which is what an animator means by rotating a bone.
class PoseTransform {
  PoseTransform({Vector3? location, Quaternion? rotation, Vector3? scale})
    : location = location ?? Vector3.zero(),
      rotation = rotation ?? Quaternion.identity(),
      scale = scale ?? Vector3(1, 1, 1);

  Vector3 location;
  Quaternion rotation;
  Vector3 scale;

  bool get isRest =>
      location.length2 < 1e-18 &&
      (rotation.w.abs() - 1).abs() < 1e-9 &&
      (scale.x - 1).abs() < 1e-9 &&
      (scale.y - 1).abs() < 1e-9 &&
      (scale.z - 1).abs() < 1e-9;

  Matrix4 get matrix => Matrix4.compose(location, rotation, scale);

  void reset() {
    location.setZero();
    rotation.setValues(0, 0, 0, 1);
    scale.setValues(1, 1, 1);
  }

  PoseTransform copy() => PoseTransform(
    location: location.clone(),
    rotation: rotation.clone(),
    scale: scale.clone(),
  );
}

/// An armature, posed.
///
/// Holds a transform per bone and works out where every bone ends up. Kept
/// apart from the armature itself so one skeleton can be posed many times over
/// — a crowd is one rest pose and a hundred poses, not a hundred skeletons.
class Pose {
  Pose(this.armature) {
    for (final bone in armature.bones) {
      _transforms[bone.name] = PoseTransform();
    }
  }

  final Armature armature;
  final Map<String, PoseTransform> _transforms = {};
  final Map<String, Matrix4> _world = {};
  final Map<String, List<BoneConstraint>> _constraints = {};
  List<String>? _order;

  /// Adds a constraint to a bone. They apply in the order they were added,
  /// each seeing what the last one produced — the same as stacking them in any
  /// rigging tool, and the reason order is worth thinking about.
  void constrain(String bone, BoneConstraint constraint) {
    (_constraints[bone] ??= []).add(constraint);
    _order = null;
  }

  List<BoneConstraint> constraintsOn(String bone) =>
      List.unmodifiable(_constraints[bone] ?? const []);

  void clearConstraints([String? bone]) {
    if (bone == null) {
      _constraints.clear();
    } else {
      _constraints.remove(bone);
    }
    _order = null;
  }

  /// The order bones are worked out in, accounting for both the hierarchy and
  /// what each constraint reads.
  ///
  /// A rig is a graph rather than a tree: a bone aimed at its cousin depends
  /// on that cousin as surely as it depends on its parent. Ordering by parents
  /// alone would read a matrix that has not been computed yet, which fails
  /// either loudly or — worse — quietly, one frame behind.
  List<String> get evaluationOrder => _order ??= _sortWithConstraints();

  List<String> _sortWithConstraints() {
    final visited = <String>{};
    final visiting = <String>{};
    final order = <String>[];

    void visit(String name, String? because) {
      if (visited.contains(name)) return;
      if (!visiting.add(name)) {
        throw ArmatureError(
          'Evaluating "$name" needs itself'
          '${because == null ? '' : ', by way of "$because"'}. A constraint '
          'that closes a loop has no order that satisfies it.',
        );
      }

      final bone = armature[name];
      if (bone != null) {
        final parent = bone.parent;
        if (parent != null && armature.contains(parent)) visit(parent, name);

        for (final constraint
            in _constraints[name] ?? const <BoneConstraint>[]) {
          for (final dependency in constraint.dependencies) {
            if (armature.contains(dependency)) visit(dependency, name);
          }
        }
      }

      visiting.remove(name);
      visited.add(name);
      order.add(name);
    }

    // Seeded from the armature's own order so a rig with no constraints comes
    // out in the same order it always did.
    for (final name in armature.evaluationOrder) {
      visit(name, null);
    }
    return order;
  }

  /// The transform for a bone, created on demand so a rig built after the pose
  /// still works.
  PoseTransform operator [](String name) =>
      _transforms[name] ??= PoseTransform();

  /// Puts every bone back at rest.
  void reset() {
    for (final transform in _transforms.values) {
      transform.reset();
    }
  }

  /// Works out where every bone is, parents first.
  void evaluate() {
    for (final name in evaluationOrder) {
      final bone = armature[name]!;
      final local = armature.restLocalOf(name).multiplied(this[name].matrix);

      final parentName = bone.parent;
      final parent = parentName == null ? null : _world[parentName];

      var world = parent == null ? local : parent.multiplied(local);

      // Constraints run before children are evaluated, so a constrained bone
      // carries everything below it. That ordering is what makes a rig a
      // mechanism rather than a list of independent parts.
      for (final constraint in _constraints[name] ?? const <BoneConstraint>[]) {
        world = constraint.apply(world, this);
      }

      _world[name] = world;
    }
  }

  /// Where a bone ended up, in armature space. Call [evaluate] first.
  Matrix4 worldOf(String name) =>
      _world[name] ?? (throw ArmatureError('No bone called "$name".'));

  /// Where a bone's head ended up.
  Vector3 headOf(String name) => worldOf(name).getTranslation();

  /// Where a bone's tail ended up.
  Vector3 tailOf(String name) {
    final bone = armature[name]!;
    return worldOf(name).transform3(Vector3(0, bone.length, 0));
  }

  /// The matrix that moves a vertex from its bound position to its posed one.
  ///
  /// Where the bone is now, undoing where it rested. A vertex bound to a bone
  /// at rest multiplied by this lands where the pose puts it, which is the
  /// whole of skinning in one product.
  Matrix4 skinningOf(String name) =>
      worldOf(name).multiplied(Matrix4.inverted(armature.restOf(name)));

  /// Skinning matrices for every deforming bone, in evaluation order.
  Map<String, Matrix4> skinningMatrices() => {
    for (final name in armature.evaluationOrder)
      if (armature[name]!.deform) name: skinningOf(name),
  };
}
