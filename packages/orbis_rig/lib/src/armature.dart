import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'bone.dart';
import 'constraints.dart';
import 'ik.dart';

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

/// A two-bone chain that reaches for something.
///
/// Named rather than constrained per bone, because inverse kinematics is one
/// answer about two bones at once: solving it as two independent constraints
/// means each is guessing at what the other will do.
class IkChain {
  const IkChain({
    required this.root,
    required this.mid,
    required this.target,
    this.pole,
    this.influence = 1,
    this.influenceProperty,
    this.stretch = 0,
    this.stretchProperty,
  });

  /// The upper bone — a thigh or an upper arm.
  final String root;

  /// The lower bone. Must be a child of [root].
  final String mid;

  /// The bone whose head the chain reaches for.
  final String target;

  /// The bone whose head decides which way the joint bends. Without one the
  /// chain still solves, but a knee may end up bending backwards.
  final String? pole;

  final double influence;

  /// A pose property to take the influence from, which is how a limb is handed
  /// between inverse and forward kinematics.
  final String? influenceProperty;

  /// How far the limb may stretch past full extension, from zero to one.
  final double stretch;

  /// A pose property to take the stretch from, so an animator can turn it off
  /// for a shot where the silhouette matters more than the reach.
  final String? stretchProperty;

  double stretchIn(Pose pose) {
    final name = stretchProperty;
    final value = name == null ? stretch : pose.property(name) ?? stretch;
    return value.clamp(0.0, 1.0);
  }

  double influenceIn(Pose pose) {
    final name = influenceProperty;
    final value = name == null ? influence : pose.property(name) ?? influence;
    return value.clamp(0.0, 1.0);
  }
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
  final Map<String, double> _properties = {};
  final List<IkChain> _ikChains = [];
  List<String>? _order;

  /// A named value constraints can read, such as an inverse-kinematics blend.
  ///
  /// Lives on the pose rather than on a bone because it is animated like
  /// anything else and read by several bones at once — a limb's switch is one
  /// number that a dozen constraints consult.
  double? property(String name) => _properties[name];

  void setProperty(String name, double value) => _properties[name] = value;

  Map<String, double> get properties => Map.unmodifiable(_properties);

  /// Adds a constraint to a bone. They apply in the order they were added,
  /// each seeing what the last one produced — the same as stacking them in any
  /// rigging tool, and the reason order is worth thinking about.
  void constrain(String bone, BoneConstraint constraint) {
    (_constraints[bone] ??= []).add(constraint);
    _order = null;
  }

  List<BoneConstraint> constraintsOn(String bone) =>
      List.unmodifiable(_constraints[bone] ?? const []);

  /// Adds a chain that reaches for a target.
  void addIkChain(IkChain chain) {
    _ikChains.add(chain);
    _order = null;
  }

  List<IkChain> get ikChains => List.unmodifiable(_ikChains);

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

  /// The transform for a bone.
  ///
  /// Refuses a name the armature does not have. Returning a fresh transform
  /// instead would make a typo do nothing at all, quietly — which is exactly
  /// how a control that was renamed goes on looking connected while driving
  /// nothing.
  PoseTransform operator [](String name) {
    final existing = _transforms[name];
    if (existing != null) return existing;
    if (!armature.contains(name)) {
      throw ArmatureError(
        'No bone called "$name" in this armature, so there is nothing to pose.',
      );
    }
    return _transforms[name] = PoseTransform();
  }

  /// Puts every bone back at rest.
  void reset() {
    for (final transform in _transforms.values) {
      transform.reset();
    }
  }

  /// Works out where every bone is, parents first.
  void evaluate() {
    _evaluateOnce();
    if (_ikChains.isEmpty) return;

    // Inverse kinematics writes rotations back into the pose rather than
    // overwriting world matrices, so everything below a solved limb — a hand's
    // fingers, a foot's toes — comes along on the ordinary pass that follows.
    _solveIkChains();
    _evaluateOnce();
  }

  void _evaluateOnce() {
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
        world = constraint.apply(world, this, name);
      }

      _world[name] = world;
    }
  }

  /// Where a bone would be with no pose applied: its parent, times its rest
  /// offset. What a local pose rotation is measured against.
  ///
  /// Public because a constraint that limits a joint has to know where the
  /// joint rests. Measuring against the identity instead would treat every
  /// bone that is not axis-aligned as already bent, and clamp the rest pose.
  Matrix4 baseOf(String name) => _baseOf(name);

  Matrix4 _baseOf(String name) {
    final bone = armature[name]!;
    final local = armature.restLocalOf(name);
    final parentName = bone.parent;
    final parent = parentName == null ? null : _world[parentName];
    return parent == null ? local : parent.multiplied(local);
  }

  void _solveIkChains() {
    for (final chain in _ikChains) {
      final amount = chain.influenceIn(this);
      if (amount <= 0) continue;

      final rootBone = armature[chain.root];
      final midBone = armature[chain.mid];
      if (rootBone == null || midBone == null) continue;

      final rootHead = headOf(chain.root);
      final goal = headOf(chain.target);
      final poleName = chain.pole;
      // Without a pole the bend plane is whatever the solver falls back to,
      // which is stable but arbitrary — fine for a tentacle, wrong for a knee.
      final pole = poleName == null
          ? rootHead + tailOf(chain.root) - rootHead + Vector3(0, 0, 1)
          : headOf(poleName);

      final solution = solveTwoBoneIk(
        root: rootHead,
        pole: pole,
        target: goal,
        upperLength: rootBone.length,
        lowerLength: midBone.length,
        stretch: chain.stretchIn(this),
      );

      // Only the root is scaled. Scale is inherited, so stretching the upper
      // bone carries the lower one out to the right place and lengthens it by
      // the same factor — scaling both would stretch the lower one twice.
      //
      // Non-uniform inherited scale shears a child that is rotated relative to
      // its parent, which would be a problem if the limb were bent. It cannot
      // be: a limb only stretches once it is past full extension, and a limb
      // past full extension is straight.
      //
      // Written every solve, including back to one, because a scale left over
      // from a frame where the limb was stretched would keep it long after the
      // target came back into reach.
      _stretchAlongY(chain.root, solution.stretch, amount);
      _aim(chain.root, solution.joint - rootHead, amount);
      _world[chain.root] = _baseOf(
        chain.root,
      ).multiplied(this[chain.root].matrix);

      _stretchAlongY(chain.mid, 1, amount);
      _aim(chain.mid, solution.end - headOf(chain.mid), amount);
      _world[chain.mid] = _baseOf(chain.mid).multiplied(this[chain.mid].matrix);
    }
  }

  /// Stretches a bone along its own length, keeping its volume.
  ///
  /// The cross-section narrows as the inverse square root of the stretch,
  /// which is what keeps a stretched forearm from also getting fatter — the
  /// giveaway that a limb is being scaled rather than stretched.
  void _stretchAlongY(String name, double factor, double amount) {
    final blended = 1 + (factor - 1) * amount;
    final cross = blended <= 0 ? 1.0 : 1 / math.sqrt(blended);
    this[name].scale.setValues(cross, blended, cross);
  }

  /// Turns a bone so it points a given way, by writing its local rotation.
  void _aim(String name, Vector3 direction, double amount) {
    if (direction.length2 < 1e-12) return;

    final world = _world[name]!;
    final column = world.getColumn(1);
    final currentAxis = Vector3(column.x, column.y, column.z)..normalize();

    final currentRotation = Quaternion.identity();
    final scale = Vector3.zero();
    final translation = Vector3.zero();
    world.decompose(translation, currentRotation, scale);
    currentRotation.normalize();

    final correction = rotationBetween(currentAxis, direction.normalized());
    final wanted = correction * currentRotation;

    final baseRotation = Quaternion.identity();
    _baseOf(name).decompose(Vector3.zero(), baseRotation, Vector3.zero());
    baseRotation.normalize();

    // Converted back to the bone's own space, because that is where a pose
    // lives — writing a world rotation would be undone the moment the parent
    // moved.
    final local = baseRotation.conjugated() * wanted;
    this[name].rotation = amount >= 1
        ? local.normalized()
        : _blend(this[name].rotation, local.normalized(), amount);
  }

  static Quaternion _blend(Quaternion a, Quaternion b, double t) {
    var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    var target = b;
    if (dot < 0) {
      target = Quaternion(-b.x, -b.y, -b.z, -b.w);
      dot = -dot;
    }
    return Quaternion(
      a.x + (target.x - a.x) * t,
      a.y + (target.y - a.y) * t,
      a.z + (target.z - a.z) * t,
      a.w + (target.w - a.w) * t,
    )..normalize();
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
