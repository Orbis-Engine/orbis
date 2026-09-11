import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  OrbisScene courtyard({
    List<OrbisEnvironmentVolume>? volumes,
    Vector3? camera,
    OrbisPostProcess? post,
    OrbisEnvironment? environment,
  }) => OrbisScene(
    objects: const [],
    camera: OrbisCamera(
      position: camera ?? Vector3(0, 0, 20),
      target: Vector3.zero(),
    ),
    sky: OrbisSky(colour: Vector3(0.6, 0.7, 0.9), ambient: 20000),
    fog: OrbisFog(density: 0.002, colour: Vector3(0.7, 0.8, 0.9)),
    post: post,
    environment: environment,
    volumes: volumes,
  );

  // A hall ten metres square round the origin, with a two metre doorway's
  // worth of blend outside it.
  OrbisEnvironmentVolume hall({
    OrbisEnvironmentOverrides? overrides,
    int priority = 0,
    int key = 1,
    double weight = 1,
  }) => OrbisEnvironmentVolume.box(
    key: key,
    centre: Vector3.zero(),
    halfExtents: Vector3.all(5),
    blendDistance: 2,
    priority: priority,
    weight: weight,
    overrides:
        overrides ??
        OrbisEnvironmentOverrides(
          fogDensity: 0.1,
          fogColour: Vector3(0.4, 0.3, 0.2),
          ambient: 2000,
          exposureCompensation: -1,
        ),
  );

  group('where a volume reaches', () {
    test('full inside, nothing past the blend, a smoothstep between', () {
      final sphere = OrbisEnvironmentVolume.sphere(
        key: 1,
        centre: Vector3.zero(),
        radius: 3,
        blendDistance: 2,
        overrides: const OrbisEnvironmentOverrides(),
      );
      expect(sphere.influenceAt(Vector3.zero()), 1);
      expect(sphere.influenceAt(Vector3(3, 0, 0)), 1, reason: 'on the skin');
      expect(sphere.influenceAt(Vector3(4, 0, 0)), closeTo(0.5, 1e-12));
      expect(sphere.influenceAt(Vector3(5, 0, 0)), 0);
      expect(sphere.influenceAt(Vector3(9, 0, 0)), 0);
      // A quarter of the way into the band: 1 - smoothstep(0.25).
      expect(sphere.influenceAt(Vector3(3.5, 0, 0)), closeTo(0.84375, 1e-12));
    });

    test('the weight scales all of it', () {
      final half = hall(weight: 0.5);
      expect(half.influenceAt(Vector3.zero()), 0.5);
      expect(half.influenceAt(Vector3(6, 0, 0)), closeTo(0.25, 1e-12));
    });

    test('a hard edge is all or nothing', () {
      final hard = OrbisEnvironmentVolume.sphere(
        key: 1,
        centre: Vector3.zero(),
        radius: 1,
        blendDistance: 0,
        overrides: const OrbisEnvironmentOverrides(),
      );
      expect(hard.influenceAt(Vector3(0.99, 0, 0)), 1);
      expect(hard.influenceAt(Vector3(1.01, 0, 0)), 0);
    });

    test('a box measures from its surface, corners included', () {
      final box = hall();
      expect(box.distanceTo(Vector3(4, 4, 4)), 0);
      expect(box.distanceTo(Vector3(6, 0, 0)), closeTo(1, 1e-12));
      // Past a corner the distance is to the corner, not to either face.
      expect(box.distanceTo(Vector3(6, 6, 0)), closeTo(math.sqrt(2), 1e-12));
    });

    test('a turned box is turned', () {
      // Long along x, then turned a quarter about the vertical so it is long
      // along z instead.
      final box = OrbisEnvironmentVolume.box(
        key: 1,
        centre: Vector3.zero(),
        halfExtents: Vector3(10, 1, 1),
        rotation: Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 2),
        blendDistance: 0,
        overrides: const OrbisEnvironmentOverrides(),
      );
      expect(box.influenceAt(Vector3(0, 0, 8)), 1);
      expect(box.influenceAt(Vector3(8, 0, 0)), 0);
    });
  });

  group('resolving the look', () {
    test('outside every volume the scene is the one the host built', () {
      final scene = courtyard(volumes: [hall()], camera: Vector3(0, 0, 20));
      final seen = scene.resolved();
      // The same objects, not equal copies: nothing downstream should see
      // anything move.
      expect(identical(seen.fog, scene.fog), isTrue);
      expect(identical(seen.sky, scene.sky), isTrue);
      expect(identical(seen.post, scene.post), isTrue);
      expect(identical(seen.camera, scene.camera), isTrue);
      expect(seen.volumes, isEmpty);
    });

    test('inside, what the volume names is what it says', () {
      final seen = courtyard(
        volumes: [hall()],
        camera: Vector3(1, 1, 1),
      ).resolved();
      expect(seen.fog.density, closeTo(0.1, 1e-12));
      expect(seen.fog.colour, Vector3(0.4, 0.3, 0.2));
      expect(seen.sky.ambient, closeTo(2000, 1e-9));
      expect(seen.camera.shutterSpeed, closeTo(1 / 250, 1e-12));
    });

    test('what the volume does not name is left exactly alone', () {
      final scene = courtyard(
        volumes: [hall(overrides: const OrbisEnvironmentOverrides())],
        camera: Vector3.zero(),
      );
      final seen = scene.resolved();
      expect(identical(seen.fog, scene.fog), isTrue);
      expect(identical(seen.sky, scene.sky), isTrue);

      // Only the fog, and only its density.
      final fogOnly = courtyard(
        volumes: [
          hall(overrides: const OrbisEnvironmentOverrides(fogDensity: 0.3)),
        ],
        camera: Vector3.zero(),
      );
      final fogged = fogOnly.resolved();
      expect(fogged.fog.density, 0.3);
      expect(fogged.fog.colour, fogOnly.fog.colour);
      expect(fogged.fog.cutOffDistance, fogOnly.fog.cutOffDistance);
      expect(identical(fogged.sky, fogOnly.sky), isTrue);
      expect(identical(fogged.post, fogOnly.post), isTrue);
      expect(fogged.camera.shutterSpeed, fogOnly.camera.shutterSpeed);
    });

    test('in the band, each kind of number blends in its own space', () {
      // Halfway through the band, where the smoothstep is a half.
      final seen = courtyard(
        volumes: [hall()],
        camera: Vector3(6, 0, 0),
      ).resolved();
      expect(seen.fog.density, closeTo((0.002 + 0.1) / 2, 1e-12));
      expect(seen.fog.colour.x, closeTo((0.7 + 0.4) / 2, 1e-12));
      // Light in log space: halfway between 20000 and 2000 is their
      // geometric mean.
      expect(seen.sky.ambient, closeTo(math.sqrt(20000 * 2000), 1e-6));
      // Half a stop down.
      expect(
        seen.camera.shutterSpeed,
        closeTo(1 / 125 * math.pow(2, -0.5), 1e-12),
      );
    });

    test('a turn blends the short way round', () {
      final scene = courtyard(
        environment: const OrbisEnvironment(rotation: 350 * math.pi / 180),
        volumes: [
          hall(
            overrides: const OrbisEnvironmentOverrides(
              environmentRotation: 10 * math.pi / 180,
            ),
          ),
        ],
        camera: Vector3(6, 0, 0),
      );
      final turned = scene.resolved().environment.rotation;
      // Through nought, not through a hundred and eighty.
      expect(math.cos(turned), closeTo(1, 1e-12));
    });

    test('a switched-off bloom and grade come on from nothing', () {
      final scene = courtyard(
        volumes: [
          hall(
            overrides: OrbisEnvironmentOverrides(
              bloomStrength: 0.4,
              saturation: 0.5,
              temperature: 0.2,
              midtones: Vector3(1, 0.9, 0.8),
            ),
          ),
        ],
        camera: Vector3(6, 0, 0),
      );
      expect(scene.post.bloom.enabled, isFalse);
      expect(scene.post.grading.enabled, isFalse);
      final post = scene.resolved().post;
      expect(post.bloom.enabled, isTrue);
      expect(post.bloom.strength, closeTo(0.2, 1e-12));
      expect(post.grading.enabled, isTrue);
      expect(post.grading.saturation, closeTo(0.75, 1e-12));
      expect(post.grading.temperature, closeTo(0.1, 1e-12));
      expect(post.grading.contrast, 1, reason: 'neutral, not a stale value');
      expect(post.grading.midtones.z, closeTo(0.9, 1e-12));
      // The host's objects are the host's: nothing was switched on in them.
      expect(scene.post.bloom.enabled, isFalse);
      expect(scene.post.grading.enabled, isFalse);
    });

    test('where two overlap, the higher priority has the last word', () {
      final low = hall(
        key: 1,
        overrides: const OrbisEnvironmentOverrides(fogDensity: 0.1),
      );
      final high = hall(
        key: 2,
        priority: 5,
        overrides: const OrbisEnvironmentOverrides(fogDensity: 0.5),
      );
      for (final order in [
        [low, high],
        [high, low],
      ]) {
        final inside = courtyard(
          volumes: order,
          camera: Vector3.zero(),
        ).resolved();
        expect(inside.fog.density, closeTo(0.5, 1e-12));

        // In the band both are at a half: the low one takes the scene's
        // 0.002 halfway to 0.1, and the high one takes that halfway to 0.5.
        final band = courtyard(
          volumes: order,
          camera: Vector3(6, 0, 0),
        ).resolved();
        expect(band.fog.density, closeTo(((0.002 + 0.1) / 2 + 0.5) / 2, 1e-12));
      }
    });

    test('equal priorities are settled by key, not by listing order', () {
      final a = hall(
        key: 3,
        overrides: const OrbisEnvironmentOverrides(fogDensity: 0.1),
      );
      final b = hall(
        key: 4,
        overrides: const OrbisEnvironmentOverrides(fogDensity: 0.5),
      );
      final one = courtyard(volumes: [a, b], camera: Vector3.zero());
      final other = courtyard(volumes: [b, a], camera: Vector3.zero());
      expect(one.resolved().fog.density, other.resolved().fog.density);
      expect(one.resolved().fog.density, closeTo(0.5, 1e-12));
    });

    test('the same question always gets the same answer', () {
      final volumes = [
        hall(key: 1),
        OrbisEnvironmentVolume.sphere(
          key: 2,
          centre: Vector3(3, 0, 0),
          radius: 2,
          blendDistance: 3,
          priority: 1,
          overrides: OrbisEnvironmentOverrides(
            fogColour: Vector3(0.1, 0.2, 0.6),
            ambient: 500,
          ),
        ),
      ];
      final base = OrbisEnvironmentSettings.of(courtyard());
      for (final at in [Vector3(5.5, 0.3, -1), Vector3(0, 0, 0)]) {
        final first = base.resolve(volumes, at).values;
        final second = base.resolve(volumes.reversed.toList(), at).values;
        expect(second, first);
      }
    });

    test('walking through the door changes the look without a step', () {
      // A hundred and one paces from well outside to well inside. A blend
      // that stepped would show as one pace changing far more than its
      // neighbours; a continuous one changes by a bounded amount each pace,
      // and only ever in one direction.
      final volumes = [hall()];
      final base = OrbisEnvironmentSettings.of(courtyard());
      final densities = <double>[];
      final ambients = <double>[];
      for (var i = 0; i <= 100; i++) {
        final x = 10 - i * 0.1;
        final seen = base.resolve(volumes, Vector3(x, 0, 0));
        densities.add(seen.fogDensity);
        ambients.add(seen.ambient);
      }
      expect(densities.first, 0.002);
      expect(densities.last, closeTo(0.1, 1e-12));
      for (var i = 1; i < densities.length; i++) {
        // The smoothstep's steepest slope is 1.5 per band width, so a pace of
        // a twentieth of the band moves at most 7.5% of the way.
        expect(
          densities[i] - densities[i - 1],
          lessThanOrEqualTo(0.098 * 0.076),
        );
        expect(densities[i], greaterThanOrEqualTo(densities[i - 1]));
        expect(ambients[i], lessThanOrEqualTo(ambients[i - 1]));
      }
    });
  });

  group('on the wire', () {
    test('a scene with volumes sends the scene they resolve to', () {
      final scene = courtyard(volumes: [hall()], camera: Vector3(6, 0, 0));
      final sent = scene.toMessage(1);
      final expected = scene.resolved().toMessage(1);
      expect(sent['fogParams'], expected['fogParams']);
      expect(sent['ambient'], expected['ambient']);
      expect(sent['shutterSpeed'], expected['shutterSpeed']);
      final fog = sent['fogParams']! as List<double>;
      expect(fog[3], closeTo(0.051, 1e-6), reason: 'the density, blended');
    });

    test('copying a scene keeps its probes, field and volumes', () {
      final scene = OrbisScene(
        objects: const [],
        camera: OrbisCamera(
          position: Vector3.zero(),
          target: Vector3(0, 0, -1),
        ),
        probes: [OrbisProbe(key: 9, position: Vector3.zero())],
        volumes: [hall()],
      );
      final copy = scene.copyWith(fog: OrbisFog.none);
      expect(copy.probes, hasLength(1));
      expect(copy.volumes, hasLength(1));
      expect(identical(copy.field, scene.field), isTrue);
    });
  });
}
