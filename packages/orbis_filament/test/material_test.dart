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
