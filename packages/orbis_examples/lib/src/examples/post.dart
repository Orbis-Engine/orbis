import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// What happens to the image after the scene is drawn.
///
/// A renderer works in light — values far above one, because the sun is
/// thousands of times brighter than a lamp and both are in the same frame —
/// and a screen takes numbers between nought and one. Everything here is about
/// that journey: what glows, what is in focus, what colour the whole thing is,
/// and how the jagged edges are dealt with.
///
/// It is the difference between a scene that looks like data and one that
/// looks like it was photographed.
class PostExample extends Example {
  PostExample();

  @override
  String get name => 'Post-processing';

  @override
  String get blurb =>
      'Bloom, depth of field, occlusion, grading and anti-aliasing, over a '
      'scene bright enough to show each of them.';

  @override
  ViewPoint get viewpoint => const ViewPoint(distance: 16, pitch: 0.22);

  final OrbisPostProcess post = OrbisPostProcess(
    bloom: OrbisBloom(enabled: true, strength: 0.25),
    occlusion: OrbisOcclusion(enabled: true),
    grading: OrbisGrading(enabled: true, contrast: 1.05),
  );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final objects = <OrbisObject>[
      // A floor to catch the contact shadows, which is what occlusion is for.
      OrbisObject(
        key: 1,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0, -1.05, 0))
          ..multiply(Matrix4.diagonal3(Vector3(14, 0.05, 14))),
        colour: linearOf(const Color(0xFF3B424C)),
      ),
    ];

    // A row of boxes going away from the camera, so depth of field has
    // something at several distances to be sharp and blurred against.
    for (var i = 0; i < 7; i++) {
      final away = (i - 3) * 3.0;
      objects.add(
        OrbisObject(
          key: 10 + i,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(math.sin(i * 1.1) * 2.4, 0, away))
            ..multiply(Matrix4.diagonal3(Vector3(0.9, 1.4, 0.9))),
          colour: linearOf(
            const [Color(0xFFD9634F), Color(0xFF7FB069), Color(0xFF5B8DD9)][i %
                3],
          ),
        ),
      );
    }

    // And something far brighter than white, which is the only thing that
    // makes bloom mean anything: a lamp glows because there is nowhere
    // brighter for it to go.
    objects.add(
      OrbisObject(
        key: 100,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(3.2, 1.6, -2))
          ..multiply(Matrix4.diagonal3(Vector3(0.5, 0.5, 0.5))),
        colour: Vector3(24, 18, 9),
      ),
    );

    return OrbisScene(
      objects: objects,
      camera: camera,
      post: post,
      lights: [
        OrbisLight(
          key: 900,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.4, -1, -0.35),
          intensity: 68000,
        ),
        OrbisLight(
          key: 901,
          kind: OrbisLightKind.point,
          position: Vector3(3.2, 1.6, -2),
          intensity: 9000,
          colour: Vector3(1, 0.78, 0.4),
          castShadows: false,
        ),
      ],
      sky: OrbisSky(colour: Vector3(0.10, 0.13, 0.19), ambient: 12000),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Toggle(
          label: 'Post-processing',
          value: post.enabled,
          onChanged: (value) {
            post.enabled = value;
            changed();
          },
        ),
        Toggle(
          label: 'Bloom',
          value: post.bloom.enabled,
          onChanged: (value) {
            post.bloom.enabled = value;
            changed();
          },
        ),
        if (post.bloom.enabled) ...[
          Setting(
            label: 'Strength',
            value: post.bloom.strength,
            min: 0,
            max: 1,
            onChanged: (value) {
              post.bloom.strength = value;
              changed();
            },
          ),
          Toggle(
            label: 'Lens flare',
            value: post.bloom.lensFlare,
            onChanged: (value) {
              post.bloom.lensFlare = value;
              changed();
            },
          ),
        ],
        Toggle(
          label: 'Depth of field',
          value: post.depthOfField.enabled,
          onChanged: (value) {
            post.depthOfField.enabled = value;
            changed();
          },
        ),
        if (post.depthOfField.enabled)
          Setting(
            label: 'Focus',
            value: post.depthOfField.focusDistance,
            min: 1,
            max: 40,
            decimals: 1,
            unit: 'm',
            onChanged: (value) {
              post.depthOfField.focusDistance = value;
              changed();
            },
          ),
        Toggle(
          label: 'Occlusion',
          value: post.occlusion.enabled,
          onChanged: (value) {
            post.occlusion.enabled = value;
            changed();
          },
        ),
        Toggle(
          label: 'Vignette',
          value: post.vignette.enabled,
          onChanged: (value) {
            post.vignette.enabled = value;
            changed();
          },
        ),
        Choice(
          label: 'Tone map',
          options: [for (final one in ToneMapping.values) one.label],
          selected: post.grading.toneMapping.label,
          onSelect: (label) {
            post.grading.toneMapping = ToneMapping.values.firstWhere(
              (one) => one.label == label,
            );
            changed();
          },
        ),
        Setting(
          label: 'Exposure',
          value: post.grading.exposure,
          min: -3,
          max: 3,
          decimals: 1,
          onChanged: (value) {
            post.grading.enabled = true;
            post.grading.exposure = value;
            changed();
          },
        ),
        Setting(
          label: 'Saturation',
          value: post.grading.saturation,
          min: 0,
          max: 2,
          onChanged: (value) {
            post.grading.enabled = true;
            post.grading.saturation = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// Everything after the scene is drawn, on the scene rather than the camera:
// a look belongs to the place, not to where somebody is standing in it.
OrbisScene(
  objects: objects,
  camera: camera,
  post: OrbisPostProcess(
    bloom: OrbisBloom(enabled: true, strength: 0.25, lensFlare: true),
    occlusion: OrbisOcclusion(enabled: true),
    depthOfField: OrbisDepthOfField(enabled: true, focusDistance: 12),
    grading: OrbisGrading(
      enabled: true,
      toneMapping: ToneMapping.aces,
      exposure: 0.4,
      saturation: 1.1,
    ),
  ),
);
''';
}
