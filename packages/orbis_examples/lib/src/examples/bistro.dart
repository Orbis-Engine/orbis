import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

  /// The prefiltered environment cmgen made when the scene was fetched.
  ///
  /// Empty when it has not been built, and the scene falls back to the flat
  /// ambient — which is worth saying out loud, because the difference between
  /// the two is most of the difference between a render and a photograph.
  String get radiance => _envIfPresent('bistro_ibl.ktx');
  String get skyboxMap => _envIfPresent('bistro_skybox.ktx');

  String _envIfPresent(String name) {
    final file = File('$directory/$name');
    return file.existsSync() ? file.absolute.path : '';
  }

  bool get hasEnvironment => radiance.isNotEmpty;

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

  bool night = false;
  bool festoon = true;

  /// The film speed, which at night is the dial that decides whether there is
  /// a picture at all.
  double iso = 1600;

  /// The moon, in lux. A real full moon is about a quarter of one.
  double moon = 4;

  /// Walk the street rather than orbit it.
  ///
  /// An orbit is the right camera for looking at an object and the wrong one
  /// for a place. A street is meant to be walked down: the lamps pass
  /// overhead one at a time, the shopfronts come alongside, and the light on
  /// a wall changes because you moved rather than because the wall did. None
  /// of that is visible from a fixed point spinning around the middle.
  bool walking = true;

  /// Where the walk goes.
  ///
  /// Searched, not chosen, and then checked. Two earlier attempts were
  /// guesses dressed up as reasoning: the first followed the street lamps, on
  /// the argument that lamps stand along a street — they stand on the
  /// pavement, with the building between them, so it walked through the
  /// restaurant. The second read an occupancy map by eye at three-metre
  /// resolution and picked a corridor out of it, which clipped eighteen
  /// samples in a hundred.
  ///
  /// These come from a breadth-first search of the open ground: every
  /// primitive occupying the height a person does becomes a solid box, the
  /// free space around the plaza is flooded at half a metre with three
  /// quarters of a metre of clearance, and the longest route through it is
  /// what the walk follows. Two hundred and thirty-six square metres of
  /// walkable ground, and fifty-six metres of walk in it.
  ///
  /// Twelve waypoints rather than five because the curve between them bows
  /// outward, and a sparse set bows far enough to cut a corner into a wall —
  /// at nine points the tightest clearance was zero. At these the curve keeps
  /// half a metre from anything, measured at six hundred points along it,
  /// which is what makes this a checked path rather than a third guess.
  static final _path = <Vector3>[
    Vector3(-4.0, 1.7, -12.0),
    Vector3(-9.0, 1.7, -12.0),
    Vector3(-10.0, 1.7, -8.0),
    Vector3(-10.0, 1.7, -3.0),
    Vector3(-10.0, 1.7, 2.0),
    Vector3(-7.0, 1.7, 4.0),
    Vector3(-6.0, 1.7, 8.0),
    Vector3(-2.0, 1.7, 9.0),
    Vector3(1.5, 1.7, 10.5),
    Vector3(4.5, 1.7, 12.5),
    Vector3(8.5, 1.7, 13.5),
    Vector3(11.5, 1.7, 15.5),
  ];

  (Vector3, Vector3) _walk(double seconds) {
    const pace = 1.3; // metres a second
    const turnTime = 3.2; // long enough to read as a turn, not a spin

    final total = _length;
    final walkTime = total / pace;
    final cycle = (walkTime + turnTime) * 2;
    final t = seconds % cycle;

    // How far along, and how far through a turn. The yaw is built up as one
    // number that only ever increases through the cycle — heading, then
    // heading plus half a turn, then a whole one — because a yaw that jumps
    // back is exactly the snap this had before: the return leg faced one way
    // and the turn at the end of it started from the other.
    final double distance;
    var extraTurn = 0.0;
    if (t < walkTime) {
      distance = t * pace;
    } else if (t < walkTime + turnTime) {
      distance = total;
      extraTurn = _ease((t - walkTime) / turnTime);
    } else if (t < walkTime * 2 + turnTime) {
      distance = total - (t - walkTime - turnTime) * pace;
      extraTurn = 1;
    } else {
      distance = 0;
      extraTurn = 1 + _ease((t - walkTime * 2 - turnTime) / turnTime);
    }

    final (at, tangent) = _onPath(distance);

    // The way the body faces. On the return leg the tangent still points the
    // way the path was drawn, so it is the half-turns that carry the
    // direction — one of them says "walking back", two says "round again".
    final yaw = math.atan2(tangent.z, tangent.x) + math.pi * extraTurn;

    // Looking about, on top of that. Two slow waves so it never settles into
    // an obvious rhythm, and gentle enough not to fight the turn.
    final sweep =
        math.sin(seconds * 0.19) * 0.42 + math.sin(seconds * 0.081) * 0.2;

    // The bob. Two steps a second at a walking pace, and a couple of
    // centimetres — enough to feel, not enough to notice. It fades out
    // through a turn rather than stopping dead, because somebody turning on
    // the spot is not taking strides but does not freeze either.
    final striding =
        1 - (extraTurn % 1 == 0 ? 0.0 : math.sin(extraTurn % 1 * math.pi));
    final bob = math.sin(seconds * math.pi * 2 * 1.8) * 0.022 * striding;
    final eye = Vector3(at.x, at.y + bob, at.z);

    final look = yaw + sweep;
    // A little up: the interesting part of this street is above eye level —
    // the lamps, the signage, the balconies.
    final rise = 0.14 + math.sin(seconds * 0.13) * 0.09;
    return (
      eye,
      eye + Vector3(math.cos(look) * 8, rise * 8, math.sin(look) * 8),
    );
  }

  /// Smoothstep: starts and stops at zero speed.
  static double _ease(double t) {
    final c = t.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  /// The path, as a curve rather than a set of corners.
  ///
  /// A polyline was the first attempt and it is where the snap came from:
  /// between waypoints the direction is constant, and at each one it changes
  /// instantly. Four waypoints is three sharp turns, however smoothly the
  /// ends of the walk are handled.
  ///
  /// Catmull-Rom passes through every point it is given and has a continuous
  /// tangent, so both where the camera is and where it is pointed change
  /// smoothly the whole way along.
  static Vector3 _spline(double u) {
    final n = _path.length;
    final scaled = u.clamp(0.0, 1.0) * (n - 1);
    final i = scaled.floor().clamp(0, n - 2);
    final f = scaled - i;
    // The ends are doubled up so the curve starts and finishes where the
    // waypoints do rather than overshooting past them.
    final p0 = _path[(i - 1).clamp(0, n - 1)];
    final p1 = _path[i];
    final p2 = _path[(i + 1).clamp(0, n - 1)];
    final p3 = _path[(i + 2).clamp(0, n - 1)];
    return (p1 * 2.0 +
            (p2 - p0) * f +
            (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * (f * f) +
            (p1 * 3.0 - p0 - p2 * 3.0 + p3) * (f * f * f)) *
        0.5;
  }

  /// The curve's length, measured once by walking it.
  static final double _length = () {
    var total = 0.0;
    var previous = _spline(0);
    for (var i = 1; i <= _samples; i++) {
      final next = _spline(i / _samples);
      total += (next - previous).length;
      previous = next;
    }
    return total;
  }();

  static const int _samples = 240;

  /// Where the curve is `distance` metres along it, and which way it points.
  ///
  /// Walked at constant speed rather than at constant parameter: a spline's
  /// parameter is not its arc length, so stepping it evenly speeds up through
  /// the straights and dawdles round the bends.
  static (Vector3, Vector3) _onPath(double distance) {
    var travelled = 0.0;
    var previous = _spline(0);
    for (var i = 1; i <= _samples; i++) {
      final u = i / _samples;
      final next = _spline(u);
      final step = (next - previous).length;
      if (travelled + step >= distance) {
        final f = step > 0 ? (distance - travelled) / step : 0.0;
        final at = previous + (next - previous) * f;
        return (at, (next - previous).normalized());
      }
      travelled += step;
      previous = next;
    }
    final end = _spline(1);
    return (end, (end - _spline(1 - 1 / _samples)).normalized());
  }

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
      camera: () {
        final (eye, look) = walking
            ? _walk(seconds)
            : (camera.position, camera.target);
        return OrbisCamera(
          position: eye,
          target: look,
          // Wider on foot. Fifty degrees is a portrait lens and a street seen
          // through one feels like a corridor; somebody actually standing in
          // this square sees most of it at once.
          fieldOfView: walking ? 65 : camera.fieldOfView,
          aperture: night ? 2.0 : 16,
          shutterSpeed: night ? 1 / 30 : 1 / 125,
          sensitivity: night ? iso : 100,
        );
      }(),
      objects: [model],
      lights: lights,
      // A photograph of a real sky, prefiltered — the reflection in its mip
      // chain and the diffuse in its harmonics. Only by day: this is a bridge
      // at noon, and using it at night would light the street with sunshine.
      environment: night || !hasEnvironment
          ? const OrbisEnvironment()
          : OrbisEnvironment(
              radiance: radiance,
              skybox: skyboxMap,
              intensity: 30000,
            ),
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
              // Both off when there is an environment. A procedural sky and a
              // photographed one are two answers to the same question and the
              // procedural one wins, so leaving it on would hide the very
              // thing it was fetched for — and light the scene twice.
              ambient: hasEnvironment ? 0 : 22000,
              drawn: !hasEnvironment,
            ),
      pipeline: OrbisPipeline(
        shadows: OrbisShadows(
          kind: OrbisShadowKind.soft,
          cascades: 4,
          mapSize: 2048,
          // A hundred and seventy metres of street, so the shadows are told
          // to reach across it rather than left at the default.
          distance: 120,
          // Contact shadows. A cascaded map cannot resolve where a chair leg
          // meets the cobbles, so without these everything fine-grained
          // floats a few centimetres above the ground.
          contact: true,
          softness: 1.2,
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
        // Temporal, not FXAA. It resolves an edge by sampling it in different
        // places on successive frames, which is why it is the best-looking of
        // the three and why it smears when something moves fast. A camera
        // walking at one and a third metres a second is exactly the case it
        // is good at, and a street of railings and shutters and thin lamp
        // posts is nothing but the edges it fixes.
        antiAliasing: AntiAliasing.temporal,
        bloom: OrbisBloom(enabled: night, strength: 0.22, levels: 7),
        // The cheapest stand-in for the contact darkening that bounced light
        // would give: without it everything sits on the ground rather than in
        // it.
        occlusion: OrbisOcclusion(enabled: true, quality: 2, radius: 0.4),
        // Wet cobbles and shop glass. Screen-space, so it can only reflect
        // what is already on screen — which is most of what a street reflects
        // anyway, since the thing above a pavement is usually the building
        // across from it.
        reflections: OrbisReflections(enabled: true, maxDistance: 6),
        // ACES rather than the plain filmic curve. More contrast and more
        // saturation, and the transform most films are graded through — which
        // matters most at night, where the difference between a lamp and the
        // dark it stands in is the whole picture.
        grading: OrbisGrading(
          enabled: true,
          toneMapping: ToneMapping.aces,
          contrast: night ? 1.06 : 1.0,
        ),
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Toggle(
          label: 'Walk',
          value: walking,
          note: walking ? 'On foot, looking around' : 'Drag to orbit instead',
          onChanged: (value) {
            walking = value;
            changed();
          },
        ),
        Toggle(
          label: 'Night',
          value: night,
          note: night
              ? '${fixtures.length} point lights'
              : 'One sun at 100,000 lux',
          onChanged: (value) {
            night = value;
            changed();
          },
        ),
        Toggle(
          label: 'Festoon',
          value: festoon,
          note: 'The small coloured bulbs',
          enabled: night,
          onChanged: (value) {
            festoon = value;
            changed();
          },
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
          contact: true,
        ),
      ),
      post: OrbisPostProcess(
        antiAliasing: AntiAliasing.temporal,
        bloom: OrbisBloom(enabled: true, strength: 0.1),
        // Occlusion earns its place indoors more than anywhere. It is the
        // cheapest approximation of the contact darkening that bounced light
        // would give for free, and indoors bounced light is most of the
        // lighting.
        occlusion: OrbisOcclusion(enabled: true, quality: 2, radius: 0.4),
        grading: OrbisGrading(enabled: true, toneMapping: ToneMapping.aces),
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Toggle(
          label: 'Wine',
          value: wine,
          note: 'The variant with the bottles and glasses',
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
