import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  OrbisScene sceneWith({
    OrbisGodRays? godRays,
    List<OrbisDistortion>? distortions,
    OrbisRenderGraph? graph,
    OrbisSky? sky,
    bool sun = true,
  }) => OrbisScene(
    objects: const [],
    camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
    lights: [
      if (sun)
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          intensity: 1000,
          direction: Vector3(0, -0.2, -1)..normalize(),
          colour: Vector3(1, 0.8, 0.6),
        ),
    ],
    godRays: godRays,
    distortions: distortions,
    graph: graph,
    sky: sky,
  );

  Float32List raysOf(OrbisScene scene) =>
      scene.toMessage(1)['godRayParams']! as Float32List;

  group('god rays', () {
    test('are off by default, and cost nothing when off', () {
      // No extra pass and no texture: the frame drawn is the frame a scene
      // drew before god rays existed.
      final scene = sceneWith();
      expect(scene.godRays.isOn, isFalse);
      expect(scene.drawnGraph.isStandard, isTrue);
      expect(scene.passNames, ['scene']);
      expect(raysOf(scene), everyElement(0));
    });

    test('a strength of nought is off, whatever else is set', () {
      final scene = sceneWith(
        godRays: const OrbisGodRays(strength: 0, samples: 128),
      );
      expect(scene.passNames, ['scene']);
      expect(raysOf(scene), everyElement(0));
    });

    test('turned on, the world goes into a texture and the shafts onto '
        'the screen', () {
      final scene = sceneWith(godRays: const OrbisGodRays(strength: 0.8));
      final graph = scene.drawnGraph;
      expect(graph.problems, isEmpty);
      expect(scene.passNames, ['scene', 'god rays']);
      expect(graph.schedule.first.into, OrbisRenderGraph.screenTarget);
      final last = graph.schedule.last;
      expect(last.effect, OrbisEffect.godRays);
      expect(last.into, isNull);
      expect(last.reads, [OrbisRenderGraph.screenTarget]);
    });

    test('with no directional light there is nothing to scatter', () {
      final scene = sceneWith(
        godRays: const OrbisGodRays(strength: 1),
        sun: false,
      );
      expect(scene.passNames, ['scene']);
      expect(raysOf(scene), everyElement(0));
    });

    test("come from the scene's own light, in its colour", () {
      final packed = raysOf(
        sceneWith(godRays: const OrbisGodRays(strength: 0.5, samples: 32)),
      );
      expect(packed[0], closeTo(0.5, 1e-6));
      expect(packed[3], 32);
      // The light's colour, because none was asked for.
      expect(packed.sublist(4, 7), [
        closeTo(1, 1e-6),
        closeTo(0.8, 1e-6),
        closeTo(0.6, 1e-6),
      ]);
      // Towards the light, which is the way it does not travel.
      final toward = Vector3(packed[7], packed[8], packed[9]);
      expect(toward.length, closeTo(1, 1e-5));
      expect(toward.y, greaterThan(0));
      expect(toward.z, greaterThan(0));
      expect(packed[11], 1);
    });

    test('a tint of their own wins over the light', () {
      final packed = raysOf(
        sceneWith(
          godRays: OrbisGodRays(strength: 1, tint: Vector3(0.2, 0.4, 1)),
        ),
      );
      expect(packed.sublist(4, 7), [
        closeTo(0.2, 1e-6),
        closeTo(0.4, 1e-6),
        closeTo(1, 1e-6),
      ]);
    });

    test('cloud only thins them when the sky that carries it is drawn', () {
      final cloudy = OrbisSky(clouds: OrbisClouds.cumulus(cover: 0.7));
      expect(
        raysOf(sceneWith(godRays: const OrbisGodRays(strength: 1), sky: cloudy))[10],
        closeTo(0.7, 1e-6),
      );
      final hidden = OrbisSky(
        drawn: false,
        clouds: OrbisClouds.cumulus(cover: 0.7),
      );
      expect(
        raysOf(sceneWith(godRays: const OrbisGodRays(strength: 1), sky: hidden))[10],
        0,
      );
    });

    test("a host's own graph is left for the host to place them in", () {
      final own = OrbisRenderGraph(
        targets: const [OrbisTarget(name: 'frame')],
        passes: const [
          OrbisPass(name: 'world', into: 'frame'),
          OrbisPass(
            name: 'sharpen',
            kind: OrbisPassKind.effect,
            effect: OrbisEffect.sharpen,
            reads: ['frame'],
          ),
        ],
      );
      final scene = sceneWith(
        godRays: const OrbisGodRays(strength: 1),
        graph: own,
      );
      expect(scene.passNames, ['world', 'sharpen']);
    });

    test('a god-ray pass needs a target that kept its depth', () {
      final graph = OrbisRenderGraph(
        targets: const [OrbisTarget(name: 'flat', depth: false)],
        passes: const [
          OrbisPass(name: 'world', into: 'flat'),
          OrbisPass(
            name: 'rays',
            kind: OrbisPassKind.effect,
            effect: OrbisEffect.godRays,
            reads: ['flat'],
          ),
        ],
      );
      expect(graph.problems.map((one) => one.pass), contains('rays'));
    });
  });

  group('distortion', () {
    test('a wave that has run its course draws no pass', () {
      final done = OrbisDistortion.expanding(
        centre: Vector3.zero(),
        age: 3,
        lifetime: 2,
      );
      expect(done.isActive, isFalse);
      expect(sceneWith(distortions: [done]).passNames, ['scene']);
      expect(OrbisDistortion.packAll([done]), isEmpty);
    });

    test('a wave grows with the clock and weakens as it goes', () {
      final early = OrbisDistortion.expanding(
        centre: Vector3.zero(),
        age: 0.5,
        speed: 4,
        lifetime: 2,
        strength: 0.04,
      );
      final late = OrbisDistortion.expanding(
        centre: Vector3.zero(),
        age: 1.5,
        speed: 4,
        lifetime: 2,
        strength: 0.04,
      );
      expect(early.radius, closeTo(2, 1e-9));
      expect(late.radius, closeTo(6, 1e-9));
      expect(early.strength, closeTo(0.03, 1e-9));
      expect(late.strength, closeTo(0.01, 1e-9));
    });

    test('each kind packs into the slots the renderer reads', () {
      final packed = OrbisDistortion.packAll([
        OrbisDistortion.shockwave(
          centre: Vector3(1, 2, 3),
          radius: 4,
          thickness: 0.5,
          strength: 0.02,
          chromatic: 0.3,
        ),
        OrbisDistortion.haze(
          centre: Vector3(-1, 0, 2),
          halfSize: Vector3(0.5, 1, 0.5),
          scale: 0.2,
          speed: 2,
          seconds: 3,
        ),
        OrbisDistortion.lens(strength: -0.1),
      ]);
      const s = OrbisDistortion.stride;
      expect(packed.length, 3 * s);
      expect(packed.sublist(0, 8), [
        1,
        closeTo(0.02, 1e-6),
        closeTo(0.3, 1e-6),
        1,
        2,
        3,
        4,
        0.5,
      ]);
      expect(packed[s], 2);
      expect(packed.sublist(s + 6, s + 11), [0.5, 1, 0.5, closeTo(0.2, 1e-6), 6]);
      expect(packed[2 * s], 3);
      expect(packed[2 * s + 1], closeTo(-0.1, 1e-6));
    });

    test('no more than the renderer can draw are sent', () {
      final many = [
        for (var i = 0; i < 12; i++) OrbisDistortion.lens(strength: 0.01),
      ];
      expect(
        OrbisDistortion.packAll(many).length,
        OrbisDistortion.capacity * OrbisDistortion.stride,
      );
    });

    test('after god rays, it bends their picture by the depth of the world', () {
      // The god rays write a picture with no depth, so the distortion takes
      // its colour from that and its depth from the world, in that order.
      final scene = sceneWith(
        godRays: const OrbisGodRays(strength: 1),
        distortions: [OrbisDistortion.lens(strength: 0.1)],
      );
      final graph = scene.drawnGraph;
      expect(graph.problems, isEmpty);
      expect(scene.passNames, ['scene', 'god rays', 'distortion']);
      expect(graph.schedule[1].into, OrbisRenderGraph.raysTarget);
      expect(graph.schedule.last.reads, [
        OrbisRenderGraph.raysTarget,
        OrbisRenderGraph.screenTarget,
      ]);
    });
  });
}
