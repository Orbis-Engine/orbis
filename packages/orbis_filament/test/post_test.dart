import 'package:orbis_filament/orbis_filament.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('what arrives at the renderer', () {
    test('is as long as the renderer expects', () {
      expect(OrbisPostProcess().packed, hasLength(OrbisPostProcess.stride));
    });

    test('starts with everything off but the picture still made', () {
      final post = OrbisPostProcess();

      // A renderer that arrives with bloom on is one where the first question
      // is how to turn it off.
      expect(post.bloom.enabled, isFalse);
      expect(post.depthOfField.enabled, isFalse);
      expect(post.vignette.enabled, isFalse);
      expect(post.occlusion.enabled, isFalse);
      expect(post.reflections.enabled, isFalse);
      expect(post.grading.enabled, isFalse);

      // But tone mapping and anti-aliasing happen anyway: something has to
      // decide how light becomes pixels.
      expect(post.enabled, isTrue);
      expect(post.grading.toneMapping, ToneMapping.filmic);
      expect(post.antiAliasing, AntiAliasing.fxaa);
      expect(post.dithering, isTrue);
    });

    test('carries every number it was given', () {
      final post = OrbisPostProcess(
        bloom: OrbisBloom(enabled: true, strength: 0.4, levels: 8),
        vignette: OrbisVignette(enabled: true, midPoint: 0.3),
        grading: OrbisGrading(
          enabled: true,
          toneMapping: ToneMapping.aces,
          exposure: 1.5,
          saturation: 1.2,
        ),
      );

      final packed = post.packed;

      /// Whether a number made it across.
      ///
      /// Compared loosely because the array is float32: 0.4 as a double is not
      /// 0.4 as a float, and an exact match would be testing the width of the
      /// array rather than the value in it.
      bool carries(double wanted) =>
          packed.any((value) => (value - wanted).abs() < 1e-6);

      expect(carries(0.4), isTrue, reason: 'bloom strength');
      expect(carries(8), isTrue, reason: 'bloom levels');
      expect(carries(1.5), isTrue, reason: 'exposure');
      expect(carries(1.2), isTrue, reason: 'saturation');
      expect(packed[35], ToneMapping.aces.index.toDouble());
    });

    test('flags are one and nought rather than anything else', () {
      final packed = OrbisPostProcess(bloom: OrbisBloom(enabled: true)).packed;

      for (final value in packed) {
        expect(value.isFinite, isTrue);
      }
      expect(packed[0], 1.0, reason: 'post-processing is on');
      expect(packed[3], 1.0, reason: 'bloom is on');
    });

    test('a colour triple is three numbers in order', () {
      final post = OrbisPostProcess(
        grading: OrbisGrading(
          shadows: Vector3(0.1, 0.2, 0.3),
          midtones: Vector3(0.4, 0.5, 0.6),
          highlights: Vector3(0.7, 0.8, 0.9),
        ),
      );

      final packed = post.packed;
      final at = OrbisPostProcess.stride - 9;
      final wanted = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9];

      for (var i = 0; i < 9; i++) {
        expect(packed[at + i], closeTo(wanted[i], 1e-6));
      }
    });
  });

  group('the scene it belongs to', () {
    test('has one, and sends it', () {
      final scene = OrbisScene(
        objects: const [],
        camera: OrbisCamera(
          position: Vector3.zero(),
          target: Vector3(0, 0, -1),
        ),
      );

      final message = scene.toMessage(1);
      expect(message['postParams'], isNotNull);
      expect((message['postParams']! as List).length, OrbisPostProcess.stride);
    });

    test('a look belongs to the scene rather than to a camera', () {
      // Four views of one world should not each grade it differently.
      final scene = OrbisScene(
        objects: const [],
        camera: OrbisCamera(
          position: Vector3.zero(),
          target: Vector3(0, 0, -1),
        ),
        post: OrbisPostProcess(bloom: OrbisBloom(enabled: true)),
      );

      expect(scene.post.bloom.enabled, isTrue);
    });
  });
}
