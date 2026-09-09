import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('a reflection probe', () {
    OrbisScene sceneWith(List<OrbisProbe> probes) => OrbisScene(
      objects: const [],
      camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
      probes: probes,
    );

    test('it crosses with everything the capture needs', () {
      final message = sceneWith([
        OrbisProbe(
          key: 7,
          position: Vector3(1, 2, 3),
          radius: 9,
          resolution: 128,
          version: 4,
          layers: 0x0F,
          intensity: 2,
        ),
      ]).toMessage(1);
      expect(message['probeKeys'], [7]);
      final params = message['probeParams']! as List<double>;
      expect(params, hasLength(OrbisProbe.stride));
      expect(params.sublist(0, 3), [1, 2, 3], reason: 'where it is taken from');
      expect(params[3], 9, reason: 'how far it reaches');
      expect(params[4], 128, reason: 'the size of a face');
      expect(params[5], 4, reason: 'the version');
      expect(params[6], 0x0F, reason: 'which layers it draws');
      expect(params[7], 2, reason: 'how much of it counts');
    });

    test('a scene with no probes still says so', () {
      // Empty rather than absent: the far side walks these arrays, and a key
      // missing from the message is a different thing to a key that is there
      // and empty.
      final message = sceneWith(const []).toMessage(1);
      expect(message['probeKeys'], isEmpty);
      expect(message['probeParams'], isEmpty);
    });

    test('the version is what asks for a new photograph', () {
      // Six renders of the whole scene is not a per-frame cost, so a probe is
      // captured and kept. The version is the only thing that says otherwise,
      // and two probes alike but for it have to differ on the wire.
      List<double> paramsFor(int version) =>
          sceneWith([
                OrbisProbe(key: 1, position: Vector3.zero(), version: version),
              ]).toMessage(1)['probeParams']!
              as List<double>;
      expect(paramsFor(0)[5], isNot(paramsFor(1)[5]));
    });
  });

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
