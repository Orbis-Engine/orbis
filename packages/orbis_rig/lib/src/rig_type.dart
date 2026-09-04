import 'package:vector_math/vector_math_64.dart';

import 'armature.dart';
import 'bone.dart';
import 'constraints.dart';
import 'naming.dart';

/// What a rig type writes into while it is generating.
///
/// A rig type never touches the meta-rig it is reading. Generation is a
/// translation, and keeping the source untouched is what makes it repeatable:
/// a rig can be thrown away and rebuilt from the skeleton it came from, which
/// is the entire reason to generate one rather than build it by hand.
class RigContext {
  RigContext({required this.source, required this.output, required this.pose});

  /// The meta-rig being read.
  final Armature source;

  /// The rig being written.
  final Armature output;

  /// Where constraints, chains and properties land.
  final Pose pose;

  final Set<String> controls = {};
  final Map<String, double> defaults = {};

  /// Copies a bone out of the meta-rig.
  ///
  /// Same position and orientation, a new name and role. Everything a
  /// generated rig contains starts as one of these or as a bone derived from
  /// one, so a control is always somewhere an artist actually put something.
  String copy(
    String sourceName, {
    BoneRole role = BoneRole.control,
    String? rename,
    String? parent,
    bool? deform,
    bool connected = false,
  }) {
    final bone = source[sourceName];
    if (bone == null) {
      throw ArmatureError('The meta-rig has no bone called "$sourceName".');
    }

    final name = BoneNaming.compose(
      rename ?? BoneNaming.baseOf(sourceName),
      role: role,
      side: BoneNaming.sideOf(sourceName),
    );

    output.add(
      Bone(
        name: name,
        head: bone.head.clone(),
        tail: bone.tail.clone(),
        roll: bone.roll,
        parent: parent,
        connected: connected,
        // Only deform bones deform. Everything else in a generated rig is
        // machinery, and a mesh bound to machinery is a mesh that breaks when
        // the machinery is rebuilt.
        deform: deform ?? (role == BoneRole.deform),
      ),
    );

    if (role == BoneRole.control) controls.add(name);
    return name;
  }

  /// Makes a bone that has no counterpart in the meta-rig.
  ///
  /// Inverse-kinematics targets, pole vectors and the hidden chain a solver
  /// runs on are all invented during generation — the artist never drew them.
  String create(
    String name, {
    required Vector3 head,
    required Vector3 tail,
    BoneRole role = BoneRole.mechanism,
    String? parent,
    double roll = 0,
    bool deform = false,
  }) {
    output.add(
      Bone(
        name: name,
        head: head.clone(),
        tail: tail.clone(),
        roll: roll,
        parent: parent,
        deform: deform,
      ),
    );
    if (role == BoneRole.control) controls.add(name);
    return name;
  }

  void constrain(String bone, BoneConstraint constraint) =>
      pose.constrain(bone, constraint);

  void ik(IkChain chain) => pose.addIkChain(chain);

  /// Declares a value an animator can change, with the value it starts at.
  void property(String name, double value) {
    defaults[name] = value;
    pose.setProperty(name, value);
  }
}

/// Turns one chain of the meta-rig into part of a working rig.
///
/// The unit of a generated rig. An artist marks a chain as an arm and gets
/// everything an arm needs — forward and inverse controls, the switch between
/// them, and the deform bones underneath — without assembling any of it.
abstract interface class RigType {
  /// What this type is called where it is assigned.
  String get id;

  /// How many bones it expects. A chain shorter than the minimum is an error
  /// worth reporting rather than a rig that half-works.
  int get minimumBones;

  void generate(RigContext context, List<String> chain);
}
