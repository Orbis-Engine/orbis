import 'package:vector_math/vector_math_64.dart';

import 'armature.dart';
import 'constraints.dart';
import 'naming.dart';
import 'rig_type.dart';

/// The deform bone for a source bone, wired to shadow its original.
///
/// Every rig type ends this way, and it is the reason a rig can be rebuilt at
/// all: the mesh is bound to bones that copy something, so the something can be
/// replaced wholesale without the mesh noticing.
String _deform(
  RigContext context,
  String sourceName,
  String organic, {
  String? parent,
}) {
  final deform = context.copy(
    sourceName,
    role: BoneRole.deform,
    parent: parent,
  );
  context.constrain(deform, CopyTransform(organic));
  return deform;
}

/// One bone, one control.
///
/// The plainest thing a rig type can be, and most of any rig by count: a jaw,
/// an eye, a prop socket. Worth having as a type rather than as a special case,
/// because it still wants a control an animator can find and a deform bone the
/// mesh binds to.
class CopyRig implements RigType {
  const CopyRig();

  @override
  String get id => 'basic.copy';

  @override
  int get minimumBones => 1;

  @override
  void generate(RigContext context, List<String> chain) {
    final sourceName = chain.first;

    final organic = context.copy(sourceName, role: BoneRole.original);
    final control = context.copy(sourceName);

    context.constrain(organic, CopyTransform(control));
    _deform(context, sourceName, organic);
  }
}

/// An arm or a leg: three bones, driven either way round.
///
/// The type that earns a generator. A limb wants forward controls for
/// animating an arc, inverse controls for keeping a hand on a table, and a way
/// to move between them mid-shot — which is a dozen bones and twice as many
/// constraints that nobody should assemble twice, let alone mirror by hand.
class LimbRig implements RigType {
  const LimbRig();

  @override
  String get id => 'limbs.limb';

  @override
  int get minimumBones => 3;

  @override
  void generate(RigContext context, List<String> chain) {
    final upper = chain[0];
    final lower = chain[1];
    final end = chain[2];

    final side = BoneNaming.sideOf(upper);
    final base = BoneNaming.baseOf(upper);
    final switchName = BoneNaming.compose('${base}_ik_fk', side: side);

    // Zero is inverse, one is forward. Starting on forward because that is
    // what an animator blocks a shot in; inverse is for when something has to
    // stay put.
    context.property(switchName, 1);

    // The originals, in their own chain.
    final organicUpper = context.copy(upper, role: BoneRole.original);
    final organicLower = context.copy(
      lower,
      role: BoneRole.original,
      parent: organicUpper,
    );
    final organicEnd = context.copy(
      end,
      role: BoneRole.original,
      parent: organicLower,
    );

    // Forward controls: a chain an animator turns joint by joint.
    final forwardUpper = context.copy(upper, rename: '${base}_fk');
    final forwardLower = context.copy(
      lower,
      rename: '${BoneNaming.baseOf(lower)}_fk',
      parent: forwardUpper,
    );
    final forwardEnd = context.copy(
      end,
      rename: '${BoneNaming.baseOf(end)}_fk',
      parent: forwardLower,
    );

    // Inverse controls: a goal for the end of the limb, and a pole that
    // decides which way the joint bends. Without the pole a knee is as likely
    // to bend backwards as forwards, and no amount of animating fixes that.
    final endBone = context.source[end]!;
    final goal = context.create(
      BoneNaming.compose('${BoneNaming.baseOf(end)}_ik', side: side),
      head: endBone.head,
      tail: endBone.tail,
      role: BoneRole.control,
    );

    final pole = context.create(
      BoneNaming.compose('${base}_pole', side: side),
      head: _polePosition(context, upper, lower),
      tail: _polePosition(context, upper, lower) + Vector3(0, 0.2, 0),
      role: BoneRole.control,
    );

    // The chain the solver actually runs on, hidden from the animator.
    final solvedUpper = context.copy(
      upper,
      role: BoneRole.mechanism,
      rename: '${base}_ik',
    );
    final solvedLower = context.copy(
      lower,
      role: BoneRole.mechanism,
      rename: '${BoneNaming.baseOf(lower)}_ik',
      parent: solvedUpper,
    );

    context.ik(
      IkChain(root: solvedUpper, mid: solvedLower, target: goal, pole: pole),
    );

    // The handover. Two stacks reading one number, one of them inverted: at
    // one the originals follow the forward controls, at zero they follow the
    // solved chain, and in between they cross over without anything else in
    // the rig knowing a handover happened.
    context
      ..constrain(
        organicUpper,
        CopyTransform(forwardUpper, influenceProperty: switchName),
      )
      ..constrain(
        organicUpper,
        CopyTransform(
          solvedUpper,
          influenceProperty: switchName,
          invertInfluence: true,
        ),
      )
      ..constrain(
        organicLower,
        CopyTransform(forwardLower, influenceProperty: switchName),
      )
      ..constrain(
        organicLower,
        CopyTransform(
          solvedLower,
          influenceProperty: switchName,
          invertInfluence: true,
        ),
      )
      ..constrain(
        organicEnd,
        CopyTransform(forwardEnd, influenceProperty: switchName),
      )
      ..constrain(
        organicEnd,
        CopyTransform(
          goal,
          influenceProperty: switchName,
          invertInfluence: true,
        ),
      );

    final deformUpper = _deform(context, upper, organicUpper);
    final deformLower = _deform(
      context,
      lower,
      organicLower,
      parent: deformUpper,
    );
    _deform(context, end, organicEnd, parent: deformLower);
  }

  /// Puts the pole out in front of the joint, along the way it already bends.
  ///
  /// Derived from the rest pose rather than asked for, because the meta-rig
  /// already says which way the limb is bent — a straight limb in the rest
  /// pose is the thing to complain about, not a pole nobody positioned.
  Vector3 _polePosition(RigContext context, String upper, String lower) {
    final upperBone = context.source[upper]!;
    final lowerBone = context.source[lower]!;

    final root = upperBone.head;
    final joint = lowerBone.head;
    final end = lowerBone.tail;

    final straight = (end - root)..normalize();
    final toJoint = joint - root;
    // How far the joint sits off the line between the two ends: the direction
    // the limb already bends in.
    final offset = toJoint - straight * toJoint.dot(straight);

    if (offset.length2 < 1e-9) {
      // A limb modelled dead straight names no plane. Somewhere in front is a
      // guess, and a guess in a known direction beats one in a random one.
      return joint + Vector3(0, 0, (end - root).length);
    }
    return joint + offset.normalized() * (end - root).length;
  }
}

/// A finger: one control that curls the whole chain.
///
/// Animating three knuckles separately is possible and nobody does it. The
/// per-segment bones still exist underneath, so a pose that needs them is not
/// locked out — the control is the fast path, not the only one.
class FingerRig implements RigType {
  const FingerRig();

  @override
  String get id => 'limbs.finger';

  @override
  int get minimumBones => 2;

  /// Strips a trailing segment number, so a chain beginning `f_index_01` gives
  /// a control called `f_index_curl` rather than `f_index_01_curl`.
  ///
  /// A convention rather than a rule: the control is named for the finger, and
  /// the finger is what the numbering counts through.
  static final RegExp _segment = RegExp(r'_\d+$');

  @override
  void generate(RigContext context, List<String> chain) {
    final side = BoneNaming.sideOf(chain.first);
    final base = BoneNaming.baseOf(chain.first).replaceAll(_segment, '');

    final master = context.copy(chain.first, rename: '${base}_curl');
    context.property(BoneNaming.compose('${base}_curl_amount', side: side), 1);

    String? organicParent;
    String? deformParent;

    for (var i = 0; i < chain.length; i++) {
      final organic = context.copy(
        chain[i],
        role: BoneRole.original,
        parent: organicParent,
      );

      // Every segment takes the master's turn. The first follows it exactly
      // and the rest follow proportionally, which is what a finger does —
      // knuckles do not all bend the same amount.
      context.constrain(
        organic,
        CopyRotation(master, influence: i == 0 ? 1.0 : 0.8),
      );

      deformParent = _deform(context, chain[i], organic, parent: deformParent);
      organicParent = organic;
    }
  }
}

/// A spine: two ends, and everything between them following.
///
/// Hips and chest are what an animator moves; the vertebrae between them bend
/// proportionally rather than being posed one at a time. Turning the chest
/// twists the upper back most and the lower back least, which is what a spine
/// does and what posing each bone by hand never quite achieves.
class SpineRig implements RigType {
  const SpineRig();

  @override
  String get id => 'spines.spine';

  @override
  int get minimumBones => 2;

  @override
  void generate(RigContext context, List<String> chain) {
    final side = BoneNaming.sideOf(chain.first);
    final base = BoneNaming.baseOf(chain.first);

    // One control that moves the whole torso, with the two ends under it, so
    // walking the character does not mean moving hips and chest in step.
    final torso = context.copy(chain.first, rename: '${base}_torso');
    final hips = context.copy(chain.first, rename: 'hips', parent: torso);
    final chest = context.copy(chain.last, rename: 'chest', parent: torso);

    context.property(BoneNaming.compose('${base}_bend', side: side), 1);

    String? organicParent;
    String? deformParent;

    for (var i = 0; i < chain.length; i++) {
      final organic = context.copy(
        chain[i],
        role: BoneRole.original,
        parent: organicParent,
      );

      // Proportional along the chain: the lowest bone is all hips, the highest
      // all chest, and the ones between are a mixture.
      final t = chain.length == 1 ? 1.0 : i / (chain.length - 1);
      context
        ..constrain(organic, CopyRotation(hips, influence: 1 - t))
        ..constrain(organic, CopyRotation(chest, influence: t));

      deformParent = _deform(context, chain[i], organic, parent: deformParent);
      organicParent = organic;
    }
  }
}
