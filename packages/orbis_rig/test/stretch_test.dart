import 'dart:math' as math;

import 'package:orbis_rig/orbis_rig.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

/// A two-bone chain along +Y, each bone a metre long, plus a goal to reach for.
({Armature armature, Pose pose}) limb({required Vector3 goal}) {
  final armature = Armature([
    Bone(name: 'upper', head: Vector3(0, 0, 0), tail: Vector3(0, 1, 0)),
    Bone(
      name: 'lower',
      head: Vector3(0, 1, 0),
      tail: Vector3(0, 2, 0),
      parent: 'upper',
      connected: true,
    ),
    Bone(name: 'goal', head: goal, tail: goal + Vector3(0, 0.2, 0)),
    Bone(name: 'pole', head: Vector3(0, 1, 2), tail: Vector3(0, 1.2, 2)),
  ]);
  return (armature: armature, pose: Pose(armature));
}

void main() {
  group('the solver', () {
    test('does not stretch a limb that can already reach', () {
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 1, 2),
        target: Vector3(0, 1.5, 0),
        upperLength: 1,
        lowerLength: 1,
        stretch: 1,
      );
      expect(solution.stretch, 1);
    });

    test('stops short when stretch is off', () {
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 1, 2),
        target: Vector3(0, 3, 0),
        upperLength: 1,
        lowerLength: 1,
      );
      expect(solution.stretch, 1);
      expect(solution.reachable, isFalse);
      // Straightened as far as it goes, and no further. The solver stops a
      // whisker inside full extension on purpose — exactly straight leaves the
      // bend plane undefined and the joint flips between frames — so the
      // tolerance here is wider than that margin rather than tighter.
      expect((solution.end - Vector3.zero()).length, closeTo(2, 1e-3));
    });

    test('reaches anything when stretch is full', () {
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 1, 2),
        target: Vector3(0, 3, 0),
        upperLength: 1,
        lowerLength: 1,
        stretch: 1,
      );
      expect(solution.reachable, isTrue);
      expect(solution.stretch, closeTo(1.5, 1e-9));
      expect((solution.end - Vector3(0, 3, 0)).length, lessThan(1e-9));
    });

    test('partial stretch closes part of the gap, not all of it', () {
      final solution = solveTwoBoneIk(
        root: Vector3.zero(),
        pole: Vector3(0, 1, 2),
        target: Vector3(0, 3, 0),
        upperLength: 1,
        lowerLength: 1,
        stretch: 0.5,
      );
      // Half of the way from 2 to 3.
      expect(solution.end.y, closeTo(2.5, 1e-9));
      expect(solution.reachable, isFalse);
    });
  });

  group('a stretching chain', () {
    test('lands its tail on a target it could not otherwise reach', () {
      final rig = limb(goal: Vector3(0, 3, 0));
      rig.pose
        ..addIkChain(
          const IkChain(
            root: 'upper',
            mid: 'lower',
            target: 'goal',
            pole: 'pole',
            stretch: 1,
          ),
        )
        ..evaluate();

      expect(rig.pose.tailOf('lower').y, closeTo(3, 1e-6));
    });

    test('narrows as it lengthens, rather than getting fatter', () {
      final rig = limb(goal: Vector3(0, 3, 0));
      rig.pose
        ..addIkChain(
          const IkChain(
            root: 'upper',
            mid: 'lower',
            target: 'goal',
            pole: 'pole',
            stretch: 1,
          ),
        )
        ..evaluate();

      final scale = rig.pose['upper'].scale;
      expect(scale.y, closeTo(1.5, 1e-9));
      // Volume preserved: the cross-section is the inverse square root of the
      // stretch, so a limb one and a half times as long is thinner, not just
      // scaled up.
      expect(scale.x, closeTo(1 / math.sqrt(1.5), 1e-9));
      expect(scale.x, lessThan(1));
      expect(scale.z, closeTo(scale.x, 1e-12));
    });

    test('the lower bone is not stretched twice by inherited scale', () {
      final rig = limb(goal: Vector3(0, 3, 0));
      rig.pose
        ..addIkChain(
          const IkChain(
            root: 'upper',
            mid: 'lower',
            target: 'goal',
            pole: 'pole',
            stretch: 1,
          ),
        )
        ..evaluate();

      // Scale is inherited, so the lower bone carries its own factor of one
      // and still ends up the right length. Scaling it as well would put its
      // tail at 3.75 rather than 3.
      expect(rig.pose['lower'].scale.y, 1);
      expect(rig.pose.headOf('lower').y, closeTo(1.5, 1e-6));
      expect(rig.pose.tailOf('lower').y, closeTo(3, 1e-6));
    });

    test('goes back to its own length when the target comes into reach', () {
      final armature = Armature([
        Bone(name: 'upper', head: Vector3(0, 0, 0), tail: Vector3(0, 1, 0)),
        Bone(
          name: 'lower',
          head: Vector3(0, 1, 0),
          tail: Vector3(0, 2, 0),
          parent: 'upper',
          connected: true,
        ),
        Bone(name: 'goal', head: Vector3(0, 3, 0), tail: Vector3(0, 3.2, 0)),
        Bone(name: 'pole', head: Vector3(0, 1, 2), tail: Vector3(0, 1.2, 2)),
      ]);
      final pose = Pose(armature)
        ..addIkChain(
          const IkChain(
            root: 'upper',
            mid: 'lower',
            target: 'goal',
            pole: 'pole',
            stretch: 1,
          ),
        )
        ..evaluate();

      expect(pose['upper'].scale.y, greaterThan(1.4));

      // The goal comes back within reach. A stretch left over from the frame
      // before would leave the limb permanently long, which is the failure
      // this guards.
      pose['goal'].location.setValues(0, -1.5, 0);
      pose.evaluate();

      expect(pose['upper'].scale.y, closeTo(1, 1e-6));
      expect(pose.tailOf('lower').y, closeTo(1.5, 1e-3));
    });

    test('an animator can turn stretch off through a property', () {
      final rig = limb(goal: Vector3(0, 3, 0));
      rig.pose
        ..setProperty('arm_stretch', 0)
        ..addIkChain(
          const IkChain(
            root: 'upper',
            mid: 'lower',
            target: 'goal',
            pole: 'pole',
            stretch: 1,
            stretchProperty: 'arm_stretch',
          ),
        )
        ..evaluate();

      expect(rig.pose['upper'].scale.y, closeTo(1, 1e-9));
      // Full extension, within the solver's stabilising margin.
      expect(rig.pose.tailOf('lower').y, closeTo(2, 1e-3));
    });
  });

  group('the stretch-to constraint', () {
    test('reaches a target and keeps its volume', () {
      final armature = Armature([
        Bone(name: 'hose', head: Vector3(0, 0, 0), tail: Vector3(0, 1, 0)),
        Bone(name: 'end', head: Vector3(0, 2, 0), tail: Vector3(0, 2.2, 0)),
      ]);
      final pose = Pose(armature)
        ..constrain('hose', const StretchTo(target: 'end', restLength: 1))
        ..evaluate();

      expect(pose.tailOf('hose').y, closeTo(2, 1e-6));

      final scale = Vector3.zero();
      pose
          .worldOf('hose')
          .decompose(Vector3.zero(), Quaternion.identity(), scale);
      expect(scale.y, closeTo(2, 1e-6));
      expect(scale.x, closeTo(1 / math.sqrt(2), 1e-6));
    });

    test('aims sideways as well as stretching', () {
      final armature = Armature([
        Bone(name: 'hose', head: Vector3(0, 0, 0), tail: Vector3(0, 1, 0)),
        Bone(name: 'end', head: Vector3(3, 0, 0), tail: Vector3(3.2, 0, 0)),
      ]);
      final pose = Pose(armature)
        ..constrain('hose', const StretchTo(target: 'end', restLength: 1))
        ..evaluate();

      final tail = pose.tailOf('hose');
      expect(tail.x, closeTo(3, 1e-6));
      expect(tail.y, closeTo(0, 1e-6));
    });

    test('leaves the cross-section alone when volume is off', () {
      final armature = Armature([
        Bone(name: 'hose', head: Vector3(0, 0, 0), tail: Vector3(0, 1, 0)),
        Bone(name: 'end', head: Vector3(0, 2, 0), tail: Vector3(0, 2.2, 0)),
      ]);
      final pose = Pose(armature)
        ..constrain(
          'hose',
          const StretchTo(target: 'end', restLength: 1, volume: 0),
        )
        ..evaluate();

      final scale = Vector3.zero();
      pose
          .worldOf('hose')
          .decompose(Vector3.zero(), Quaternion.identity(), scale);
      expect(scale.y, closeTo(2, 1e-6));
      expect(scale.x, closeTo(1, 1e-6));
    });
  });
}
