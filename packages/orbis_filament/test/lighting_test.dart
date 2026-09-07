import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('what crosses to the renderer keeps its shape', () {
    test('a light writes exactly the stride it declares', () {
      // The renderer walks this array by a stride of its own. When the two
      // disagree every light after the first reads a mixture of the one
      // before it and itself — which is what happened when the halo fields
      // took a light from sixteen floats to eighteen.
      final scene = OrbisScene(
        objects: const [],
        camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
        lights: [
          OrbisLight(
            key: 1,
            kind: OrbisLightKind.directional,
            intensity: 100000,
            direction: Vector3(0, -1, 0),
          ),
          OrbisLight(
            key: 2,
            kind: OrbisLightKind.point,
            intensity: 800,
            position: Vector3(3, 2, 1),
          ),
        ],
      );

      final params = scene.toMessage(1)['lightParams']! as List<double>;
      expect(params, hasLength(2 * OrbisLight.stride));

      // The second light starts exactly one stride in, and its own numbers
      // are there rather than the tail of the first.
      expect(params[OrbisLight.stride + 3], 800);
      expect(params[OrbisLight.stride + 4], 3);
      expect(params[OrbisLight.stride + 5], 2);
      expect(params[OrbisLight.stride + 6], 1);
    });

    test('a shading model keeps the number the renderer reads it by', () {
      // The renderer branches on this index. Reordering the enum to put a new
      // model in the middle is a silent swap of every video screen in every
      // scene for whatever took its place.
      expect(OrbisShading.lit.index, 0);
      expect(OrbisShading.unlit.index, 1);
      expect(OrbisShading.video.index, 2);
      expect(OrbisShading.shadowCatcher.index, 3);
    });
  });

  group('light clustering', () {
    test('the defaults are the ones a room-sized scene wants', () {
      final lighting = OrbisLighting();
      expect(lighting.clusterNear, 5);
      expect(lighting.clusterFar, 100);
    });

    test('it crosses on the end of the pipeline block', () {
      final pipeline = OrbisPipeline(
        lighting: OrbisLighting(clusterNear: 2, clusterFar: 400),
      );
      final packed = pipeline.packed;

      expect(packed, hasLength(OrbisPipeline.stride));
      expect(packed[16], 2);
      expect(packed[17], 400);
    });

    test('a pipeline that says nothing still sends the numbers', () {
      // A short block is one from before clustering existed, and the renderer
      // reads it as "use Filament's own defaults". A pipeline built today is
      // never short, so the two paths do not have to agree about anything.
      expect(OrbisPipeline().packed[16], 5);
      expect(OrbisPipeline().packed[17], 100);
    });

    test('every named detail tier carries clustering too', () {
      for (final detail in OrbisDetail.values) {
        expect(
          OrbisPipeline.at(detail).packed,
          hasLength(OrbisPipeline.stride),
        );
      }
    });
  });

  group('a shadow catcher', () {
    test('is a shading model, not a blend mode', () {
      // Its blending is fixed by what it is: a surface that is only its own
      // shadow is see-through by definition.
      const floor = OrbisMaterial(key: 9, shading: OrbisShading.shadowCatcher);
      expect(floor.shading, OrbisShading.shadowCatcher);
      expect(OrbisShading.shadowCatcher.isSurface, isFalse);
      expect(OrbisShading.lit.isSurface, isTrue);
    });

    test('it reaches the renderer as a shading model in the flags', () {
      final scene = OrbisScene(
        objects: const [],
        camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
        materials: const [
          OrbisMaterial(key: 9, shading: OrbisShading.shadowCatcher),
        ],
      );
      final flags = scene.toMessage(1)['materialFlags']! as List<int>;
      expect(flags.single & 3, 3);
    });
  });
}
