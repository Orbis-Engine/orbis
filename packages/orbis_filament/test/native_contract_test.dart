import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';

/// The numbers three languages have to agree on, checked rather than trusted.
///
/// Every scene crosses the boundary as flat float arrays, and how wide a row
/// is exists in three places: the Dart that packs it, the Swift that checks
/// the message, and the C++ that reads it. They agree by hand, and the
/// comments on all three say so, which is not the same as anything noticing
/// when they stop.
///
/// What happens when they drift is worth spelling out, because it is not a
/// crash. Swift refuses the message, so the scene never reaches the renderer
/// and the view shows the error it got back — everything else still passes:
/// the packing tests, because Dart packs correctly; the frame smoke, because
/// the renderer still draws the last thing it was given. The failure is a
/// whole app that renders nothing, found by running it.
///
/// So this reads the native sources and compares the numbers. Coarse, but it
/// fails on the commit that causes it rather than on the first launch after.
void main() {
  final swift = _read(
    'darwin/orbis_filament/Sources/orbis_filament/OrbisFilamentPlugin.swift',
  );
  final native = _read(
    'darwin/orbis_filament/Sources/orbis_filament_native/OrbisRenderer.mm',
  );

  group('the strides the three sides share', () {
    // Dart's number, what Swift calls it, and what the renderer calls it —
    // null where that side has no say in it.
    const contract = <String, (int, String, String?)>{
      'a light': (OrbisLight.stride, 'lightStride', null),
      'a probe': (OrbisProbe.stride, 'probeStride', null),
      'a field': (OrbisField.stride, 'fieldStride', null),
      'an environment': (OrbisEnvironment.stride, 'environmentStride', null),
      'a graph pass': (OrbisRenderGraph.passStride, 'passStride', null),
      'a graph target': (OrbisRenderGraph.targetStride, 'targetStride', null),
      'a material': (OrbisMaterial.stride, 'materialStride', 'kMaterialParams'),
      "a material's maps": (
        OrbisMaterial.mapCount,
        'materialMaps',
        'kMaterialMaps',
      ),
      'a video': (OrbisVideo.stride, 'videoStride', 'kVideoParams'),
      'fog': (OrbisFog.stride, 'fogStride', null),
      'precipitation': (OrbisPrecipitation.stride, 'precipitationStride', null),
      'the sky': (OrbisSky.stride, 'skyStride', null),
    };

    contract.forEach((what, agreed) {
      final (dart, swiftName, nativeName) = agreed;

      test('$what is $dart wide everywhere', () {
        expect(
          _swiftValue(swift, swiftName),
          dart,
          reason:
              'Dart packs $dart floats for $what and the plugin checks '
              'for a different number, so it will refuse every scene',
        );
        if (nativeName != null) {
          expect(
            _nativeValue(native, nativeName),
            dart,
            reason:
                'Dart packs $dart floats for $what and the renderer reads '
                'a different number, so it will read the wrong offsets',
          );
        }
      });
    });
  });

  _screenEffects(swift);
}

/// God rays and distortion keep their numbers in their own plain C++ header
/// rather than in the renderer, so they are checked against that.
void _screenEffects(String swift) {
  final screen = _read(
    'darwin/orbis_filament/Sources/orbis_filament_native/ScreenEffects.h',
  );

  group('god rays and distortion', () {
    test('agree on how wide a row is', () {
      expect(_swiftValue(swift, 'godRayStride'), OrbisGodRays.stride);
      expect(_swiftValue(swift, 'distortionStride'), OrbisDistortion.stride);
      expect(_nativeValue(screen, 'kGodRayStride'), OrbisGodRays.stride);
      expect(_nativeValue(screen, 'kDistortionStride'), OrbisDistortion.stride);
      expect(
        _nativeValue(screen, 'kDistortionCapacity'),
        OrbisDistortion.capacity,
      );
    });

    test('agree on what the numbers mean', () {
      // An effect index out of step runs the wrong shader over the frame;
      // a kind out of step bends it the wrong way.
      expect(_nativeInt(screen, 'kEffectGodRays'), OrbisEffect.godRays.index);
      expect(
        _nativeInt(screen, 'kEffectDistortion'),
        OrbisEffect.distortion.index,
      );
      expect(
        _nativeInt(screen, 'kDistortionShockwave'),
        OrbisDistortionKind.shockwave.index,
      );
      expect(
        _nativeInt(screen, 'kDistortionHaze'),
        OrbisDistortionKind.haze.index,
      );
      expect(
        _nativeInt(screen, 'kDistortionLens'),
        OrbisDistortionKind.lens.index,
      );
    });
  });
}

/// `constexpr int kName = 6;`
int _nativeInt(String source, String name) {
  final found = RegExp(
    r'constexpr int ' + name + r'\s*=\s*(\d+)',
  ).firstMatch(source);
  expect(found, isNotNull, reason: 'the renderer no longer declares $name');
  return int.parse(found!.group(1)!);
}

/// `private static let name = 12`, whatever the access level.
int _swiftValue(String source, String name) {
  final found = RegExp(
    r'static let ' + name + r'\s*=\s*(\d+)',
  ).firstMatch(source);
  expect(found, isNotNull, reason: 'the plugin no longer declares $name');
  return int.parse(found!.group(1)!);
}

/// `constexpr size_t kName = 12;`
int _nativeValue(String source, String name) {
  final found = RegExp(
    r'constexpr size_t ' + name + r'\s*=\s*(\d+)',
  ).firstMatch(source);
  expect(found, isNotNull, reason: 'the renderer no longer declares $name');
  return int.parse(found!.group(1)!);
}

/// The native source, wherever the test was run from.
String _read(String withinPackage) {
  for (final root in ['.', 'packages/orbis_filament']) {
    final file = File('$root/$withinPackage');
    if (file.existsSync()) return file.readAsStringSync();
  }
  // Deliberately not a skip. A guard that quietly stands down when it cannot
  // find what it guards is worse than no guard, because it reports green.
  fail(
    'cannot find $withinPackage from ${Directory.current.path} — this test '
    'reads the native sources and has to be run where it can see them',
  );
}
