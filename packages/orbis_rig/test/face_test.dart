import 'dart:math' as math;

import 'package:orbis_rig/orbis_rig.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

/// A head with a jaw, two eyes and an upper lid on the left.
///
/// Eyes point along +Z, which is the way a face looks in a Y-up world.
Armature head() => Armature([
  Bone(name: 'head', head: Vector3(0, 1.6, 0), tail: Vector3(0, 1.8, 0)),
  Bone(
    name: 'jaw',
    head: Vector3(0, 1.7, 0.02),
    tail: Vector3(0, 1.64, 0.12),
    parent: 'head',
  ),
  Bone(
    name: 'eye.L',
    head: Vector3(0.03, 1.74, 0.05),
    tail: Vector3(0.03, 1.74, 0.08),
    parent: 'head',
  ),
  Bone(
    name: 'eye.R',
    head: Vector3(-0.03, 1.74, 0.05),
    tail: Vector3(-0.03, 1.74, 0.08),
    parent: 'head',
  ),
  Bone(
    name: 'lid_upper.L',
    head: Vector3(0.03, 1.75, 0.05),
    tail: Vector3(0.03, 1.76, 0.08),
    parent: 'head',
  ),
]);

GeneratedRig face({String eyeForLid = 'eye.L'}) {
  final meta = MetaRig(head())
    ..assign('jaw', const JawRig())
    ..assign('eye.L', const EyeRig())
    ..assign('eye.R', const EyeRig())
    ..assign('lid_upper.L', EyelidRig(eye: eyeForLid));
  return const RigGenerator().generate(meta);
}

void main() {
  group('a jaw', () {
    test('cannot be pushed further than a jaw goes', () {
      final rig = face();
      final pose = rig.pose;

      // Far past anything anatomical — a jaw opening a full half turn.
      pose['jaw'].rotation = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi);
      pose.evaluate();

      expect(
        _departure(pose, 'ORG-jaw'),
        lessThanOrEqualTo(math.pi / 5 + 1e-6),
      );
    });

    test('is limited from where it rests, not from the identity', () {
      // The jaw points down and forward, so its rest orientation is already a
      // long way from the identity. A limit measured from the identity clamps
      // the rest pose itself, and the joint looks stuck rather than limited.
      final rig = face();
      final pose = rig.pose..evaluate();

      expect(_departure(pose, 'ORG-jaw'), closeTo(0, 1e-6));

      const opening = math.pi / 12;
      pose['jaw'].rotation = Quaternion.axisAngle(Vector3(1, 0, 0), opening);
      pose.evaluate();

      // Well inside the limit, so it arrives untouched.
      expect(_departure(pose, 'ORG-jaw'), closeTo(opening, 1e-6));
    });

    test('still moves within its range', () {
      final rig = face();
      final rest = rig.pose..evaluate();
      final restTail = rest.tailOf('DEF-jaw').clone();

      rig.pose['jaw'].rotation = Quaternion.axisAngle(
        Vector3(1, 0, 0),
        math.pi / 12,
      );
      rig.pose.evaluate();

      expect((rig.pose.tailOf('DEF-jaw') - restTail).length, greaterThan(1e-3));
    });
  });

  group('eyes', () {
    test('share one control, so a character looks somewhere in one move', () {
      final rig = face();

      expect(rig.armature.contains(EyeRig.masterName), isTrue);
      // Two eyes, two targets, one master they both hang off.
      expect(rig.armature['eye_target.L']?.parent, EyeRig.masterName);
      expect(rig.armature['eye_target.R']?.parent, EyeRig.masterName);
    });

    test('follow the shared control when it moves', () {
      final rig = face();
      final pose = rig.pose..evaluate();

      final before = _forward(pose, 'ORG-eye.L');
      expect(before.z, greaterThan(0.9), reason: 'should start looking ahead');

      // Look sharply to the character's left.
      pose[EyeRig.masterName].location.setValues(1.5, 0, 0);
      pose.evaluate();

      final after = _forward(pose, 'ORG-eye.L');
      expect(after.x, greaterThan(0.3));
      expect(after.z, lessThan(before.z));
    });

    test('stay parallel by default, so an unposed rig is the rest pose', () {
      final rig = face();
      final pose = rig.pose..evaluate();

      // Both looking exactly where the modeller pointed them.
      expect(_forward(pose, 'ORG-eye.L').z, closeTo(1, 1e-6));
      expect(_forward(pose, 'ORG-eye.R').z, closeTo(1, 1e-6));

      pose[EyeRig.masterName].location.setValues(0.8, 0, 0);
      pose.evaluate();

      // Still parallel: each eye's own target moved by the same amount, so the
      // pair swing together without crossing.
      final left = _forward(pose, 'ORG-eye.L');
      final right = _forward(pose, 'ORG-eye.R');
      expect(right.x, closeTo(left.x, 1e-9));
    });

    test('converge on one point when focus is turned up', () {
      final rig = face();
      final pose = rig.pose
        ..setProperty(EyeRig.focusProperty, 1)
        ..evaluate();

      pose[EyeRig.masterName].location.setValues(0.8, 0, 0);
      pose.evaluate();

      final left = _forward(pose, 'ORG-eye.L');
      final right = _forward(pose, 'ORG-eye.R');

      // Both turned the same way, and the further eye turned more — which is
      // what two eyes meeting at one point looks like.
      expect(left.x, greaterThan(0));
      expect(right.x, greaterThan(left.x));
    });

    test('focus starts off, so it changes nothing until asked', () {
      final rig = face();
      expect(rig.properties[EyeRig.focusProperty], 0);
    });
  });

  group('an eyelid', () {
    test('follows the eye part of the way, not all of it', () {
      final rig = face();
      final pose = rig.pose..evaluate();
      final restLid = _forward(pose, 'ORG-lid_upper.L').clone();

      pose[EyeRig.masterName].location.setValues(1.5, 0, 0);
      pose.evaluate();

      final lid = _forward(pose, 'ORG-lid_upper.L');
      final eye = _forward(pose, 'ORG-eye.L');

      // It moved with the eye...
      expect((lid - restLid).length, greaterThan(1e-3));
      // ...but not as far, or it would close when the character looked down.
      expect(lid.x, lessThan(eye.x));
    });

    test('an eye that is not in the meta-rig is reported, not ignored', () {
      final rig = face(eyeForLid: 'eye.middle');

      expect(rig.hasProblems, isTrue);
      expect(
        rig.problems.map((problem) => problem.toString()).join(),
        contains('eye.middle'),
      );
    });

    test('the lid is still built when the eye it names is missing', () {
      // A problem worth reporting is not a reason to leave a hole in the rig:
      // the lid still has a control and the mesh still has something to bind
      // to, so the character is animatable while the meta-rig is fixed.
      final rig = face(eyeForLid: 'eye.middle');

      expect(rig.armature.contains('lid_upper.L'), isTrue);
      expect(rig.armature.contains('DEF-lid_upper.L'), isTrue);
    });
  });

  test('the whole face hides together', () {
    final rig = face();
    final members = rig.collections.membersOf(faceCollection);

    expect(members, contains('jaw'));
    expect(members, contains('eye_target.L'));
    expect(members, contains(EyeRig.masterName));
    expect(members, contains('lid_upper.L'));
  });
}

/// Which way a bone points, in armature space.
Vector3 _forward(Pose pose, String bone) =>
    (pose.tailOf(bone) - pose.headOf(bone))..normalize();

/// How far a bone has turned from where it rests, in radians.
double _departure(Pose pose, String bone) {
  final rest = Quaternion.identity();
  pose.baseOf(bone).decompose(Vector3.zero(), rest, Vector3.zero());

  final now = Quaternion.identity();
  pose.worldOf(bone).decompose(Vector3.zero(), now, Vector3.zero());

  final local = (rest.normalized().conjugated() * now.normalized())
    ..normalize();
  return 2 * math.acos(local.w.abs().clamp(0.0, 1.0));
}
