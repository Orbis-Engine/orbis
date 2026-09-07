import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  OrbisScene sceneWith(OrbisEnvironment? environment) => OrbisScene(
    objects: const [],
    environment: environment,
    camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
  );

  group('an environment', () {
    test('nothing named is nothing set', () {
      expect(OrbisEnvironment.none.isSet, isFalse);
      expect(const OrbisEnvironment(radiance: '').isSet, isFalse);
    });

    test('either half on its own is a real environment', () {
      // Light with no visible sky is what an interior lit through a window
      // wants; a backdrop that lights nothing is a matte painting.
      expect(const OrbisEnvironment(radiance: '/k_ibl.ktx').isSet, isTrue);
      expect(const OrbisEnvironment(skybox: '/k_skybox.ktx').isSet, isTrue);
    });

    test('it is stated in the same unit as every other light', () {
      const outdoors = OrbisEnvironment(
        radiance: '/day_ibl.ktx',
        intensity: 80000,
      );
      expect(outdoors.packed[0], 80000);
    });

    test('turning it is what makes one bake serve any scene', () {
      const turned = OrbisEnvironment(radiance: '/a.ktx', rotation: 1.5);
      expect(turned.packed[1], 1.5);
    });

    test('the backdrop can be sampled without being drawn', () {
      const hidden = OrbisEnvironment(
        radiance: '/a.ktx',
        skybox: '/a_sky.ktx',
        showSkybox: false,
      );
      expect(hidden.packed[2], 0);
      expect(const OrbisEnvironment(radiance: '/a.ktx').packed[2], 1);
    });
  });

  group('on a scene', () {
    test('a scene that says nothing sends an environment of nothing', () {
      final message = sceneWith(null).toMessage(1);

      expect(message['environmentRadiance'], '');
      expect(message['environmentSkybox'], '');
      // The numbers still cross, so the renderer never reads a short array.
      expect(message['environmentParams'], hasLength(OrbisEnvironment.stride));
    });

    test('the paths cross as paths and the numbers as numbers', () {
      final message = sceneWith(
        const OrbisEnvironment(
          radiance: '/env/kitchen_ibl.ktx',
          skybox: '/env/kitchen_skybox.ktx',
          intensity: 12000,
        ),
      ).toMessage(1);

      expect(message['environmentRadiance'], '/env/kitchen_ibl.ktx');
      expect(message['environmentSkybox'], '/env/kitchen_skybox.ktx');
      expect((message['environmentParams']! as List)[0], 12000);
    });

    test('changing only the brightness leaves the files alone', () {
      // What the renderer leans on to avoid re-reading a cubemap off disk on
      // every frame of a slider drag.
      const before = OrbisEnvironment(radiance: '/a.ktx', intensity: 1000);
      final after = before.copyWith(intensity: 2000);

      expect(after.radiance, before.radiance);
      expect(after.packed[0], 2000);
    });
  });
}
