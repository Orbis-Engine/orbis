import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';

void main() {
  group('motion blur', () {
    test('is off unless a graph asks for it', () {
      // Nothing about a scene with no graph mentions it, so the frame a host
      // has always drawn is the frame it still draws.
      expect(OrbisRenderGraph.standard().passes.map((p) => p.effect), [null]);
    });

    test('its graph is the world into a target and the blur onto the screen',
        () {
      final graph = const OrbisMotionBlur().graph();
      expect(graph.problems, isEmpty);
      final order = graph.schedule;
      expect(order.map((p) => p.name), ['world', 'motion blur']);
      expect(order.last.effect, OrbisEffect.motionBlur);
      expect(order.last.into, isNull, reason: 'the blur draws the frame');
      expect(order.last.reads, ['frame']);
    });

    test('its four dials cross in the order the renderer reads them', () {
      final packed = const OrbisMotionBlur(
        shutter: 1 / 30,
        maxPixels: 32,
        objects: false,
        frameRate: 50,
      ).graph().packedPasses;
      final at = OrbisRenderGraph.passStride;
      expect(packed[at + 8], closeTo(1 / 30, 1e-6), reason: 'shutter');
      expect(packed[at + 9], 32, reason: 'the clamp in pixels');
      expect(packed[at + 10], -1, reason: 'camera only');
      expect(packed[at + 11], 50, reason: 'frame rate');
      expect(packed[at + 12], OrbisEffect.motionBlur.index);
    });

    test('a shutter left unset follows the camera, and says so with nought',
        () {
      const blur = OrbisMotionBlur();
      expect(blur.dials.first, 0);
      expect(blur.dials[2], 1, reason: 'objects blur by default');
      // A 1/125 s shutter at sixty frames a second records a little under
      // half of each frame's travel.
      expect(blur.openFor(1 / 125), closeTo(0.48, 1e-9));
      expect(const OrbisMotionBlur(shutter: 1 / 1000).openFor(1 / 30),
          closeTo(0.06, 1e-9));
    });

    test('a target it reads has to keep its depth', () {
      final graph = OrbisRenderGraph(
        targets: const [OrbisTarget(name: 'flat', depth: false)],
        passes: [
          const OrbisPass(name: 'world', into: 'flat'),
          const OrbisMotionBlur().pass(reads: 'flat'),
        ],
      );
      expect(graph.problems.map((p) => p.what).join(' '), contains('depth'));
    });

    test('the renderer numbers the effect the way Dart does', () {
      // The effect crosses as its index, and the renderer switches on a
      // constant of its own. Appended rather than inserted, so every effect
      // before it keeps its number — and checked, because an index that
      // drifts runs a different shader rather than failing.
      final native = _read(
        'darwin/orbis_filament/Sources/orbis_filament_native/OrbisRenderer.mm',
      );
      final found = RegExp(
        r'constexpr int kEffectMotionBlur\s*=\s*(\d+);',
      ).firstMatch(native);
      expect(found, isNotNull);
      expect(int.parse(found!.group(1)!), OrbisEffect.motionBlur.index);
    });
  });
}

String _read(String withinPackage) {
  for (final root in ['.', 'packages/orbis_filament']) {
    final file = File('$root/$withinPackage');
    if (file.existsSync()) return file.readAsStringSync();
  }
  fail('cannot find $withinPackage from ${Directory.current.path}');
}
