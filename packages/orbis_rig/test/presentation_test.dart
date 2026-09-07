import 'package:orbis_rig/orbis_rig.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

/// An arm, marked up as a limb.
GeneratedRig arm({double stretch = 0}) {
  final armature = Armature([
    Bone(
      name: 'upper_arm.L',
      head: Vector3(0.2, 1.5, 0),
      tail: Vector3(0.6, 1.5, -0.1),
    ),
    Bone(
      name: 'forearm.L',
      head: Vector3(0.6, 1.5, -0.1),
      tail: Vector3(1.0, 1.5, 0),
      parent: 'upper_arm.L',
      connected: true,
    ),
    Bone(
      name: 'hand.L',
      head: Vector3(1.0, 1.5, 0),
      tail: Vector3(1.2, 1.5, 0),
      parent: 'forearm.L',
      connected: true,
    ),
  ]);
  final meta = MetaRig(armature)
    ..assign('upper_arm.L', LimbRig(stretch: stretch));
  return const RigGenerator().generate(meta);
}

void main() {
  group('control widgets', () {
    test('every shape draws something', () {
      // A switch arm that returned nothing would be an invisible control, and
      // invisible is indistinguishable from missing.
      for (final shape in WidgetShape.values) {
        final lines = BoneWidget(shape: shape).outline(1);
        expect(lines, isNotEmpty, reason: '$shape drew no lines');
        for (final line in lines) {
          expect(line.length, greaterThanOrEqualTo(2), reason: '$shape');
        }
      }
    });

    test('a sphere is three rings, a circle is one', () {
      expect(const BoneWidget(shape: WidgetShape.sphere).outline(1).length, 3);
      expect(const BoneWidget(shape: WidgetShape.circle).outline(1).length, 1);
    });

    test(
      'scales with the bone, so a bigger character keeps its proportions',
      () {
        final small = const BoneWidget(shape: WidgetShape.circle).outline(1);
        final large = const BoneWidget(shape: WidgetShape.circle).outline(4);
        expect(large.first.first.x, closeTo(small.first.first.x * 4, 1e-9));
      },
    );

    test('size multiplies the bone length rather than replacing it', () {
      final plain = const BoneWidget(shape: WidgetShape.circle).outline(2);
      final double_ = const BoneWidget(
        shape: WidgetShape.circle,
        size: 2,
      ).outline(2);
      expect(double_.first.first.x, closeTo(plain.first.first.x * 2, 1e-9));
    });

    test('an offset moves the shape without resizing it', () {
      final moved = BoneWidget(
        shape: WidgetShape.circle,
        offset: Vector3(0, 1, 0),
      ).outline(2);
      // Offset is in bone lengths, so a bone of two moves the ring by two.
      for (final point in moved.first) {
        expect(point.y, closeTo(2, 1e-9));
      }
    });

    test('a limb gives its controls shapes an animator can tell apart', () {
      final rig = arm();

      expect(rig.widgets['hand_ik.L']?.shape, WidgetShape.cube);
      expect(rig.widgets['upper_arm_pole.L']?.shape, WidgetShape.square);
      expect(rig.widgets['upper_arm_fk.L']?.shape, WidgetShape.circle);
    });

    test('every control has a shape', () {
      final rig = arm();
      // A control with no shape falls back to a bone, which is legible but
      // says nothing about what the control does.
      for (final control in rig.controls) {
        expect(rig.widgets, contains(control), reason: control);
      }
    });
  });

  group('bone collections', () {
    test('machinery is hidden and controls are not', () {
      final rig = arm();

      for (final name in ['ORG', 'DEF', 'MCH']) {
        expect(rig.collections[name]?.visible, isFalse, reason: name);
      }
      // Named after the chain's first bone rather than a hand-set rig name,
      // so the collection is predictable from the skeleton alone.
      expect(rig.collections['upper_arm.L (IK)']?.visible, isTrue);
      expect(rig.collections['upper_arm.L (FK)']?.visible, isTrue);
    });

    test('every original, deform and mechanism bone is filed away', () {
      final rig = arm();

      for (final bone in rig.armature.bones) {
        final role = BoneNaming.roleOf(bone.name);
        if (role == BoneRole.control) continue;
        expect(
          rig.collections.collectionsOf(bone.name),
          isNotEmpty,
          reason: '${bone.name} is in nothing and cannot be hidden',
        );
      }
    });

    test('the two sides are different colours', () {
      expect(
        BoneCollections.colourFor(Side.left),
        isNot(BoneCollections.colourFor(Side.right)),
      );
    });

    test('a bone can be in more than one collection', () {
      final collections = BoneCollections()
        ..add('hand_ik.L', 'Arm.L (IK)')
        ..add('hand_ik.L', 'IK');

      expect(collections.collectionsOf('hand_ik.L'), ['Arm.L (IK)', 'IK']);
    });

    test('declaring the same collection twice is not a mistake', () {
      final collections = BoneCollections()
        ..declare('IK', colour: 1)
        ..declare('IK', colour: 2);

      // Both arms declare "IK" while generating; the second is not an error,
      // and it does not overwrite the first.
      expect(collections.all.length, 1);
      expect(collections['IK']?.colour, 1);
    });
  });

  group('stretch through the generator', () {
    test('a limb does not stretch unless it was asked to', () {
      final rig = arm();
      expect(rig.pose.ikChains.single.stretch, 0);
      expect(rig.properties.keys, isNot(contains('upper_arm_stretch.L')));
    });

    test('a stretchy limb gets a property an animator can turn down', () {
      final rig = arm(stretch: 0.5);
      expect(rig.properties['upper_arm_stretch.L'], 0.5);
      expect(rig.pose.ikChains.single.stretchProperty, 'upper_arm_stretch.L');
    });
  });
}
