import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

/// A float32 cannot hold most of the doubles written into it, so nothing here
/// compares for equality.
Matcher near(double value) => closeTo(value, 1e-6);

void main() {
  OrbisScene sceneOf(List<OrbisObject> objects, List<OrbisMaterial> materials) {
    return OrbisScene(
      objects: objects,
      materials: materials,
      camera: OrbisCamera(position: Vector3(0, 2, 6), target: Vector3.zero()),
    );
  }

  OrbisObject objectOn(int key, {int? material}) => OrbisObject(
    key: key,
    material: material,
    transform: Matrix4.identity(),
    colour: Vector3(1, 1, 1),
  );

  test('a material with nothing said about it still draws something', () {
    const material = OrbisMaterial(key: 1);
    expect(material.baseColour.w, 1.0, reason: 'opaque');
    expect(material.metallic, 0.0);
    expect(
      material.roughness,
      greaterThan(0.0),
      reason: 'a perfectly smooth surface flickers',
    );
    expect(material.tiling.x, 1.0);
    expect(material.maps, everyElement(isNull));
  });

  test('flags separate what needs a rebuild from what does not', () {
    const opaque = OrbisMaterial(key: 1);
    const faded = OrbisMaterial(key: 1, blend: OrbisBlend.fade);
    const twoSided = OrbisMaterial(key: 1, doubleSided: true);

    expect(opaque.flags & 3, OrbisShading.lit.index);
    expect((opaque.flags >> 2) & 15, OrbisBlend.opaque.index);
    expect((faded.flags >> 2) & 15, OrbisBlend.fade.index);
    expect((twoSided.flags >> 8) & 1, 1);
    expect((opaque.flags >> 8) & 1, 0);
    expect((opaque.flags >> 9) & 1, 1, reason: 'depth write is on by default');
  });

  group('wind', () {
    test('a surface says nothing about it and does not move', () {
      // The vertex stage is compiled into every lit surface, so the thing
      // that has to be true is that a material which never mentions wind
      // takes the early return. Both the speed and the compliance are nought,
      // and either one alone is enough to stop it.
      const material = OrbisMaterial(key: 1);
      expect(material.wind, OrbisWind.none);
      expect(material.wind.moves, isFalse);

      final packed = Float32List(OrbisMaterial.stride);
      material.pack(packed, 0);
      expect(packed[35], 0.0, reason: 'speed');
      expect(packed[36], 0.0, reason: 'compliance');
    });

    test('still air and a rigid surface both fold to nought', () {
      // Two different ways of saying "does not move", and the shader has one
      // early return rather than two, so both have to arrive as zero.
      final gale = OrbisMaterial(
        key: 1,
        wind: const OrbisWind(bearing: 90, speed: 20, strength: 0),
      );
      final calm = OrbisMaterial(
        key: 2,
        wind: const OrbisWind(bearing: 90, speed: 0, strength: 1),
      );

      final packed = Float32List(OrbisMaterial.stride);
      gale.pack(packed, 0);
      expect(packed[35], 0.0, reason: 'a rigid surface in a gale');
      calm.pack(packed, 0);
      expect(packed[36], 0.0, reason: 'a canopy in still air');
    });

    test('a bearing becomes a direction on the ground', () {
      // North is negative Z in a right-handed Y-up world, which is the same
      // convention `WeatherState.windFrom` uses — the two have to agree or a
      // scene's rain and its trees blow in different directions.
      const north = OrbisWind(bearing: 0, speed: 1);
      expect(north.direction.x, closeTo(0, 1e-9));
      expect(north.direction.y, closeTo(1, 1e-9));

      const east = OrbisWind(bearing: 90, speed: 1);
      expect(east.direction.x, closeTo(1, 1e-9));
      expect(east.direction.y, closeTo(0, 1e-9));
    });

    test('it packs where the renderer reads it', () {
      final material = OrbisMaterial(
        key: 1,
        wind: const OrbisWind(bearing: 90, speed: 6, strength: 0.75),
      );

      final packed = Float32List(OrbisMaterial.stride);
      material.pack(packed, 0);
      expect(packed[33], near(1.0), reason: 'east, x');
      expect(packed[34], closeTo(0, 1e-6), reason: 'east, z');
      expect(packed[35], near(6.0));
      expect(packed[36], near(0.75));
    });

    test('copyWith carries it', () {
      const base = OrbisMaterial(key: 1);
      final swaying = base.copyWith(
        wind: const OrbisWind(bearing: 180, speed: 3),
      );
      expect(swaying.wind.moves, isTrue);
      expect(swaying.wind.speed, 3);
      expect(base.wind.moves, isFalse, reason: 'the original is untouched');
    });
  });

  group('the three extra lobes', () {
    test('a surface that asked for none carries none', () {
      // The whole design rests on this: the coat, the grain and the sheen are
      // compiled into every lit surface, so if their defaults were anything
      // but inert, every material in every scene would quietly gain a
      // varnish. Nought is not a tidy default here, it is the feature being
      // off.
      const material = OrbisMaterial(key: 1);
      expect(material.clearCoat, 0.0);
      expect(material.anisotropy, 0.0);
      expect(material.sheenColour, Vector3.zero());

      final packed = Float32List(OrbisMaterial.stride);
      material.pack(packed, 0);
      expect(packed[26], 0.0, reason: 'clear coat');
      expect(packed[28], 0.0, reason: 'anisotropy');
      expect(packed[29], 0.0, reason: 'sheen red');
      expect(packed[30], 0.0, reason: 'sheen green');
      expect(packed[31], 0.0, reason: 'sheen blue');
    });

    test('each one packs where the renderer reads it', () {
      final material = OrbisMaterial(
        key: 1,
        clearCoat: 0.8,
        clearCoatRoughness: 0.05,
        anisotropy: -0.6,
        sheenColour: Vector3(0.2, 0.3, 0.4),
        sheenRoughness: 0.55,
      );

      final packed = Float32List(OrbisMaterial.stride);
      material.pack(packed, 0);
      expect(packed[26], near(0.8));
      expect(packed[27], near(0.05));
      // Negative is a direction, not a mistake: the grain runs the other way.
      expect(packed[28], near(-0.6));
      expect(packed[29], near(0.2));
      expect(packed[30], near(0.3));
      expect(packed[31], near(0.4));
      expect(packed[32], near(0.55));
    });

    test('a second material starts where the first one ends', () {
      // The failure this guards is the one the light stride already had once:
      // the row grew and an offset somewhere did not follow, so everything
      // after the first row read the row before it. Packing two and checking
      // the second is the cheapest way to notice.
      final packed = Float32List(OrbisMaterial.stride * 2);
      const OrbisMaterial(key: 1, clearCoat: 1.0).pack(packed, 0);
      const OrbisMaterial(key: 2, clearCoat: 0.25).pack(
        packed,
        OrbisMaterial.stride,
      );

      expect(packed[26], near(1.0));
      expect(packed[OrbisMaterial.stride + 26], near(0.25));
    });

    test('copyWith carries them', () {
      const base = OrbisMaterial(key: 1);
      final coated = base.copyWith(clearCoat: 0.5, anisotropy: 0.9);
      expect(coated.clearCoat, 0.5);
      expect(coated.anisotropy, 0.9);
      // And leaves everything it was not asked about alone.
      expect(coated.roughness, base.roughness);
      expect(coated.sheenColour, Vector3.zero());
    });
  });

  test('the numbers pack in the order the renderer reads them', () {
    final material = OrbisMaterial(
      key: 1,
      baseColour: Vector4(0.1, 0.2, 0.3, 0.4),
      metallic: 0.5,
      roughness: 0.6,
      reflectance: 0.7,
      emissive: Vector3(0.8, 0.9, 1.0),
      emissiveIntensity: 2.0,
      ambientOcclusion: 0.25,
      normalScale: 1.5,
      tiling: Vector2(3, 4),
      offset: Vector2(0.05, 0.06),
      maskThreshold: 0.75,
    );
    final packed = Float32List(OrbisMaterial.stride);
    material.pack(packed, 0);

    expect(packed[0], near(0.1));
    expect(packed[3], near(0.4));
    expect(packed[4], near(0.5));
    expect(packed[6], near(0.7));
    expect(packed[10], near(2.0));
    expect(packed[13], near(3.0));
    expect(packed[16], near(0.06));
    expect(packed[17], near(0.75));
  });

  test('an object points at a material by its place in the list', () {
    final scene = sceneOf(
      [objectOn(1, material: 70), objectOn(2), objectOn(3, material: 60)],
      const [OrbisMaterial(key: 60), OrbisMaterial(key: 70)],
    );
    final message = scene.toMessage(0);
    final indices = message['objectMaterials']! as Int32List;

    expect(indices[0], 1, reason: 'key 70 is second in the list');
    expect(indices[1], -1, reason: 'no material named');
    expect(indices[2], 0);
  });

  test(
    'naming a material the scene does not list falls back rather than fails',
    () {
      final scene = sceneOf([objectOn(1, material: 999)], const []);
      final indices = scene.toMessage(0)['objectMaterials']! as Int32List;
      expect(indices[0], -1);
    },
  );

  test('an image on several materials travels once', () {
    const shared = OrbisTexture('/tmp/one.png');
    final scene = sceneOf(
      [objectOn(1, material: 1)],
      const [
        OrbisMaterial(key: 1, baseColourMap: shared, emissiveMap: shared),
        OrbisMaterial(key: 2, baseColourMap: shared),
      ],
    );
    final message = scene.toMessage(0);
    final paths = message['texturePaths']! as List<String>;
    final maps = message['materialMaps']! as Int32List;

    expect(paths, ['/tmp/one.png']);
    expect(maps[0], 0, reason: 'the first material base colour');
    expect(maps[4], 0, reason: 'and its emissive, the same entry');
    expect(maps[1], -1, reason: 'no normal map');
    expect(maps[OrbisMaterial.mapCount], 0, reason: 'the second material too');
  });

  test('the same file in two colour spaces is two textures', () {
    final scene = sceneOf(
      [objectOn(1, material: 1)],
      const [
        OrbisMaterial(
          key: 1,
          baseColourMap: OrbisTexture('/tmp/one.png'),
          normalMap: OrbisTexture('/tmp/one.png', srgb: false),
        ),
      ],
    );
    final message = scene.toMessage(0);
    final srgb = message['textureSrgb']! as Int32List;

    expect((message['texturePaths']! as List<String>).length, 2);
    expect(srgb[0], 1);
    expect(srgb[1], 0);
  });

  test('a scene with no materials still says so', () {
    final scene = sceneOf([objectOn(1)], const []);
    final message = scene.toMessage(0);
    expect((message['materialKeys']! as Int64List), isEmpty);
    expect((message['materialParams']! as Float32List), isEmpty);
    expect((message['objectMaterials']! as Int32List).single, -1);
  });

  test('every material contributes its own stride, in list order', () {
    final scene = sceneOf(
      [objectOn(1, material: 2)],
      [
        OrbisMaterial(key: 1, roughness: 0.11),
        OrbisMaterial(key: 2, roughness: 0.22),
      ],
    );
    final params = scene.toMessage(0)['materialParams']! as Float32List;
    expect(params.length, 2 * OrbisMaterial.stride);
    expect(params[5], near(0.11));
    expect(params[OrbisMaterial.stride + 5], near(0.22));
  });

  test('a screen points at a video by its place in the list', () {
    final scene = OrbisScene(
      objects: [
        OrbisObject(
          key: 1,
          material: 10,
          transform: Matrix4.identity(),
          colour: Vector3(1, 1, 1),
        ),
      ],
      materials: const [
        OrbisMaterial(key: 10, shading: OrbisShading.video, video: 7),
        OrbisMaterial(key: 11, shading: OrbisShading.video, video: 999),
        OrbisMaterial(key: 12),
      ],
      videos: const [
        OrbisVideo(key: 5, path: '/tmp/a.mp4'),
        OrbisVideo(key: 7, path: '/tmp/b.mp4'),
      ],
      camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
    );
    final message = scene.toMessage(0);

    expect((message['materialVideos']! as Int32List)[0], 1);
    expect(
      (message['materialVideos']! as Int32List)[1],
      -1,
      reason: 'a video the scene does not list',
    );
    expect(
      (message['materialVideos']! as Int32List)[2],
      -1,
      reason: 'not a screen at all',
    );
    expect(message['videoPaths'], ['/tmp/a.mp4', '/tmp/b.mp4']);
  });

  test('a seek only counts when its token moves', () {
    OrbisScene sceneWith(OrbisVideo video) => OrbisScene(
      objects: const [],
      videos: [video],
      camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
    );

    final still = sceneWith(const OrbisVideo(key: 1, path: '/tmp/a.mp4'));
    final params = still.toMessage(0)['videoParams']! as Float32List;
    expect(params[2], -1, reason: 'no seek asked for');
    expect(params[3], 0);

    final jumped = sceneWith(
      const OrbisVideo(key: 1, path: '/tmp/a.mp4', seekTo: 12, seekToken: 3),
    );
    final moved = jumped.toMessage(0)['videoParams']! as Float32List;
    expect(moved[2], 12);
    expect(moved[3], 3);
  });

  test('a paused looping video says so in its flags', () {
    const video = OrbisVideo(key: 1, path: '/a', playing: false, loop: true);
    expect(video.flags & 1, 0);
    expect(video.flags & 2, 2);
  });

  test('copyWith keeps the maps and the key', () {
    const material = OrbisMaterial(
      key: 4,
      baseColourMap: OrbisTexture('/tmp/a.png'),
      roughness: 0.3,
    );
    final rougher = material.copyWith(roughness: 0.9);
    expect(rougher.key, 4);
    expect(rougher.roughness, 0.9);
    expect(rougher.baseColourMap?.path, '/tmp/a.png');
  });

  group('a second surface blended into the first', () {
    test('its mode, amount and tiling reach the message', () {
      final scene = sceneOf(
        [objectOn(1, material: 9)],
        [
          OrbisMaterial(
            key: 9,
            blendMode: OrbisBlendMode.maskedDepth,
            blendAmount: 0.4,
            blendSharpness: 12,
            blendTiling: Vector2(8, 8),
            blendOffset: Vector2(0.25, 0.5),
          ),
        ],
      );

      final params = scene.toMessage(0)['materialParams']! as Float32List;
      const at = 0;
      expect(params[at + 19], OrbisBlendMode.maskedDepth.index);
      expect(params[at + 20], near(0.4));
      expect(params[at + 21], near(12));
      expect(params[at + 22], near(8));
      expect(params[at + 23], near(8));
      expect(params[at + 24], near(0.25));
      expect(params[at + 25], near(0.5));
    });

    test('its maps sit after the first surface\'s', () {
      final scene = sceneOf(
        [objectOn(1, material: 9)],
        [
          const OrbisMaterial(
            key: 9,
            baseColourMap: OrbisTexture('/ground/cobbles.png'),
            blendBaseColourMap: OrbisTexture('/ground/grass.png'),
            blendMaskMap: OrbisTexture('/ground/height.png'),
          ),
        ],
      );

      final message = scene.toMessage(0);
      final paths = message['texturePaths']! as List<String>;
      final maps = message['materialMaps']! as Int32List;

      // The order the renderer reads them back in. Getting this wrong swaps
      // a mask for a colour map and shows up as a surface that is somehow
      // the wrong material rather than as anything that looks like an index.
      expect(maps, hasLength(OrbisMaterial.mapCount));
      expect(paths[maps[0]], '/ground/cobbles.png');
      expect(paths[maps[5]], '/ground/grass.png');
      expect(paths[maps[6]], '/ground/height.png');
      // Untouched slots stay empty rather than pointing at something.
      expect(maps[1], -1);
      expect(maps[4], -1);
    });

    test('a material that does not blend costs no maps and no mode', () {
      final scene = sceneOf(
        [objectOn(1, material: 9)],
        [const OrbisMaterial(key: 9)],
      );

      final message = scene.toMessage(0);
      final params = message['materialParams']! as Float32List;
      final maps = message['materialMaps']! as Int32List;

      expect(params[19], OrbisBlendMode.none.index);
      expect(maps[5], -1);
      expect(maps[6], -1);
      expect(message['texturePaths'], isEmpty);
    });

    test(
      'the blend layer tiles with the first when it is not told otherwise',
      () {
        // Two surfaces the same size of thing is the ordinary case, and having
        // to restate the tiling for it would be a trap: forget, and the second
        // layer silently tiles once across a field.
        const material = OrbisMaterial(
          key: 9,
          blendMode: OrbisBlendMode.linear,
        );
        final tiled = OrbisMaterial(
          key: 9,
          tiling: Vector2(16, 16),
          blendMode: OrbisBlendMode.linear,
        );

        expect(material.blendTiling, material.tiling);
        expect(tiled.blendTiling, Vector2(16, 16));
      },
    );
  });
}
