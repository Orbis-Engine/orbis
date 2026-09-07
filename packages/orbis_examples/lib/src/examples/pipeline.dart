import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// How much of the frame's work actually happens.
///
/// One pipeline, not a choice of them. Every frame goes the same way — shadow
/// maps, depth, opaque, sky, see-through, then the image work — and what these
/// controls change is how much of each step there is. The four named settings
/// are settings of the same dials, which is the point: nothing appears or
/// disappears between them, so a scene is authored once and checked once.
///
/// The pillars are here to be shadowed. Cascades and map size are the two
/// settings that show most, and the way to see them is to look at the shadow
/// edge near the camera and then at the same edge far away.
class PipelineExample extends Example {
  PipelineExample() {
    // So the four settings can be compared from outside, one frame each,
    // without anybody having to click through them.
    final wanted = Platform.environment['ORBIS_DETAIL'];
    if (wanted != null) {
      for (final one in OrbisDetail.values) {
        if (one.name == wanted.toLowerCase()) _retier(one);
      }
    }
  }

  @override
  String get name => 'Pipeline';

  @override
  String get blurb =>
      'Shadows, cascades, multisampling and render scale — the four named '
      'settings, and every dial behind them.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 22, pitch: 0.12, yaw: 0.55, height: 1.5);

  OrbisDetail detail = OrbisDetail.medium;
  OrbisPipeline pipeline = OrbisPipeline.at(OrbisDetail.medium);

  void _retier(OrbisDetail chosen) {
    detail = chosen;
    pipeline = OrbisPipeline.at(chosen);
  }

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final objects = <OrbisObject>[
      OrbisObject(
        key: 1,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0, -1.5, 0))
          ..multiply(Matrix4.diagonal3(Vector3(200, 0.05, 200))),
        colour: linearOf(const Color(0xFF57606B)),
        castShadows: false,
      ),
    ];

    // A colonnade going away from the camera, so one shadow edge is a metre
    // off and the next is fifty. That distance is what cascades are for, and
    // it is the only way to see what they do.
    for (var i = 0; i < 14; i++) {
      final away = i * 4.0 - 6;
      for (final side in [-1.0, 1.0]) {
        objects.add(
          OrbisObject(
            key: 100 + i * 2 + (side > 0 ? 1 : 0),
            transform: Matrix4.identity()
              ..setTranslation(Vector3(side * 3.2, 0.6, away))
              ..multiply(Matrix4.diagonal3(Vector3(0.45, 2.1, 0.45))),
            colour: linearOf(const Color(0xFFD5CFC4)),
          ),
        );
      }
    }

    // Something with a fine edge close to the camera, because multisampling
    // shows on a thin diagonal and nowhere else.
    for (var i = 0; i < 5; i++) {
      objects.add(
        OrbisObject(
          key: 300 + i,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(-1.6 + i * 0.8, -0.4, 4))
            ..multiply(Matrix4.rotationZ(0.3 + i * 0.12))
            ..multiply(Matrix4.diagonal3(Vector3(0.06, 1.6, 0.06))),
          colour: linearOf(const Color(0xFFE0B252)),
        ),
      );
    }

    return OrbisScene(
      objects: objects,
      camera: camera,
      pipeline: pipeline,
      lights: [
        OrbisLight(
          key: 900,
          kind: OrbisLightKind.directional,
          // Low and across, so the shadows are long and the far ones are
          // where the resolution actually runs out.
          direction: Vector3(-0.55, -0.42, -0.72)..normalize(),
          intensity: 95000,
          sourceRadius: 0.6,
        ),
      ],
      sky: OrbisSky(colour: Vector3(0.24, 0.33, 0.46), ambient: 22000),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    final shadows = pipeline.shadows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Choice(
          label: 'Detail',
          options: [for (final one in OrbisDetail.values) one.label],
          selected: detail.label,
          onSelect: (label) {
            _retier(OrbisDetail.values.firstWhere((one) => one.label == label));
            changed();
          },
        ),
        Toggle(
          label: 'Shadows',
          value: shadows.enabled,
          onChanged: (value) {
            shadows.enabled = value;
            changed();
          },
        ),
        if (shadows.enabled) ...[
          Choice(
            label: 'Edge',
            options: [for (final one in OrbisShadowKind.values) one.label],
            selected: shadows.kind.label,
            onSelect: (label) {
              shadows.kind = OrbisShadowKind.values.firstWhere(
                (one) => one.label == label,
              );
              changed();
            },
          ),
          Setting(
            label: 'Map size',
            value: math.log(shadows.mapSize / 256) / math.ln2,
            min: 0,
            max: 4,
            decimals: 0,
            onChanged: (value) {
              shadows.mapSize = 256 * math.pow(2, value.round()).toInt();
              changed();
            },
          ),
          Setting(
            label: 'Cascades',
            value: shadows.cascades.toDouble(),
            min: 1,
            max: 4,
            decimals: 0,
            onChanged: (value) {
              shadows.cascades = value.round();
              changed();
            },
          ),
          Setting(
            label: 'Distance',
            value: shadows.distance,
            min: 0,
            max: 200,
            decimals: 0,
            unit: 'm',
            onChanged: (value) {
              shadows.distance = value;
              changed();
            },
          ),
          Setting(
            label: 'Spread',
            value: shadows.lambda,
            min: 0,
            max: 1,
            decimals: 2,
            onChanged: (value) {
              shadows.lambda = value;
              changed();
            },
          ),
          Toggle(
            label: 'Contact shadows',
            value: shadows.contact,
            onChanged: (value) {
              shadows.contact = value;
              changed();
            },
          ),
          Toggle(
            label: 'Steady edges',
            value: shadows.stable,
            onChanged: (value) {
              shadows.stable = value;
              changed();
            },
          ),
        ],
        Setting(
          label: 'Multisampling',
          value: math.log(pipeline.samples) / math.ln2,
          min: 0,
          max: 3,
          decimals: 0,
          onChanged: (value) {
            pipeline.samples = math.pow(2, value.round()).toInt();
            changed();
          },
        ),
        Setting(
          label: 'Render scale',
          value: pipeline.resolution.scale,
          min: 0.35,
          max: 1,
          decimals: 2,
          onChanged: (value) {
            pipeline.resolution.scale = value;
            pipeline.resolution.adaptive = false;
            changed();
          },
        ),
        Toggle(
          label: 'Let it shrink to keep up',
          value: pipeline.resolution.adaptive,
          onChanged: (value) {
            pipeline.resolution.adaptive = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// One pipeline. The four named settings are settings of its dials, not
// different pipelines — nothing appears or disappears between them.
final pipeline = OrbisPipeline.at(OrbisDetail.high);

// Or every dial by hand.
final mine = OrbisPipeline(
  shadows: OrbisShadows(
    kind: OrbisShadowKind.soft,
    mapSize: 2048,
    // The single most effective shadow setting there is: one map over a
    // hundred metres puts a centimetre in each pixel; four cascades over the
    // same hundred metres puts a millimetre in the first.
    cascades: 3,
    distance: 80,
    contact: true,
  ),
  // Runs while the frame is drawn, unlike the anti-aliasing in post, which
  // runs on the finished image. Sharper, and costs bandwidth on everything.
  samples: 4,
  // A frame that arrives on time slightly soft beats one that arrives late
  // sharp.
  resolution: OrbisResolution(adaptive: true, minScale: 0.6),
);

OrbisScene(objects: objects, camera: camera, pipeline: pipeline);
''';
}
