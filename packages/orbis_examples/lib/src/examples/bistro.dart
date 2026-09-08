import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// The Amazon Lumberyard Bistro, lit by this engine.
///
/// Every other example builds its scene out of cubes, which is honest about
/// what it is demonstrating and useless for judging whether the lighting
/// looks right. A cube lit badly still looks like a cube. This is somebody
/// else's art, built for a different renderer, with reference images of how
/// it is supposed to look — which is the only way to find out whether a
/// lighting model is convincing rather than merely arithmetic.
///
/// It is also the heaviest thing here by a wide margin: 1,296 meshes, 132
/// materials and 2.8 million triangles in the exterior, against a hundred
/// point lights. What a frame costs on this is worth more than what it costs
/// on a hundred thousand cubes, because it is shaped like a real scene.
///
///   Amazon Lumberyard Bistro, Open Research Content Archive (ORCA)
///   https://developer.nvidia.com/orca/amazon-lumberyard-bistro
///   Amazon Lumberyard, CC BY 4.0
///
/// Fetched rather than shipped — it is half a gigabyte, and not ours:
///
///   ./tool/fetch_bistro.sh exterior
abstract class BistroExample extends Example {
  BistroExample();

  /// Which file, under the fetched directory.
  String get asset;

  /// Where the assets landed. The engine repository's own path by default,
  /// because that is where the fetch script puts them, and an override for
  /// everybody whose checkout is somewhere else.
  static String get directory =>
      Platform.environment['ORBIS_BISTRO'] ?? '../orbis/assets/bistro';

  String get _model => '$directory/$asset.gltf';

  /// The fixtures, taken out of the scene's own emissive geometry when it was
  /// fetched. Read once: it is a hundred entries and the scene is rebuilt
  /// sixty times a second.
  late final List<BistroFixture> fixtures = _readFixtures();

  List<BistroFixture> _readFixtures() {
    final file = File('$directory/$asset.lights.json');
    if (!file.existsSync()) return const [];
    final rows = jsonDecode(file.readAsStringSync()) as List<Object?>;
    return [
      for (final row in rows.cast<Map<String, Object?>>())
        BistroFixture(
          kind: row['kind']! as String,
          at: Vector3(
            (row['at']! as List)[0] as double,
            (row['at']! as List)[1] as double,
            (row['at']! as List)[2] as double,
          ),
        ),
    ];
  }

  bool get ready => File(_model).existsSync();

  /// The model, as one object. Its own root node carries the turn from Z-up
  /// and the scale into metres, so nothing is done to it here.
  OrbisObject get model => OrbisObject(
    key: 1,
    transform: Matrix4.identity(),
    colour: Vector3(0.8, 0.8, 0.8),
    mesh: File(_model).absolute.path,
  );

  @override
  Widget? overlay(BuildContext context, VoidCallback changed) {
    if (ready) return null;
    return const _Missing();
  }
}

/// One emissive fixture in the scene, and where it is.
class BistroFixture {
  const BistroFixture({required this.kind, required this.at});

  final String kind;
  final Vector3 at;
}

/// What each kind of fixture is, in units a fitting is sold in.
///
/// Lumens rather than a brightness between nought and one, because these are
/// real fittings in a real street: a sodium street lamp is a couple of
/// thousand lumens and a festoon bulb is under a hundred, and that ratio of
/// twenty-five to one is most of why the reference images read as evening
/// rather than as a stage set.
const _fittings = <String, ({Color colour, double lumens, double reach})>{
  // Reach is a cull distance as much as a physical one — beyond it the light
  // contributes nothing and the renderer can skip it. Set too short it is
  // visible as a hard edge where a pool of light stops, and set to what a
  // lamp really lights, the pools overlap the way they do in a street.
  'street': (colour: Color(0xFFFFB870), lumens: 5200, reach: 28),
  'spot': (colour: Color(0xFFFFD5A8), lumens: 1400, reach: 12),
  'sign': (colour: Color(0xFFFFE0B0), lumens: 900, reach: 9),
  'orange': (colour: Color(0xFFFF8A3D), lumens: 70, reach: 4),
  'red': (colour: Color(0xFFFF4A4A), lumens: 70, reach: 4),
  'white': (colour: Color(0xFFFFF2DC), lumens: 90, reach: 4),
  'pink': (colour: Color(0xFFFF7ACB), lumens: 70, reach: 4),
  'blue': (colour: Color(0xFF5AA6FF), lumens: 70, reach: 4),
  'green': (colour: Color(0xFF6BE86B), lumens: 70, reach: 4),
};

/// The street outside, at night or in daylight.
///
/// Your four reference images are two scenes: this is the first two of them.
/// Night is the interesting one — a hundred small sources, six colours of
/// festoon bulb, and almost no ambient — because that is the case a renderer
/// either sells or does not.
class BistroExteriorExample extends BistroExample {
  BistroExteriorExample();

  @override
  String get name => 'Bistro exterior';

  @override
  String get blurb =>
      'Somebody else\'s street, lit by this engine. A hundred lights at night.';

  @override
  String get asset => 'BistroExterior';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 22, pitch: 0.20, height: 3, yaw: 2.2);

  bool night = true;
  bool festoon = true;

  /// The film speed, which at night is the dial that decides whether there is
  /// a picture at all.
  double iso = 1600;

  /// The moon, in lux. A real full moon is about a quarter of one.
  double moon = 4;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final lights = <OrbisLight>[];
    var key = 100;

    if (night) {
      for (final fixture in fixtures) {
        final fitting = _fittings[fixture.kind];
        if (fitting == null) continue;
        if (!festoon && fitting.lumens < 100) continue;
        lights.add(
          OrbisLight(
            key: key++,
            kind: OrbisLightKind.point,
            position: fixture.at,
            colour: linearOf(fitting.colour),
            intensity: fitting.lumens,
            falloffRadius: fitting.reach,
            // A hundred shadow-casting points is not a thing any real-time
            // renderer does, and it is not what makes this read: the shadows
            // that matter here are the ones the moon casts.
            castShadows: false,
          ),
        );
      }
      // The moon, at what a moon actually is.
      //
      // This was 900 lux, and that one number was most of why the night did
      // not read as night: it is roughly three thousand times a real full
      // moon, so it flooded every surface evenly and the hundred lamps —
      // which are the whole point — contributed almost nothing next to it.
      // A scene lit flat has no depth, and no amount of tuning the lamps
      // fixes a fill light that is drowning them.
      //
      // Three lux is generous for a full moon and leaves the street dark
      // enough that a lamp pools light on it, which is what the reference
      // images actually look like.
      lights.add(
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.3, -1, 0.4)..normalize(),
          colour: linearOf(const Color(0xFF9FB4D8)),
          intensity: moon,
          castShadows: true,
        ),
      );
    } else {
      // Daylight is one light, which is the whole point of stating these in
      // lux: a hundred thousand of them is what the sun actually is.
      lights.add(
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.45, -0.82, -0.35)..normalize(),
          colour: linearOf(const Color(0xFFFFF6E8)),
          intensity: 100000,
          castShadows: true,
        ),
      );
    }

    return OrbisScene(
      // The camera the gallery hands over is framed on sunny-16 — f/16 at a
      // hundred-and-twenty-fifth, ISO 100 — which is right for the daylight
      // setting and about seventeen stops too dark for the night one. That is
      // not a detail: on one fixed exposure either the night is black or the
      // day is white, which is exactly why these are stated as a real camera's
      // three numbers rather than as a brightness.
      camera: OrbisCamera(
        position: camera.position,
        target: camera.target,
        fieldOfView: camera.fieldOfView,
        aperture: night ? 2.0 : 16,
        shutterSpeed: night ? 1 / 30 : 1 / 125,
        sensitivity: night ? iso : 100,
      ),
      objects: [model],
      lights: lights,
      sky: night
          ? OrbisSky(
              zenith: linearOf(const Color(0xFF0B1224)),
              horizon: linearOf(const Color(0xFF243046)),
              // Not zero — a night sky still casts light, and shadows with
              // nothing in them read as holes. But close to it: this is the
              // sky's own glow, not a stage wash, and at anything like a
              // hundred lux it stops being night.
              ambient: 12,
              showBody: false,
            )
          : OrbisSky(
              zenith: linearOf(const Color(0xFF4E86C8)),
              horizon: linearOf(const Color(0xFFBFD4E8)),
              ambient: 22000,
            ),
      pipeline: OrbisPipeline(
        shadows: OrbisShadows(
          kind: OrbisShadowKind.soft,
          cascades: 4,
          mapSize: 2048,
          // Not the default. `distance` is Filament's shadowFar, and it
          // defaults to zero — which over four cascades leaves the shadow map
          // covering nothing, so every surface samples as shadowed and the
          // scene renders black under a hundred thousand lux of sun. This
          // street is a hundred and seventy metres across.
          distance: 120,
        ),
        // Four samples. A street full of railings, shutters and thin lamp
        // posts is nothing but edges, and edges are what a single sample
        // makes a mess of.
        samples: 4,
      ),
      // Bloom at night only — it is what makes a small bright bulb read as a
      // light rather than as a white dot, and in daylight it only fogs the
      // image. Occlusion always: it is the cheapest stand-in for the contact
      // darkening that bounced light would give, and without it everything
      // sits on the ground rather than in it.
      post: OrbisPostProcess(
        antiAliasing: AntiAliasing.fxaa,
        bloom: OrbisBloom(enabled: night, strength: 0.22, levels: 7),
        occlusion: OrbisOcclusion(enabled: true),
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: night,
          title: const Text('Night'),
          subtitle: Text(
            night
                ? '${fixtures.length} point lights'
                : 'One sun at 100,000 lux',
          ),
          onChanged: (value) {
            night = value;
            changed();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: festoon,
          title: const Text('Festoon lights'),
          subtitle: const Text('The small coloured bulbs'),
          onChanged: night
              ? (value) {
                  festoon = value;
                  changed();
                }
              : null,
        ),
        if (night) ...[
          const SizedBox(height: 8),
          Text(
            'Film speed — ISO ${iso.round()}',
            style: const TextStyle(fontSize: 12),
          ),
          Slider(
            value: iso,
            min: 100,
            max: 6400,
            onChanged: (value) {
              iso = value;
              changed();
            },
          ),
          const Text(
            'At ISO 100 this street is black. The lamps have not changed; '
            'the camera has.',
            style: TextStyle(fontSize: 11, height: 1.4),
          ),
        ],
      ],
    );
  }

  @override
  String get code => '''
// The fixtures come out of the scene's own emissive geometry, so the lights
// stand where the artist put the lamps.
for (final fixture in fixtures)
  OrbisLight(
    kind: OrbisLightKind.point,
    position: fixture.at,
    intensity: 2400,       // lumens — a street lamp
    falloffRadius: 14,     // metres
    castShadows: false,    // a hundred shadow casters is not a thing
  ),

// And the sky is still a light, even at night.
OrbisSky(zenith: Color(0xFF0B1224), horizon: Color(0xFF243046), ambient: 120)
''';
}

/// The room inside, which is the harder case.
///
/// Your third and fourth reference images. An interior is where a real-time
/// renderer is most obviously not a path tracer: almost none of the light in
/// a room like this arrives straight from a bulb, it arrives off the walls
/// and the ceiling. Filament has image-based lighting and screen-space
/// occlusion; it does not have bounced light. What that costs is visible
/// here and nowhere else in this gallery, which is the reason to have it.
class BistroInteriorExample extends BistroExample {
  BistroInteriorExample();

  @override
  String get name => 'Bistro interior';

  @override
  String get blurb =>
      'The room, and the one place the absence of bounced light shows.';

  @override
  String get asset => wine ? 'BistroInterior_Wine' : 'BistroInterior';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 9, pitch: 0.06, height: 1.7, yaw: 0.4);

  bool wine = false;
  double ambient = 400;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final lights = <OrbisLight>[];
    var key = 100;

    for (final fixture in fixtures) {
      final fitting = _fittings[fixture.kind];
      if (fitting == null) continue;
      lights.add(
        OrbisLight(
          key: key++,
          kind: OrbisLightKind.point,
          position: fixture.at,
          colour: linearOf(fitting.colour),
          intensity: fitting.lumens,
          falloffRadius: fitting.reach,
          castShadows: false,
        ),
      );
    }

    // If the room has no fixtures of its own, light it the way the reference
    // does: warm pendants over the tables, at the height they hang.
    if (lights.isEmpty) {
      for (var i = 0; i < 6; i++) {
        lights.add(
          OrbisLight(
            key: key++,
            kind: OrbisLightKind.point,
            position: Vector3(-4.0 + i * 1.8, 2.6, i.isEven ? -1.2 : 1.4),
            colour: linearOf(const Color(0xFFFFD9A8)),
            intensity: 900,
            falloffRadius: 6,
            castShadows: i == 0,
          ),
        );
      }
    }

    return OrbisScene(
      camera: camera,
      objects: [model],
      lights: lights,
      // Standing in for the light this renderer will not bounce. In a real
      // room the walls are half the lighting; here the ambient is the only
      // thing filling a shadow, so it is a dial rather than a constant.
      sky: OrbisSky(
        zenith: linearOf(const Color(0xFF2A1D18)),
        horizon: linearOf(const Color(0xFF3A2A20)),
        ambient: ambient,
        showBody: false,
        drawn: false,
      ),
      pipeline: OrbisPipeline(
        shadows: OrbisShadows(
          kind: OrbisShadowKind.soft,
          mapSize: 2048,
          // A room rather than a street, so the shadows only have to reach
          // across it — but not zero, which covers nothing at all.
          distance: 30,
        ),
      ),
      post: OrbisPostProcess(
        bloom: OrbisBloom(enabled: true, strength: 0.1),
        // Occlusion earns its place indoors. It is the cheapest approximation
        // of the contact darkening that bounced light would give for free.
        occlusion: OrbisOcclusion(enabled: true),
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: wine,
          title: const Text('Wine dressing'),
          subtitle: const Text('The variant with the bottles and glasses'),
          onChanged: (value) {
            wine = value;
            changed();
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Ambient — ${ambient.round()} lux',
          style: const TextStyle(fontSize: 12),
        ),
        Slider(
          value: ambient,
          min: 0,
          max: 2000,
          onChanged: (value) {
            ambient = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// Indoors, the ambient is doing the job bounced light would do. Drag it to
// nothing and the shadows go black, which is exactly what a renderer without
// global illumination looks like when nothing stands in for it.
OrbisSky(
  zenith: linearOf(const Color(0xFF2A1D18)),
  ambient: 400,     // lux
  drawn: false,     // lighting only; there is no sky to see from in here
)

// And occlusion, the cheapest approximation of contact darkening.
OrbisPostProcess(occlusion: OrbisOcclusion(enabled: true))
''';
}

/// Shown over the viewport when the scene has not been fetched.
class _Missing extends StatelessWidget {
  const _Missing();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xE6161A21),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'The Bistro is not here yet.',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text(
              'It is half a gigabyte and belongs to somebody else, so it is '
              'fetched rather than shipped:\n\n'
              './tool/fetch_bistro.sh exterior\n\n'
              'Set ORBIS_BISTRO if your checkout is somewhere else.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
