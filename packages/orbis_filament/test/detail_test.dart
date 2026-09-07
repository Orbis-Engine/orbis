import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  const tree = OrbisLod([
    OrbisStep('/trees/oak_near.glb', 30),
    OrbisStep('/trees/oak_mid.glb', 120),
    OrbisStep('/trees/oak_far.glb', 400),
  ]);

  group('choosing a step', () {
    test('near the camera is the near mesh', () {
      expect(tree.meshAt(5), '/trees/oak_near.glb');
      expect(tree.meshAt(29.9), '/trees/oak_near.glb');
    });

    test('each boundary hands over to the next', () {
      expect(tree.meshAt(30), '/trees/oak_near.glb');
      expect(tree.meshAt(30.1), '/trees/oak_mid.glb');
      expect(tree.meshAt(120), '/trees/oak_mid.glb');
      expect(tree.meshAt(120.1), '/trees/oak_far.glb');
    });

    test('past the last step it is not drawn at all', () {
      // Null rather than the crudest mesh: past its range is the application
      // saying it is not worth the pixels, and falling back to a default
      // would put the worst version of it on screen for ever.
      expect(tree.meshAt(401), isNull);
      expect(tree.isVisibleAt(401), isFalse);
      expect(tree.isVisibleAt(400), isTrue);
    });

    test('a step list that runs inwards is a mistake worth seeing', () {
      const muddled = OrbisLod([
        OrbisStep('/far.glb', 400),
        OrbisStep('/near.glb', 30),
      ]);
      expect(muddled.isOrdered, isFalse);
      expect(tree.isOrdered, isTrue);
    });

    test('no steps at all draws nothing rather than throwing', () {
      // What a half-written asset looks like. It should show up as a missing
      // tree, not as a dead frame.
      const empty = OrbisLod([]);
      expect(empty.meshAt(1), isNull);
      expect(empty.isVisibleAt(0), isFalse);
    });

    test('one step is a range, not a level of detail, and that is allowed', () {
      const simple = OrbisLod([OrbisStep('/rock.glb', 80)]);
      expect(simple.meshAt(79), '/rock.glb');
      expect(simple.meshAt(81), isNull);
    });

    test('a last step that never ends draws for ever', () {
      const mountain = OrbisLod([
        OrbisStep('/near.glb', 500),
        OrbisStep('/far.glb', double.infinity),
      ]);
      expect(mountain.meshAt(50000), '/far.glb');
    });
  });

  group('hysteresis', () {
    test('sitting on a boundary does not flicker', () {
      // The camera breathing across 30m would otherwise swap the mesh on
      // every frame — visible, and a mesh change each time it happens.
      expect(tree.stepAt(30.5, was: 0), 0);
      expect(tree.stepAt(32, was: 0), 0);
      // Far enough past it to mean it.
      expect(tree.stepAt(34, was: 0), 1);
    });

    test('coming back the other way changes at the boundary itself', () {
      // Only the step being shown holds on. Coming inwards there is nothing
      // to hold on to, so the near mesh arrives as soon as it is right.
      expect(tree.stepAt(29, was: 1), 0);
    });

    test('with no history the boundary is taken at face value', () {
      expect(tree.stepAt(30.5), 1);
    });
  });

  group('a scene of them', () {
    test('each object remembers its own step', () {
      final state = OrbisDetailState();
      final camera = Vector3.zero();

      // One just inside the near boundary, one well inside it.
      expect(
        state.meshFor(1, tree, Vector3(29, 0, 0), camera),
        '/trees/oak_near.glb',
      );
      expect(
        state.meshFor(2, tree, Vector3(10, 0, 0), camera),
        '/trees/oak_near.glb',
      );

      // The first drifts out; the second does not move. One changing does not
      // change the other.
      expect(
        state.meshFor(1, tree, Vector3(40, 0, 0), camera),
        '/trees/oak_mid.glb',
      );
      expect(
        state.meshFor(2, tree, Vector3(10, 0, 0), camera),
        '/trees/oak_near.glb',
      );
    });

    test('something out of range is forgotten rather than frozen', () {
      final state = OrbisDetailState();
      final camera = Vector3.zero();

      state.meshFor(1, tree, Vector3(10, 0, 0), camera);
      expect(state.length, 1);

      expect(state.meshFor(1, tree, Vector3(900, 0, 0), camera), isNull);
      expect(state.length, 0);

      // Back in shot, it picks its step from where it is now.
      expect(
        state.meshFor(1, tree, Vector3(200, 0, 0), camera),
        '/trees/oak_far.glb',
      );
    });

    test('distance is to the camera, not along one axis', () {
      final state = OrbisDetailState();
      // A little over 30 metres away diagonally, so past the near step even
      // though no single axis is.
      expect(
        state.meshFor(1, tree, Vector3(25, 25, 0), Vector3.zero()),
        '/trees/oak_mid.glb',
      );
    });

    test('a reloaded scene starts again', () {
      final state = OrbisDetailState();
      state.meshFor(1, tree, Vector3(10, 0, 0), Vector3.zero());
      state.clear();
      expect(state.length, 0);
    });
  });
}
