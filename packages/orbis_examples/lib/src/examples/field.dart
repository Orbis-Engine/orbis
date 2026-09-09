import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Light kept in the world instead of on the screen.
///
/// A screen-space bounce only knows what is in frame, so turning away from a
/// red wall takes its bounce with it. A field keeps the answer where the
/// camera cannot move it: probes standing in the room, each holding what light
/// reaches it from every direction, built up over many frames and read by
/// every surface near it.
///
/// The same room as the bounced-light example on purpose. What is worth
/// watching is not that the walls tint the boxes — the bounce does that too —
/// but that they go on tinting them, and that the tint is right for where a
/// surface *is* rather than for what happens to be in shot.
class FieldExample extends Example {
  FieldExample();

  @override
  String get name => 'Irradiance field';

  @override
  String get blurb =>
      'Probes standing in the room, holding the light that reaches them, so '
      'indirect light survives the camera looking away.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0, pitch: 0.16, distance: 13, height: -0.6);

  bool on = true;
  double intensity = 1.6;
  double retention = 0.94;

  OrbisObject _slab(int key, Vector3 at, Vector3 size, Color colour) =>
      OrbisObject(
        key: key,
        transform: Matrix4.identity()
          ..setTranslation(at)
          ..scaleByDouble(size.x, size.y, size.z, 1),
        colour: linearOf(colour),
        castShadows: true,
      );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) => OrbisScene(
    objects: [
      _slab(
        10,
        Vector3(0, -3, 0),
        Vector3(4, 0.15, 4),
        const Color(0xFFEDEAE3),
      ),
      _slab(
        11,
        Vector3(-4, 0, 0),
        Vector3(0.15, 3, 4),
        const Color(0xFFC7332B),
      ),
      _slab(12, Vector3(4, 0, 0), Vector3(0.15, 3, 4), const Color(0xFF2F6DBF)),
      _slab(
        13,
        Vector3(0, 0, -4),
        Vector3(4, 3, 0.15),
        const Color(0xFFEDEAE3),
      ),
      _slab(
        14,
        Vector3(-1.5, -1.85, 0.6),
        Vector3(1, 1, 1),
        const Color(0xFFF4F2EE),
      ),
      _slab(
        15,
        Vector3(1.6, -1.35, -1.4),
        Vector3(0.9, 1.5, 0.9),
        const Color(0xFFF4F2EE),
      ),
    ],
    lights: [
      OrbisLight(
        key: 1,
        kind: OrbisLightKind.directional,
        intensity: 70000,
        direction: (Vector3(-0.32, -1, -0.16))..normalize(),
        sunAngularRadius: 1.5,
        castShadows: true,
        colour: linearOf(const Color(0xFFFFF6E8)),
      ),
    ],
    // Dim on purpose. Ambient fills shadows evenly and for free, and a room
    // where it does that is a room where a field has nothing left to add.
    sky: OrbisSky(colour: linearOf(const Color(0xFF181D24)), ambient: 400),
    field: OrbisField(
      enabled: on,
      // One probe every two metres through the room, standing from the floor
      // to a little above the walls. Light cannot vary faster than the probes
      // are spaced, which is why a field is coarse and the direct light does
      // the detail.
      origin: Vector3(-4, -2.6, -4),
      spacing: Vector3(2, 2, 2),
      counts: Vector3(5, 4, 5),
      from: 'frame',
      intensity: intensity,
      retention: retention,
    ),
    // The scene has to be drawn into a target for the probes to read it, and
    // then put on the screen. That is the whole reason `copy` exists.
    graph: OrbisRenderGraph(
      targets: const [OrbisTarget(name: 'frame')],
      passes: const [
        OrbisPass(name: 'world', into: 'frame'),
        OrbisPass(
          name: 'present',
          kind: OrbisPassKind.effect,
          effect: OrbisEffect.copy,
          reads: ['frame'],
        ),
      ],
    ),
    camera: camera,
  );

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Field',
        value: on,
        onChanged: (value) {
          on = value;
          changed();
        },
      ),
      Setting(
        label: 'Strength',
        value: intensity,
        min: 0,
        max: 6,
        onChanged: (value) {
          intensity = value;
          changed();
        },
      ),
      Setting(
        label: 'Retention',
        value: retention,
        min: 0.5,
        max: 0.99,
        decimals: 2,
        onChanged: (value) {
          retention = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
OrbisScene(
  field: OrbisField(
    enabled: true,
    origin: Vector3(-4, -2.6, -4),   // where the corner probe stands
    spacing: Vector3(2, 2, 2),       // metres between probes
    counts: Vector3(5, 4, 5),        // how many along each axis
    from: 'frame',                   // the target the probes read
    intensity: 1.6,
    retention: 0.94,                 // how much survives each frame
  ),
  // The probes read the picture the scene drew, so it has to go into a
  // target first and then be put on the screen.
  graph: OrbisRenderGraph(
    targets: const [OrbisTarget(name: 'frame')],
    passes: const [
      OrbisPass(name: 'world', into: 'frame'),
      OrbisPass(
        name: 'present',
        kind: OrbisPassKind.effect,
        effect: OrbisEffect.copy,
        reads: ['frame'],
      ),
    ],
  ),
  // ...
)
''';
}
