import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';

void main() {
  group('the bounce pass', () {
    OrbisRenderGraph graphWith(List<double>? dials) => OrbisRenderGraph(
      targets: const [OrbisTarget(name: 'frame')],
      passes: [
        const OrbisPass(name: 'world', into: 'frame'),
        OrbisPass(
          name: 'bounce',
          kind: OrbisPassKind.effect,
          effect: OrbisEffect.bounce,
          reads: const ['frame'],
          plane: dials,
        ),
      ],
    );

    test('it reads one target and gets both the picture and the depth', () {
      // The colour and the depth of a target are two halves of one thing, so
      // a graph names it once. Making a host list it twice is how the two end
      // up naming different targets.
      final graph = graphWith(null);
      expect(graph.problems, isEmpty);
      final pass = graph.schedule.last;
      expect(pass.reads, ['frame']);
      expect(pass.effect, OrbisEffect.bounce);
    });

    test('a target it reads has to keep its depth', () {
      // Colour alone is a target the march cannot use: without depth there is
      // no telling what is in front of what, and the pass would gather light
      // from surfaces on the far side of a wall.
      final graph = OrbisRenderGraph(
        targets: const [OrbisTarget(name: 'flat', depth: false)],
        passes: [
          const OrbisPass(name: 'world', into: 'flat'),
          const OrbisPass(
            name: 'bounce',
            kind: OrbisPassKind.effect,
            effect: OrbisEffect.bounce,
            reads: ['flat'],
          ),
        ],
      );
      expect(
        graph.problems.map((p) => p.what).join(' '),
        contains('depth'),
        reason: 'a bounce over a target with no depth should be reported',
      );
    });

    test('its four dials cross in the order the renderer reads them', () {
      final packed = graphWith([3, 6, 0.4, 8]).packedPasses;
      final at = OrbisRenderGraph.passStride;
      expect(packed[at + 8], 3, reason: 'reach');
      expect(packed[at + 9], 6, reason: 'strength');
      expect(packed[at + 10], closeTo(0.4, 1e-6), reason: 'thickness');
      expect(packed[at + 11], 8, reason: 'directions');
      expect(packed[at + 12], OrbisEffect.bounce.index);
    });
  });

  _effectTests();
  group('the default graph', () {
    test('is the frame as it was before there was a graph', () {
      final graph = OrbisRenderGraph.standard();

      expect(graph.isRunnable, isTrue);
      expect(graph.schedule.map((pass) => pass.name), ['scene']);
      expect(graph.schedule.single.into, isNull);
    });

    test('an empty graph is not a broken one', () {
      // A host that never mentions a graph is not a host with a wrong graph.
      const graph = OrbisRenderGraph();
      expect(graph.problems, isEmpty);
      expect(graph.schedule, isEmpty);
    });
  });

  group('scheduling', () {
    final reflection = OrbisRenderGraph(
      targets: const [OrbisTarget(name: 'mirror', scale: 0.5)],
      passes: const [
        // Declared out of order on purpose: the frame first, then the thing
        // it needs. An order kept by hand would draw the mirror empty.
        OrbisPass(name: 'frame', reads: ['mirror']),
        OrbisPass(
          name: 'water',
          kind: OrbisPassKind.reflection,
          into: 'mirror',
          plane: [0, 1, 0, 0],
        ),
      ],
    );

    test('a target is written before it is read', () {
      expect(reflection.isRunnable, isTrue);
      expect(reflection.schedule.map((pass) => pass.name), ['water', 'frame']);
    });

    test('the frame is last whatever else there is', () {
      final graph = reflection
          .withTarget(const OrbisTarget(name: 'monitor'))
          .with_(const OrbisPass(name: 'prepass', into: 'monitor'));

      expect(graph.schedule.last.name, 'frame');
      expect(graph.schedule.map((pass) => pass.name), contains('prepass'));
    });

    test('passes that do not depend on each other keep their order', () {
      // Two independent passes have no correct order, so the one somebody
      // wrote down is the one a capture should show.
      final graph = OrbisRenderGraph(
        targets: const [
          OrbisTarget(name: 'a'),
          OrbisTarget(name: 'b'),
        ],
        passes: const [
          OrbisPass(name: 'second', into: 'b'),
          OrbisPass(name: 'first', into: 'a'),
          OrbisPass(name: 'frame', reads: ['a', 'b']),
        ],
      );

      expect(graph.schedule.map((pass) => pass.name), [
        'second',
        'first',
        'frame',
      ]);
    });

    test('a chain of three is ordered end to end', () {
      final graph = OrbisRenderGraph(
        targets: const [
          OrbisTarget(name: 'one'),
          OrbisTarget(name: 'two'),
        ],
        passes: const [
          OrbisPass(name: 'frame', reads: ['two']),
          OrbisPass(name: 'middle', into: 'two', reads: ['one']),
          OrbisPass(name: 'first', into: 'one'),
        ],
      );

      expect(graph.schedule.map((pass) => pass.name), [
        'first',
        'middle',
        'frame',
      ]);
    });

    test('a pass switched off is skipped, not scheduled around', () {
      final graph = OrbisRenderGraph(
        targets: const [OrbisTarget(name: 'mirror')],
        passes: const [
          OrbisPass(
            name: 'water',
            into: 'mirror',
            enabled: false,
            kind: OrbisPassKind.reflection,
            plane: [0, 1, 0, 0],
          ),
          OrbisPass(name: 'frame', reads: ['mirror']),
        ],
      );

      // The frame still draws. Whatever the mirror held last is what it
      // samples, which is the honest behaviour for a pass somebody turned off.
      expect(graph.schedule.map((pass) => pass.name), ['frame']);
      expect(graph.problems, isEmpty);
    });
  });

  group('what a graph gets wrong', () {
    test('two passes cannot both draw the frame', () {
      const graph = OrbisRenderGraph(
        passes: [
          OrbisPass(name: 'one'),
          OrbisPass(name: 'two'),
        ],
      );

      expect(
        graph.problems.map((problem) => problem.what).join(),
        contains('overwrite'),
      );
      // Nothing runs: a graph the renderer cannot make sense of should draw
      // what it drew last rather than half of a new idea.
      expect(graph.schedule, isEmpty);
    });

    test('a graph with no frame pass says so', () {
      const graph = OrbisRenderGraph(
        targets: [OrbisTarget(name: 'a')],
        passes: [OrbisPass(name: 'only', into: 'a')],
      );
      expect(
        graph.problems.map((problem) => problem.what).join(),
        contains('no pass draws the frame'),
      );
    });

    test('a target nobody declared is named, not guessed at', () {
      const graph = OrbisRenderGraph(
        passes: [
          OrbisPass(name: 'frame', reads: ['nowhere']),
        ],
      );

      expect(graph.problems.single.pass, 'frame');
      expect(graph.problems.single.what, contains('nowhere'));
    });

    test('two passes cannot write the same target', () {
      const graph = OrbisRenderGraph(
        targets: [OrbisTarget(name: 'a')],
        passes: [
          OrbisPass(name: 'one', into: 'a'),
          OrbisPass(name: 'two', into: 'a'),
          OrbisPass(name: 'frame', reads: ['a']),
        ],
      );
      expect(
        graph.problems.map((problem) => problem.what).join(),
        contains('already writes'),
      );
    });

    test('a pass cannot read what it writes', () {
      const graph = OrbisRenderGraph(
        targets: [OrbisTarget(name: 'a')],
        passes: [
          OrbisPass(name: 'itself', into: 'a', reads: ['a']),
          OrbisPass(name: 'frame'),
        ],
      );
      expect(
        graph.problems.map((problem) => problem.what).join(),
        contains('reads the target it writes'),
      );
    });

    test('two passes waiting on each other are named', () {
      const graph = OrbisRenderGraph(
        targets: [
          OrbisTarget(name: 'a'),
          OrbisTarget(name: 'b'),
        ],
        passes: [
          OrbisPass(name: 'one', into: 'a', reads: ['b']),
          OrbisPass(name: 'two', into: 'b', reads: ['a']),
          OrbisPass(name: 'frame'),
        ],
      );

      final waiting = graph.problems
          .where((problem) => problem.what.contains('waits on'))
          .map((problem) => problem.pass);
      expect(waiting, containsAll(['one', 'two']));
    });

    test('a reflection with no plane is not a reflection', () {
      const graph = OrbisRenderGraph(
        targets: [OrbisTarget(name: 'mirror')],
        passes: [
          OrbisPass(
            name: 'water',
            kind: OrbisPassKind.reflection,
            into: 'mirror',
          ),
          OrbisPass(name: 'frame', reads: ['mirror']),
        ],
      );
      expect(graph.problems.single.what, contains('no plane'));
    });

    test('a graph that has run away is refused rather than allocated', () {
      final graph = OrbisRenderGraph(
        passes: [
          for (var i = 0; i < OrbisRenderGraph.maxPasses + 1; i++)
            OrbisPass(name: 'pass$i'),
        ],
      );
      expect(graph.problems.first.what, contains('more than'));
    });

    test('a target nothing reads is worth saying, and is not an error', () {
      const graph = OrbisRenderGraph(
        targets: [OrbisTarget(name: 'thumbnail')],
        passes: [
          OrbisPass(name: 'shot', into: 'thumbnail'),
          OrbisPass(name: 'frame'),
        ],
      );

      expect(graph.problems, isEmpty);
      expect(graph.unreadTargets, ['thumbnail']);
    });
  });

  group('on the wire', () {
    final graph = OrbisRenderGraph(
      targets: const [
        OrbisTarget(name: 'mirror', scale: 0.5, colour: true),
        OrbisTarget(name: 'shadowless', depth: true, colour: false),
      ],
      passes: const [
        OrbisPass(name: 'frame', reads: ['mirror', 'shadowless'], layers: 0x0F),
        OrbisPass(name: 'prepass', into: 'shadowless'),
        OrbisPass(
          name: 'water',
          kind: OrbisPassKind.reflection,
          into: 'mirror',
          plane: [0, 1, 0, -2],
        ),
      ],
    );

    test('passes cross in the order they run', () {
      final packed = graph.packedPasses;
      expect(packed.length, 3 * OrbisRenderGraph.passStride);

      // Targets travel as indices. The names are for people; matching strings
      // sixty times a second is matching the same strings sixty times.
      const stride = OrbisRenderGraph.passStride;
      expect(packed[0 * stride + 1], 1); // prepass writes target 1
      expect(packed[1 * stride + 1], 0); // water writes target 0
      expect(packed[2 * stride + 1], -1); // the frame writes no target
    });

    test('a pass carries its reads, its layers and its plane', () {
      final packed = graph.packedPasses;
      const stride = OrbisRenderGraph.passStride;
      final frame = 2 * stride;

      expect(packed[frame + 2], 0x0F);
      expect(packed[frame + 4], 0); // reads mirror
      expect(packed[frame + 5], 1); // and depth
      expect(packed[frame + 6], -1); // and nothing else

      final water = 1 * stride;
      expect(packed[water + 8 + 1], 1); // the plane's normal
      expect(packed[water + 8 + 3], -2); // and its distance
    });

    test('targets carry their size and what they keep', () {
      final packed = graph.packedTargets;
      const stride = OrbisRenderGraph.targetStride;

      expect(packed.length, 2 * stride);
      expect(packed[0 * stride + 2], 0.5);
      expect(packed[1 * stride + 3], 1); // depth keeps depth
      expect(packed[1 * stride + 4], 0); // and no colour
    });
  });

  group('a capture', () {
    test('says what ran and what it cost', () {
      final capture = OrbisFrameCapture.from(
        Float32List.fromList([0.4, 120, 2.6, 4300, 0.2, 8]),
        ['prepass', 'scene', 'outline'],
      );

      expect(capture.passes.map((pass) => pass.name), [
        'prepass',
        'scene',
        'outline',
      ]);
      expect(capture.milliseconds, closeTo(3.2, 0.0001));
      expect(capture.draws, 4428);
      expect(capture.slowest!.name, 'scene');
    });

    test(
      'a frame the renderer has not reported on yet is empty, not wrong',
      () {
        final capture = OrbisFrameCapture.from(Float32List(0), ['scene']);
        expect(capture.passes, isEmpty);
        expect(capture.slowest, isNull);
        expect(capture.milliseconds, 0);
      },
    );
  });
}

void _effectTests() {
  group('effect passes on the wire', () {
    test('an effect names itself; every other kind says none', () {
      final graph = OrbisRenderGraph(
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

      final packed = graph.packedPasses;
      const stride = OrbisRenderGraph.passStride;

      // A scene pass has no effect, and must say so rather than leaving the
      // slot at zero — zero is a real effect.
      expect(packed[12], -1);
      expect(packed[stride + 12], OrbisEffect.sharpen.index);
      expect(packed[stride], OrbisPassKind.effect.index);
    });

    test('an effect reads the target the scene wrote', () {
      final graph = OrbisRenderGraph(
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
      const stride = OrbisRenderGraph.passStride;
      // First read is target 0; the rest are empty.
      expect(graph.packedPasses[stride + 4], 0);
      expect(graph.packedPasses[stride + 5], -1);
    });

    test('the effect survives a copyWith', () {
      const pass = OrbisPass(
        name: 'sharpen',
        kind: OrbisPassKind.effect,
        effect: OrbisEffect.sharpen,
      );
      expect(pass.copyWith(name: 'other').effect, OrbisEffect.sharpen);
    });
  });
}
