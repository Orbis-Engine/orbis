import 'dart:math' as math;

import 'package:orbis_rig/orbis_rig.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

Matcher near(double value, [double tolerance = 1e-6]) =>
    closeTo(value, tolerance);

void expectVector(
  Vector3 actual,
  Vector3 expected, {
  double tolerance = 1e-5,
  String? reason,
}) {
  final because = reason == null ? '' : ' — $reason';
  expect(
    actual.x,
    closeTo(expected.x, tolerance),
    reason: 'x of $actual$because',
  );
  expect(
    actual.y,
    closeTo(expected.y, tolerance),
    reason: 'y of $actual$because',
  );
  expect(
    actual.z,
    closeTo(expected.z, tolerance),
    reason: 'z of $actual$because',
  );
}

/// A two-bone arm along +Y, the simplest thing that has a hierarchy.
Armature arm() => Armature([
  Bone(name: 'upper', head: Vector3.zero(), tail: Vector3(0, 2, 0)),
  Bone(
    name: 'lower',
    head: Vector3(0, 2, 0),
    tail: Vector3(0, 5, 0),
    parent: 'upper',
    connected: true,
  ),
]);

void main() {
  _propertyDrivenConstraints();
  group('a bone', () {
    test('measures itself between its ends', () {
      final bone = Bone(
        name: 'b',
        head: Vector3.zero(),
        tail: Vector3(0, 3, 0),
      );
      expect(bone.length, near(3));
      expectVector(bone.direction, Vector3(0, 1, 0));
    });

    test('pointing along +Y is the identity orientation', () {
      // The convention the whole package rests on: a bone's own Y axis runs
      // head to tail, so a bone already pointing that way is unrotated.
      final bone = Bone(
        name: 'b',
        head: Vector3.zero(),
        tail: Vector3(0, 1, 0),
      );
      final axis = bone.restMatrix.transform3(Vector3(0, 1, 0));
      expectVector(axis, Vector3(0, 1, 0));
    });

    test('turns its own Y towards where it points', () {
      final bone = Bone(
        name: 'b',
        head: Vector3.zero(),
        tail: Vector3(2, 0, 0),
      );
      // The bone's local Y, taken into armature space, is the direction it
      // points. Read through the matrix rather than the quaternion, because
      // the library's own quaternion rotation runs the other way and has
      // caught this codebase out twice.
      final axis = bone.restMatrix.transform3(Vector3(0, 1, 0));
      expectVector(axis, Vector3(1, 0, 0));
    });

    test('sits at its head', () {
      final bone = Bone(
        name: 'b',
        head: Vector3(1, 2, 3),
        tail: Vector3(1, 5, 3),
      );
      expectVector(bone.restMatrix.getTranslation(), Vector3(1, 2, 3));
    });

    test('roll twists about the bone rather than moving it', () {
      final straight = Bone(
        name: 'b',
        head: Vector3.zero(),
        tail: Vector3(0, 1, 0),
      );
      final rolled = Bone(
        name: 'b',
        head: Vector3.zero(),
        tail: Vector3(0, 1, 0),
        roll: math.pi / 2,
      );

      // Still pointing the same way...
      expectVector(
        rolled.restMatrix.transform3(Vector3(0, 1, 0)),
        straight.restMatrix.transform3(Vector3(0, 1, 0)),
      );
      // ...but turned about that direction, which is what decides where a
      // knee bends.
      final x = rolled.restMatrix.transform3(Vector3(1, 0, 0));
      expect(x.x, near(0, 1e-6));
    });

    test('a zero-length bone still produces a usable matrix', () {
      final bone = Bone(name: 'b', head: Vector3.zero(), tail: Vector3.zero());
      expect(bone.restMatrix.getTranslation().length, near(0));
      expect(
        bone.direction.length,
        near(1),
        reason:
            'a degenerate bone should fall back to an axis rather than '
            'fill the matrix with NaNs',
      );
    });
  });

  group('an armature', () {
    test('evaluates parents before children', () {
      final order = arm().evaluationOrder;
      expect(order.indexOf('upper'), lessThan(order.indexOf('lower')));
    });

    test('refuses a bone that is its own ancestor', () {
      final armature = Armature([
        Bone(
          name: 'a',
          head: Vector3.zero(),
          tail: Vector3(0, 1, 0),
          parent: 'b',
        ),
        Bone(
          name: 'b',
          head: Vector3.zero(),
          tail: Vector3(0, 1, 0),
          parent: 'a',
        ),
      ]);
      expect(() => armature.evaluationOrder, throwsA(isA<ArmatureError>()));
    });

    test('refuses a parent that is not there', () {
      final armature = Armature([
        Bone(
          name: 'a',
          head: Vector3.zero(),
          tail: Vector3(0, 1, 0),
          parent: 'ghost',
        ),
      ]);
      expect(() => armature.evaluationOrder, throwsA(isA<ArmatureError>()));
    });

    test('refuses two bones with the same name', () {
      final armature = Armature();
      armature.add(
        Bone(name: 'a', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
      );
      expect(
        () => armature.add(
          Bone(name: 'a', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        ),
        throwsA(isA<ArmatureError>()),
      );
    });

    test('removing a bone promotes its children rather than breaking', () {
      final armature = arm()..remove('upper');
      expect(armature['lower']!.parent, isNull);
      expect(
        armature.evaluationOrder,
        ['lower'],
        reason:
            'a rig that loses a bone should keep evaluating, so the '
            'mistake shows up as a limb in the wrong place',
      );
    });

    test('a child rests relative to its parent', () {
      final local = arm().restLocalOf('lower');
      // The lower bone starts two units up its parent's own axis.
      expectVector(local.getTranslation(), Vector3(0, 2, 0));
    });
  });

  group('posing', () {
    test('at rest, a bone is where it rests', () {
      final armature = arm();
      final pose = Pose(armature)..evaluate();

      expectVector(pose.headOf('lower'), Vector3(0, 2, 0));
      expectVector(pose.tailOf('lower'), Vector3(0, 5, 0));
    });

    test('at rest, skinning changes nothing', () {
      final pose = Pose(arm())..evaluate();
      final matrix = pose.skinningOf('lower');
      final point = matrix.transform3(Vector3(1, 3, 2));
      expectVector(
        point,
        Vector3(1, 3, 2),
        reason:
            'the rest pose is the pose the mesh was bound in, so it '
            'must move nothing',
      );
    });

    test('turning a parent carries its children', () {
      final armature = arm();
      final pose = Pose(armature);

      // Fold the upper bone a quarter turn about Z: +Y becomes -X.
      pose['upper'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose.evaluate();

      expectVector(pose.tailOf('upper'), Vector3(-2, 0, 0));
      expectVector(
        pose.headOf('lower'),
        Vector3(-2, 0, 0),
        reason: 'a connected child follows its parent to the joint',
      );
      expectVector(pose.tailOf('lower'), Vector3(-5, 0, 0));
    });

    test('a child turns about its own joint, not the root', () {
      final pose = Pose(arm());
      pose['lower'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose.evaluate();

      // The elbow has not moved; the forearm has swung from it.
      expectVector(pose.headOf('lower'), Vector3(0, 2, 0));
      expectVector(pose.tailOf('lower'), Vector3(-3, 2, 0));
    });

    test('resetting puts everything back', () {
      final pose = Pose(arm());
      pose['upper'].rotation = Quaternion.axisAngle(Vector3(0, 0, 1), 1.2);
      pose
        ..evaluate()
        ..reset()
        ..evaluate();
      expectVector(pose.tailOf('lower'), Vector3(0, 5, 0));
    });

    test('only deforming bones produce skinning matrices', () {
      final armature = arm();
      armature['lower']!.deform = false;
      final pose = Pose(armature)..evaluate();

      expect(
        pose.skinningMatrices().keys,
        ['upper'],
        reason:
            'a generated rig has far more bones than deforming ones, '
            'and skinning should only ever see the deforming ones',
      );
    });
  });

  group('two-bone inverse kinematics', () {
    test('reaches a target it can reach', () {
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 0, 5),
        target: Vector3(3, 1, 0),
        upperLength: 2,
        lowerLength: 3,
      );

      expect(solution.reachable, isTrue);
      expectVector(solution.end, Vector3(3, 1, 0));
    });

    test('keeps both bones their own length', () {
      const upper = 2.0, lower = 3.0;
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 0, 5),
        target: Vector3(3.5, 1, 0),
        upperLength: upper,
        lowerLength: lower,
      );

      expect(solution.joint.length, near(upper, 1e-5));
      expect((solution.end - solution.joint).length, near(lower, 1e-5));
    });

    test('the pole decides which way the joint bends', () {
      Vector3 jointWithPole(Vector3 pole) => solveTwoBoneIk(
        root: Vector3.zero(),
        pole: pole,
        target: Vector3(4, 0, 0),
        upperLength: 3,
        lowerLength: 3,
      ).joint;

      final front = jointWithPole(Vector3(2, 0, 5));
      final back = jointWithPole(Vector3(2, 0, -5));

      // Mirrored about the line to the target: the difference between a knee
      // and a backwards knee.
      expect(front.z.sign, isNot(back.z.sign));
      expect(front.z.abs(), closeTo(back.z.abs(), 1e-5));
    });

    test('straightens towards a target it cannot reach', () {
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 0, 5),
        target: Vector3(100, 0, 0),
        upperLength: 2,
        lowerLength: 3,
      );

      expect(solution.reachable, isFalse);
      // Extended along the line to the target, rather than left where it was —
      // a limb that gives up looks broken, one that strains does not.
      //
      // Not quite perfectly straight: the solver stops a hair short, because
      // an exactly straight limb has no defined bend plane and the joint would
      // flip between frames as rounding pushed it either side. A fifth of a
      // degree off axis is the price, and it is invisible.
      expect(solution.end.length, closeTo(5, 1e-3));
      expectVector(
        solution.end.normalized(),
        Vector3(1, 0, 0),
        tolerance: 5e-3,
      );
    });

    test('folds as far as it goes towards something too close', () {
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 0, 5),
        target: Vector3(0.01, 0, 0),
        upperLength: 3,
        lowerLength: 1,
      );

      expect(solution.reachable, isFalse);
      // Cannot get closer than the difference between the two bones.
      expect(solution.end.length, closeTo(2, 0.01));
    });

    test('a pole in line with the target still gives a usable bend', () {
      // Degenerate: the pole names no plane. It should pick one rather than
      // produce a limb full of NaNs.
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(2, 0, 0),
        target: Vector3(4, 0, 0),
        upperLength: 3,
        lowerLength: 3,
      );

      expect(solution.joint.x.isFinite, isTrue);
      expect(solution.joint.length, near(3, 1e-5));
    });
  });

  group('constraints', () {
    test('copy rotation takes another bone\'s orientation', () {
      final armature = Armature([
        Bone(name: 'source', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        Bone(name: 'target', head: Vector3(5, 0, 0), tail: Vector3(5, 1, 0)),
      ]);

      final pose = Pose(armature);
      pose['source'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose
        ..constrain('target', CopyRotation('source'))
        ..evaluate();

      // Turned like the source, but still where it was.
      expectVector(pose.headOf('target'), Vector3(5, 0, 0));
      expectVector(pose.tailOf('target'), Vector3(4, 0, 0));
    });

    test('influence blends rather than switching', () {
      final armature = Armature([
        Bone(name: 'source', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        Bone(name: 'target', head: Vector3(5, 0, 0), tail: Vector3(5, 1, 0)),
      ]);

      final pose = Pose(armature);
      pose['source'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose
        ..constrain('target', CopyRotation('source', influence: 0.5))
        ..evaluate();

      // Half of a quarter turn: the tail should be up and across, not fully
      // across. A head that half-follows reads as attention; one that fully
      // follows reads as a turret.
      final tail = pose.tailOf('target');
      expect(tail.x, lessThan(5));
      expect(tail.y, greaterThan(0));
    });

    test('damped track aims the chosen axis at a target', () {
      final armature = Armature([
        Bone(name: 'eye', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        Bone(name: 'focus', head: Vector3(0, 0, -4), tail: Vector3(0, 1, -4)),
      ]);

      final pose = Pose(armature)
        ..constrain('eye', DampedTrack(target: 'focus'))
        ..evaluate();

      // The bone's own Y now points at the focus.
      final direction = (pose.tailOf('eye') - pose.headOf('eye')).normalized();
      expectVector(direction, Vector3(0, 0, -1), tolerance: 1e-5);
    });

    test('limit rotation clamps how far a joint bends', () {
      final armature = Armature([
        Bone(name: 'finger', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
      ]);

      final pose = Pose(armature);
      // Asked for a half turn, allowed a quarter.
      pose['finger'].rotation = Quaternion.axisAngle(Vector3(0, 0, 1), math.pi);
      pose
        ..constrain('finger', LimitRotation(maximumAngle: math.pi / 2))
        ..evaluate();

      final tail = pose.tailOf('finger');
      // A quarter turn about Z puts +Y at -X.
      expectVector(tail, Vector3(-1, 0, 0), tolerance: 1e-5);
    });

    test('a constraint carries the bones below it', () {
      final armature = arm();
      final extra = Armature([
        Bone(name: 'source', head: Vector3(9, 0, 0), tail: Vector3(9, 1, 0)),
      ]);
      armature.add(extra['source']!);

      final pose = Pose(armature);
      pose['source'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose
        ..constrain('upper', CopyRotation('source'))
        ..evaluate();

      // Constraining the upper arm swung the forearm too, which is what makes
      // a rig a mechanism rather than a list of parts.
      expectVector(pose.tailOf('lower'), Vector3(-5, 0, 0), tolerance: 1e-5);
    });
  });

  group('naming', () {
    test('a prefix says what a bone is for', () {
      expect(BoneNaming.roleOf('DEF-upper_arm.L'), BoneRole.deform);
      expect(BoneNaming.roleOf('ORG-spine'), BoneRole.original);
      expect(BoneNaming.roleOf('MCH-ik_target'), BoneRole.mechanism);
      expect(BoneNaming.roleOf('hand_ik.L'), BoneRole.control);
    });

    test('a side survives a duplicate suffix', () {
      expect(BoneNaming.sideOf('hand.L'), Side.left);
      expect(BoneNaming.sideOf('hand.R'), Side.right);
      expect(
        BoneNaming.sideOf('hand.L.001'),
        Side.left,
        reason:
            'the number goes after the side, so anything that only '
            'looked at the end of the name would call this sideless',
      );
      expect(BoneNaming.sideOf('spine'), isNull);
    });

    test('the base is what is left after the role and the side', () {
      expect(BoneNaming.baseOf('DEF-upper_arm.L'), 'upper_arm');
      expect(BoneNaming.baseOf('MCH-foot_roll.R.001'), 'foot_roll');
      expect(BoneNaming.baseOf('spine'), 'spine');
    });

    test('names are built from their parts', () {
      expect(
        BoneNaming.compose('upper_arm', role: BoneRole.deform, side: Side.left),
        'DEF-upper_arm.L',
      );
      expect(BoneNaming.compose('spine'), 'spine');
    });

    test('a bone can be asked for in another role', () {
      expect(
        BoneNaming.asRole('DEF-upper_arm.L', BoneRole.control),
        'upper_arm.L',
      );
      expect(
        BoneNaming.asRole('upper_arm.L', BoneRole.mechanism),
        'MCH-upper_arm.L',
      );
    });

    test('mirroring swaps the side and keeps everything else', () {
      expect(BoneNaming.mirror('DEF-hand.L'), 'DEF-hand.R');
      expect(BoneNaming.mirror('hand.R'), 'hand.L');
      expect(
        BoneNaming.mirror('spine'),
        isNull,
        reason: 'a bone on the midline has no opposite',
      );
    });

    test('a constraint that closes a loop is refused', () {
      final armature = Armature([
        Bone(name: 'a', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        Bone(name: 'b', head: Vector3(1, 0, 0), tail: Vector3(1, 1, 0)),
      ]);

      final pose = Pose(armature)
        ..constrain('a', CopyRotation('b'))
        ..constrain('b', CopyRotation('a'));

      // No order satisfies both, and saying so is better than evaluating one
      // of them against last frame's answer.
      expect(pose.evaluate, throwsA(isA<ArmatureError>()));
    });

    test('a constraint on a cousin is evaluated in the right order', () {
      // The case that made ordering follow constraints: two roots, where the
      // one added first reads the one added second.
      final armature = Armature([
        Bone(name: 'reader', head: Vector3.zero(), tail: Vector3(0, 1, 0)),
        Bone(name: 'source', head: Vector3(5, 0, 0), tail: Vector3(5, 1, 0)),
      ]);

      final pose = Pose(armature);
      pose['source'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose
        ..constrain('reader', CopyRotation('source'))
        ..evaluate();

      expectVector(pose.tailOf('reader'), Vector3(-1, 0, 0), tolerance: 1e-5);
    });
  });

  group('more naming', () {
    test('mirrors are recognised as a pair', () {
      expect(BoneNaming.areMirrors('hand.L', 'hand.R'), isTrue);
      expect(BoneNaming.areMirrors('hand.L', 'foot.R'), isFalse);
      expect(BoneNaming.areMirrors('spine', 'spine'), isFalse);
    });
  });
}

void _propertyDrivenConstraints() {
  group('a constraint driven by a property', () {
    Pose twoBones() {
      final armature = Armature([
        Bone(name: 'driver', head: Vector3(0, 0, 0), tail: Vector3(0, 1, 0)),
        Bone(name: 'follower', head: Vector3(1, 0, 0), tail: Vector3(1, 1, 0)),
      ]);
      return Pose(armature);
    }

    test('copy rotation reads the property, not the fixed influence', () {
      // Declaring influenceProperty and then ignoring it is the worst kind of
      // failure: the slider moves, nothing happens, and nothing says why.
      final pose = twoBones()
        ..setProperty('blend', 0)
        ..constrain(
          'follower',
          const CopyRotation('driver', influenceProperty: 'blend'),
        );

      pose['driver'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose.evaluate();
      final unblended = pose.tailOf('follower').clone();
      expect(unblended.y, closeTo(1, 1e-6), reason: 'should be unmoved at 0');

      pose.setProperty('blend', 1);
      pose.evaluate();
      expect(pose.tailOf('follower').x, closeTo(0, 1e-6));
    });

    test('damped track reads the property too', () {
      final pose = twoBones()
        ..setProperty('look', 0)
        ..constrain(
          'follower',
          const DampedTrack(target: 'driver', influenceProperty: 'look'),
        );

      pose.evaluate();
      expect(pose.tailOf('follower').y, closeTo(1, 1e-6));

      pose.setProperty('look', 1);
      pose.evaluate();
      // Now aimed at the driver, which is a metre to its left.
      expect(pose.tailOf('follower').x, closeTo(0, 1e-6));
    });

    test('an inverted influence is the other half of a switch', () {
      final pose = twoBones()
        ..setProperty('blend', 1)
        ..constrain(
          'follower',
          const CopyRotation(
            'driver',
            influenceProperty: 'blend',
            invertInfluence: true,
          ),
        );

      pose['driver'].rotation = Quaternion.axisAngle(
        Vector3(0, 0, 1),
        math.pi / 2,
      );
      pose.evaluate();
      // One minus one is nothing, so the follower stays put.
      expect(pose.tailOf('follower').y, closeTo(1, 1e-6));
    });
  });
}
