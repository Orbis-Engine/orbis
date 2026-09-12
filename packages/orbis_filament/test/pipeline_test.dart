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
      for (final detail in OrbisDetail.values) OrbisPipeline.at(detail),
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
      expect(
        OrbisPipeline.at(detail).resolution.adaptive,
        isFalse,
        reason: '${detail.label} holds its resolution',
      );
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

  test('the variance flags pack beside the older two', () {
    final packed = OrbisPipeline(
      shadows: OrbisShadows(
        stable: true,
        variance: OrbisVarianceShadows(
          highPrecision: true,
          mipmapping: true,
          exponential: true,
        ),
      ),
    ).packed;
    expect(packed[8], 1 + 4 + 8 + 16);
  });

  test('the defaults are the ones the renderer had before', () {
    // A scene written before these dials existed must draw the same, so
    // every default here is Filament's own.
    final packed = OrbisPipeline().packed;
    expect(packed, hasLength(28));
    expect(packed.sublist(18, 21), [0, 0, 0], reason: 'lambda places them');
    expect(packed[21], 1, reason: 'physical penumbra falloff');
    expect(packed[22], 0, reason: 'no anisotropy');
    expect(packed[23], 0, reason: 'no blur');
    expect(packed[24], closeTo(0.15, 1e-6));
    expect(packed[25], 1, reason: 'one sample');
    expect(packed[26], closeTo(0.3, 1e-6));
    expect(packed[27], 8);
  });

  test(
    'cascade splits and the contact trace land where the renderer looks',
    () {
      final packed = OrbisPipeline(
        shadows: OrbisShadows(
          cascades: 4,
          splits: [0.1, 0.3, 0.6],
          softnessFalloff: 2,
          contactDistance: 0.8,
          contactSteps: 16,
          variance: OrbisVarianceShadows(
            blur: 3,
            anisotropy: 2,
            samples: 4,
            lightBleedReduction: 0.4,
          ),
        ),
      ).packed;
      expect(packed[18], closeTo(0.1, 1e-6));
      expect(packed[19], closeTo(0.3, 1e-6));
      expect(packed[20], closeTo(0.6, 1e-6));
      expect(packed[21], 2);
      expect(packed[22], 2);
      expect(packed[23], 3);
      expect(packed[24], closeTo(0.4, 1e-6));
      expect(packed[25], 4);
      expect(packed[26], closeTo(0.8, 1e-6));
      expect(packed[27], 16);
    },
  );

  test('a short split list fills only what it has', () {
    final packed = OrbisPipeline(
      shadows: OrbisShadows(cascades: 2, splits: [0.25]),
    ).packed;
    expect(packed.sublist(18, 21), [0.25, 0, 0]);
  });

  test('the view flags pack together', () {
    expect(OrbisPipeline().packed[15], 6, reason: 'culling and refraction');
    expect(
      OrbisPipeline(
        precise: true,
        culling: false,
        refraction: false,
      ).packed[15],
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

  test('a handheld is 1280 by 800, and that is not 16:9', () {
    const deck = OrbisDisplay.handheld;
    expect(deck.width, 1280);
    expect(deck.height, 800);
    expect(deck.pixels, 1024000);
    expect(deck.aspect, closeTo(1.6, 1e-9), reason: '16:10, not 16:9');
    expect(
      deck.aspect,
      isNot(closeTo(16 / 9, 1e-3)),
      reason: 'a camera framed for 16:9 is stretched or cropped here',
    );
  });

  test('a small panel gets a shadow map matched to it', () {
    // A shadow map is only as useful as the screen pixels it is stretched
    // over, so the map a 1440p frame needs is resolution a Deck cannot show.
    final named = OrbisPipeline.at(OrbisDetail.high);
    final deck = OrbisPipeline.forDisplay(
      const OrbisDisplay(width: 1280, height: 800, detail: OrbisDetail.high),
    );
    expect(named.shadows.mapSize, 2048);
    expect(deck.shadows.mapSize, 1024);
    expect(deck.shadows.cascades, named.shadows.cascades - 1);
  });

  test('the map never falls below the lowest setting the engine has', () {
    // Low is already at 512, and halving it again would invent a rung.
    final deck = OrbisPipeline.forDisplay(
      const OrbisDisplay(width: 1280, height: 800, detail: OrbisDetail.low),
    );
    expect(deck.shadows.mapSize, 512);
    expect(deck.shadows.cascades, 1, reason: 'one cascade stays one');
  });

  test('the floor under a shrinking frame rises on a small panel', () {
    // Half scale at 1440p is still 1280 by 720 of real pixels; half scale at
    // 1280 by 800 is 640 by 400, which is soft rather than slightly soft.
    final deck = OrbisPipeline.forDisplay(
      const OrbisDisplay(width: 1280, height: 800, detail: OrbisDetail.low),
    );
    expect(deck.resolution.adaptive, isTrue);
    expect(deck.resolution.minScale, closeTo(0.7, 1e-9));
    expect(OrbisPipeline.at(OrbisDetail.low).resolution.minScale, 0.5);
  });

  test('multisampling comes off, since bandwidth is what it costs', () {
    for (final detail in [OrbisDetail.high, OrbisDetail.ultra]) {
      expect(OrbisPipeline.at(detail).samples, 4);
      expect(
        OrbisPipeline.forDisplay(
          OrbisDisplay(width: 1280, height: 800, detail: detail),
        ).samples,
        1,
        reason: '${detail.label} on a handheld',
      );
    }
  });

  test('a large display is left exactly as the named setting had it', () {
    // The profile is the display's half of the question only. A full-sized
    // screen settles nothing, so nothing is changed.
    for (final detail in OrbisDetail.values) {
      final named = OrbisPipeline.at(detail);
      final big = OrbisPipeline.forDisplay(
        OrbisDisplay(width: 2560, height: 1440, detail: detail),
      );
      expect(big.shadows.mapSize, named.shadows.mapSize);
      expect(big.shadows.cascades, named.shadows.cascades);
      expect(big.samples, named.samples);
      expect(big.resolution.minScale, named.resolution.minScale);
    }
  });

  test('nothing appears or disappears on a handheld', () {
    // The same promise the four named settings make: a scene authored once is
    // the same scene here, drawn with smaller numbers.
    for (final detail in OrbisDetail.values) {
      final deck = OrbisPipeline.forDisplay(
        OrbisDisplay(width: 1280, height: 800, detail: detail),
      );
      expect(deck.shadows.enabled, isTrue);
      expect(deck.culling, isTrue);
      expect(deck.refraction, isTrue);
      expect(deck.packed, hasLength(OrbisPipeline.stride));
    }
  });
}
