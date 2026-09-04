import 'dart:math' as math;

import 'package:orbis_rig/orbis_rig.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

/// An arm hanging down and bent slightly forward, which is what a rest pose
/// is for: it tells the generator which way the elbow goes.
MetaRig armMetaRig({String side = '.L'}) {
  final armature = Armature([
    Bone(
      name: 'upper_arm$side',
      head: Vector3(0, 0, 0),
      tail: Vector3(0.4, -2, 0),
    ),
    Bone(
      name: 'forearm$side',
      head: Vector3(0.4, -2, 0),
      tail: Vector3(0, -3.9, 0),
      parent: 'upper_arm$side',
      connected: true,
    ),
    Bone(
      name: 'hand$side',
      head: Vector3(0, -3.9, 0),
      tail: Vector3(0, -4.4, 0),
      parent: 'forearm$side',
      connected: true,
    ),
  ]);
  return MetaRig(armature)..assign('upper_arm$side', const LimbRig());
}

void expectVector(Vector3 actual, Vector3 expected, {double tolerance = 1e-4}) {
  expect(actual.x, closeTo(expected.x, tolerance), reason: 'x of $actual');
  expect(actual.y, closeTo(expected.y, tolerance), reason: 'y of $actual');
  expect(actual.z, closeTo(expected.z, tolerance), reason: 'z of $actual');
}

void main() {
  const generator = RigGenerator();

  group('a copied bone', () {
    test('becomes a control, an original and a deform bone', () {
      final meta = MetaRig(
        Armature([
          Bone(name: 'jaw', head: Vector3.zero(), tail: Vector3(0, 0, 1)),
        ]),
      )..assign('jaw', const CopyRig());

      final rig = generator.generate(meta);

      expect(rig.armature.contains('jaw'), isTrue);
      expect(rig.armature.contains('ORG-jaw'), isTrue);
      expect(rig.armature.contains('DEF-jaw'), isTrue);
      expect(rig.controls, contains('jaw'));
      expect(rig.deformBones, [
        'DEF-jaw',
      ], reason: 'only the deform bone deforms; the rest is machinery');
    });

    test('the control drives the deform bone through the original', () {
      final meta = MetaRig(
        Armature([
          Bone(name: 'jaw', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        ]),
      )..assign('jaw', const CopyRig());

      final rig = generator.generate(meta);
      rig.pose['jaw'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      rig.pose.evaluate();

      expectVector(rig.pose.tailOf('DEF-jaw'), Vector3(-1, 0, 0));
    });
  });

  group('a limb', () {
    test('generates the bones a limb needs', () {
      final rig = generator.generate(armMetaRig());

      for (final name in [
        'ORG-upper_arm.L',
        'ORG-forearm.L',
        'ORG-hand.L',
        'DEF-upper_arm.L',
        'DEF-forearm.L',
        'DEF-hand.L',
        'upper_arm_fk.L',
        'forearm_fk.L',
        'hand_fk.L',
        'hand_ik.L',
        'upper_arm_pole.L',
        'MCH-upper_arm_ik.L',
        'MCH-forearm_ik.L',
      ]) {
        expect(rig.armature.contains(name), isTrue, reason: 'missing $name');
      }
    });

    test('only the controls are offered to an animator', () {
      final rig = generator.generate(armMetaRig());

      expect(
        rig.controls,
        containsAll([
          'upper_arm_fk.L',
          'forearm_fk.L',
          'hand_fk.L',
          'hand_ik.L',
          'upper_arm_pole.L',
        ]),
      );
      for (final control in rig.controls) {
        expect(control.startsWith('MCH-'), isFalse);
        expect(control.startsWith('DEF-'), isFalse);
        expect(control.startsWith('ORG-'), isFalse);
      }
    });

    test('carries a switch between the two ways of driving it', () {
      final rig = generator.generate(armMetaRig());
      expect(
        rig.properties['upper_arm_ik_fk.L'],
        1,
        reason:
            'blocking a shot happens on forward controls, so that is '
            'where the switch starts',
      );
    });

    test('forward controls drive the deform bones', () {
      final rig = generator.generate(armMetaRig());
      final pose = rig.pose..setProperty('upper_arm_ik_fk.L', 1);

      pose.evaluate();
      final before = pose.tailOf('DEF-forearm.L').clone();

      pose['upper_arm_fk.L'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        0.6,
      );
      pose.evaluate();

      expect(
        (pose.tailOf('DEF-forearm.L') - before).length,
        greaterThan(0.5),
        reason: 'turning the shoulder should swing the forearm below it',
      );
    });

    test('the inverse goal drives the deform bones', () {
      final rig = generator.generate(armMetaRig());
      final pose = rig.pose..setProperty('upper_arm_ik_fk.L', 0);

      // Move the goal somewhere the arm can reach.
      pose['hand_ik.L'].location = Vector3(1.0, 0.6, 0);
      pose.evaluate();

      final hand = pose.headOf('DEF-hand.L');
      final goal = pose.headOf('hand_ik.L');
      expectVector(hand, goal, tolerance: 1e-3);
    });

    test('the chain keeps its bone lengths while reaching', () {
      final rig = generator.generate(armMetaRig());
      final pose = rig.pose..setProperty('upper_arm_ik_fk.L', 0);

      pose['hand_ik.L'].location = Vector3(0.8, 1.2, 0.3);
      pose.evaluate();

      final upper =
          pose.headOf('MCH-forearm_ik.L') - pose.headOf('MCH-upper_arm_ik.L');
      // Compared against the bone rather than a number, so changing the test
      // skeleton cannot quietly make this assertion meaningless.
      final rest = rig.armature['MCH-upper_arm_ik.L']!.length;
      expect(
        upper.length,
        closeTo(rest, 1e-3),
        reason:
            'a limb that stretches to reach is a different feature, and '
            'not one anybody asked for by accident',
      );
    });

    test('the switch hands the limb over rather than snapping', () {
      final rig = generator.generate(armMetaRig());
      final pose = rig.pose;

      pose['hand_ik.L'].location = Vector3(1.2, 0.8, 0);
      pose['upper_arm_fk.L'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        0.9,
      );

      pose.setProperty('upper_arm_ik_fk.L', 1);
      pose.evaluate();
      final forward = pose.headOf('DEF-hand.L').clone();

      pose.setProperty('upper_arm_ik_fk.L', 0);
      pose.evaluate();
      final inverse = pose.headOf('DEF-hand.L').clone();

      pose.setProperty('upper_arm_ik_fk.L', 0.5);
      pose.evaluate();
      final between = pose.headOf('DEF-hand.L');

      expect(
        (forward - inverse).length,
        greaterThan(0.5),
        reason:
            'the two ways of driving it should disagree, or the test '
            'proves nothing',
      );
      // Somewhere between the two, rather than at either end.
      expect((between - forward).length, greaterThan(1e-3));
      expect((between - inverse).length, greaterThan(1e-3));
    });

    test('the pole sits off the way the elbow already bends', () {
      final rig = generator.generate(armMetaRig());
      rig.pose.evaluate();

      final pole = rig.pose.headOf('upper_arm_pole.L');
      final elbow = rig.pose.headOf('ORG-forearm.L');

      // The meta-rig bends forwards in +X, so the pole should be that way —
      // derived from the rest pose rather than asked for.
      expect(pole.x, greaterThan(elbow.x));
    });

    test('mirrors generate independently, with their own names', () {
      final meta = armMetaRig();
      final right = armMetaRig(side: '.R');
      for (final bone in right.armature.bones) {
        meta.armature.add(bone);
      }
      meta.assign('upper_arm.R', const LimbRig());

      final rig = generator.generate(meta);

      expect(rig.armature.contains('hand_ik.L'), isTrue);
      expect(rig.armature.contains('hand_ik.R'), isTrue);
      expect(
        rig.properties.keys,
        containsAll(['upper_arm_ik_fk.L', 'upper_arm_ik_fk.R']),
      );
      expect(BoneNaming.mirror('hand_ik.L'), 'hand_ik.R');
    });
  });

  group('a finger', () {
    MetaRig fingerMetaRig() {
      final armature = Armature([
        Bone(
          name: 'f_index_01.L',
          head: Vector3.zero(),
          tail: Vector3(0, 1, 0),
        ),
        Bone(
          name: 'f_index_02.L',
          head: Vector3(0, 1, 0),
          tail: Vector3(0, 1.8, 0),
          parent: 'f_index_01.L',
          connected: true,
        ),
        Bone(
          name: 'f_index_03.L',
          head: Vector3(0, 1.8, 0),
          tail: Vector3(0, 2.4, 0),
          parent: 'f_index_02.L',
          connected: true,
        ),
      ]);
      return MetaRig(armature)..assign('f_index_01.L', const FingerRig());
    }

    test('one control curls every segment', () {
      final rig = generator.generate(fingerMetaRig());
      final pose = rig.pose;

      pose.evaluate();
      final straight = pose.tailOf('DEF-f_index_03.L').clone();

      expect(
        rig.controls,
        contains('f_index_curl.L'),
        reason:
            'the control is named for the finger, not for its first '
            'knuckle',
      );
      pose['f_index_curl.L'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        0.5,
      );
      pose.evaluate();

      expect(
        (pose.tailOf('DEF-f_index_03.L') - straight).length,
        greaterThan(0.3),
        reason:
            'animating three knuckles separately is possible and nobody '
            'does it',
      );
    });

    test('the segments still exist for a pose that needs them', () {
      final rig = generator.generate(fingerMetaRig());
      expect(rig.deformBones, hasLength(3));
    });
  });

  group('a spine', () {
    MetaRig spineMetaRig() {
      final armature = Armature([
        Bone(name: 'spine', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        Bone(
          name: 'spine_01',
          head: Vector3(0, 1, 0),
          tail: Vector3(0, 2, 0),
          parent: 'spine',
          connected: true,
        ),
        Bone(
          name: 'spine_02',
          head: Vector3(0, 2, 0),
          tail: Vector3(0, 3, 0),
          parent: 'spine_01',
          connected: true,
        ),
      ]);
      return MetaRig(armature)..assign('spine', const SpineRig());
    }

    test('gives an animator a torso, hips and a chest', () {
      final rig = generator.generate(spineMetaRig());
      expect(rig.controls, containsAll(['spine_torso', 'hips', 'chest']));
    });

    test('turning the chest bends the top of the spine most', () {
      final rig = generator.generate(spineMetaRig());
      final pose = rig.pose;

      pose.evaluate();
      final lowerBefore = pose.tailOf('DEF-spine').clone();
      final upperBefore = pose.tailOf('DEF-spine_02').clone();

      pose['chest'].rotation = Quaternion.axisAngle(Vector3(0, 0, 1), 0.5);
      pose.evaluate();

      final lowerMoved = (pose.tailOf('DEF-spine') - lowerBefore).length;
      final upperMoved = (pose.tailOf('DEF-spine_02') - upperBefore).length;

      expect(
        upperMoved,
        greaterThan(lowerMoved),
        reason:
            'a spine bends proportionally, which is what posing each '
            'vertebra by hand never quite achieves',
      );
    });
  });

  group('the generator', () {
    test('a chain stops where another rig begins', () {
      final meta = armMetaRig()..assign('hand.L', const CopyRig());
      final rig = generator.generate(meta);

      // The arm claimed two bones, and the hand claimed its own.
      expect(rig.armature.contains('hand'), isFalse);
      expect(
        rig.problems.map((p) => p.message).join(),
        contains('at least 3'),
        reason:
            'a limb needs three bones, and with the hand taken away it '
            'only has two — worth saying rather than half-building',
      );
    });

    test('problems are collected, not thrown at the first one', () {
      final meta =
          MetaRig(
              Armature([
                Bone(
                  name: 'lonely',
                  head: Vector3.zero(),
                  tail: Vector3(0, 1, 0),
                ),
              ]),
            )
            ..assign('lonely', const LimbRig())
            ..assign('ghost', const CopyRig());

      final rig = generator.generate(meta);

      expect(
        rig.problems,
        hasLength(2),
        reason:
            'an artist fixing a rig wants the whole list; one problem '
            'per generate turns a five minute fix into an afternoon',
      );
      expect(rig.hasProblems, isTrue);
    });

    test('a bone nobody claimed is reported rather than dropped', () {
      final meta = armMetaRig();
      meta.armature.add(
        Bone(name: 'forgotten', head: Vector3(9, 0, 0), tail: Vector3(9, 1, 0)),
      );

      final rig = generator.generate(meta);
      expect(
        rig.unassigned,
        contains('forgotten'),
        reason:
            'an unclaimed bone is almost always a chain somebody forgot '
            'to mark, and it is invisible in the result exactly when it '
            'matters',
      );
    });

    test('generating twice gives the same rig', () {
      final first = generator.generate(armMetaRig());
      final second = generator.generate(armMetaRig());

      expect(
        first.armature.evaluationOrder,
        second.armature.evaluationOrder,
        reason:
            'a generated rig that differs run to run cannot be diffed, '
            'and a rig nobody can diff is a rig nobody can review',
      );
    });

    test('an empty meta-rig generates an empty rig rather than failing', () {
      final rig = generator.generate(MetaRig(Armature()));
      expect(rig.armature.length, 0);
      expect(rig.problems, isEmpty);
    });
  });
}
