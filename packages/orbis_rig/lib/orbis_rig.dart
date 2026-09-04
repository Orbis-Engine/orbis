/// Armatures, poses and the maths a control rig is generated on top of.
///
/// A skeleton is described by where its bones start and end, because that is
/// what an artist adjusts. Everything else — orientations, world matrices, the
/// matrices that skin a mesh — is derived from that rather than stored beside
/// it, so there is one source of truth about where a bone is.
library;

export 'src/armature.dart' show Armature, ArmatureError, Pose, PoseTransform;
export 'src/bone.dart' show Bone;
export 'src/constraints.dart'
    show BoneConstraint, CopyRotation, DampedTrack, LimitRotation, TrackAxis;
export 'src/generator.dart'
    show GeneratedRig, MetaRig, RigGenerator, RigProblem;
export 'src/ik.dart' show IkSolution, rotationBetween, solveTwoBoneIk;
export 'src/naming.dart' show BoneNaming, BoneRole, Side;
export 'src/rig_type.dart' show RigContext, RigType;
export 'src/rig_types.dart' show CopyRig, FingerRig, LimbRig, SpineRig;
