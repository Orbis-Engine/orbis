import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('the default pipeline draws shadows at every pixel', () {
    final pipeline = OrbisPipeline();
    expect(pipeline.shadows.enabled, isTrue);
    expect(pipeline.resolution.scale, 1.0);
    expect(pipeline.resolution.adaptive, isFalse);
    expect(pipeline.samples, 1, reason: 'multisampling is opt-in');
    expect(pipeline.culling, isTrue);
  });

  test('the four named settings differ only in how much, not in what', () {
    final tiers = [
      for (final detail in OrbisDetail.values) OrbisPipeline.at(detail)
    ];
    // Nothing appears or disappears between them: a scene authored for one is
    // the same scene on all four.
    expect(tiers.every((one) => one.shadows.enabled), isTrue);
    expect(tiers.every((one) => one.culling), isTrue);
    expect(tiers.every((one) => one.refraction), isTrue);

    final sizes = [for (final one in tiers) one.shadows.mapSize];
    expect(sizes, [512, 1024, 2048, 4096], reason: 'each tier doubles');
    final cascades = [for (final one in tiers) one.shadows.cascades];
    expect(cascades, [1, 2, 3, 4]);
  });

  test('only the lowest setting is allowed to shrink the frame', () {
    expect(OrbisPipeline.at(OrbisDetail.low).resolution.adaptive, isTrue);
    for (final detail in [
      OrbisDetail.medium,
      OrbisDetail.high,
      OrbisDetail.ultra,
    ]) {
      expect(OrbisPipeline.at(detail).resolution.adaptive, isFalse,
          reason: '${detail.label} holds its resolution');
    }
  });

  test('a fixed scale packs as a range with nowhere to go', () {
    final fixed = OrbisPipeline(resolution: OrbisResolution(scale: 0.75));
    final packed = fixed.packed;
    expect(packed[10], 0, reason: 'not adaptive');
    expect(packed[11], closeTo(0.75, 1e-6));
    expect(packed[12], closeTo(0.75, 1e-6));

    final moving = OrbisPipeline(
      resolution: OrbisResolution(adaptive: true, minScale: 0.6, maxScale: 1),
    );
    expect(moving.packed[10], 1);
    expect(moving.packed[11], closeTo(0.6, 1e-6));
    expect(moving.packed[12], 1);
  });

  test('the shadow flags pack together', () {
    final plain = OrbisPipeline().packed;
    expect(plain[8], 0);
    final both = OrbisPipeline(
      shadows: OrbisShadows(stable: true, contact: true),
    ).packed;
    expect(both[8], 3);
    final contactOnly = OrbisPipeline(
      shadows: OrbisShadows(contact: true),
    ).packed;
    expect(contactOnly[8], 2);
  });

  test('the view flags pack together', () {
    expect(OrbisPipeline().packed[15], 6, reason: 'culling and refraction');
    expect(
      OrbisPipeline(precise: true, culling: false, refraction: false)
          .packed[15],
      1,
    );
  });

  test('a scene carries a pipeline whether or not one was given', () {
    final scene = OrbisScene(
      objects: const [],
      camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
    );
    final packed = scene.toMessage(0)['pipelineParams']!;
    expect(packed, hasLength(OrbisPipeline.stride));

    final ultra = OrbisScene(
      objects: const [],
      pipeline: OrbisPipeline.at(OrbisDetail.ultra),
      camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
    );
    expect((ultra.toMessage(0)['pipelineParams']! as List)[2], 4096);
  });

  test('the shadow kind travels as its own index', () {
    for (final kind in OrbisShadowKind.values) {
      final packed = OrbisPipeline(shadows: OrbisShadows(kind: kind)).packed;
      expect(packed[1], kind.index);
    }
  });
}
