/// Runs one worked example, full window, so a frame of it can be looked at.
///
/// The examples are shown inside the editor, which opens on a project list —
/// so nothing draws there until somebody clicks, and neither a frame smoke nor
/// a person trying to reproduce a rendering fault can get at them. This opens
/// straight into a scene.
///
/// Driven by the environment, so a sweep of camera angles is a shell loop
/// rather than a person dragging:
///
///   ORBIS_EXAMPLE=Blocks   which one, by name (default: the first)
///   ORBIS_YAW / ORBIS_PITCH / ORBIS_DISTANCE   where to look from
///   ORBIS_SECONDS          hold the clock still, for a scene that animates
///   ORBIS_WALK=0           give the camera back, for an example that drives it
///   ORBIS_RANGE            how far a population is drawn from; 0 draws it all
///   ORBIS_TREES=0          leave the trees out
///   ORBIS_MESH             a path to a .glb or .gltf, shown on its own
///   ORBIS_MORPH            comma-separated shape weights for that model
///   ORBIS_SHARPEN          run the sharpen effect, 0 to 1, over the frame
///   ORBIS_EFFECT           an effect by name, shown on its own over the frame
///   ORBIS_SMAA=1           the whole three-pass SMAA chain
///   ORBIS_LIGHT            which light the Lights example shows
///   ORBIS_LUMENS           how bright it is
///   ORBIS_PANEL_W / _H     the panel's size in metres
///   ORBIS_CIRCLING=0       stop it going round, so two renders compare
///   ORBIS_BOUNCE_OFF=1     turn the Bounced light example's effect off
///   ORBIS_BOUNCE           with ORBIS_EFFECT=bounce, how much light bounces
///   ORBIS_BOUNCE_RADIUS    how far it looks, in metres
///   ORBIS_BOUNCE_THICKNESS how solid the depth buffer's surfaces are
///   ORBIS_BOUNCE_SLICES    how many directions each pixel fans along
///   ORBIS_VOLUME_AT        where the Environment volumes walk stands, 0 in
///                          the courtyard to 1 at the back of the hall; stops
///                          the walk, and prints what the volumes resolved to
///   ORBIS_VOLUMES_OFF=1    the same place with the volumes left out
///   ORBIS_VOLUME_BLEND     how far outside the hall its look reaches, metres
///   ORBIS_DECALS_OFF=1     paint none of the Decals example's decals
///   ORBIS_DECAL_ONLY       paint only that one of them, counting from 0
///   ORBIS_DECAL_FADE_OFF=1 turn their angle fade off
///   ORBIS_DECAL_MASK_OFF=1 let the paint splash reach the crate's layer
///   ORBIS_OUTLINE=0        the Outline example with nothing outlined
///   ORBIS_OUTLINE_OTHERS=0 outline only the active object
///   ORBIS_OUTLINE_WIDTH    how wide the outline is, in pixels
///   ORBIS_OUTLINE_HIDDEN   shown, faint, dashed or hidden: the part a wall hides
///   ORBIS_AA               off, fxaa or temporal, under the Outline example
///   ORBIS_SPLAT            a .ply or .splat capture for the Gaussian splats
///                          example to show instead of its generated ring
///   ORBIS_SPLAT_COUNT      how many splats the generated ring has
///   ORBIS_SPLAT_SORT=0     draw them unsorted, to measure what the sort does
///   ORBIS_SPLAT_PILLAR=0   take the solid pillar out of the ring
///   ORBIS_BATCHING=0/1     batching off or on, for any example, so the same
///                          frame can be drawn both ways and compared
///   ORBIS_CRATES           how many crates the Batching example draws
///   ORBIS_PALETTE          its colours: One, Six or Every one
///   ORBIS_BATCH_MATERIAL=1 its crates made of one shared material
///   ORBIS_BATCH_MESH       a .glb for its crates, instead of the cube (which
///                          only batches alongside ORBIS_BATCH_MATERIAL=1)
///   ORBIS_MOVING=0         hold its turning crate still
///   ORBIS_SLABS            how many slabs the Overdraw example crosses
///   ORBIS_SHADOWS=0        no shadow pass, for any example
///   ORBIS_POST=0           no post-processing, for any example
///   ORBIS_PANEL_SHADOW=0   the Panel shadows example's panel casts nothing
///   ORBIS_PANEL            its panel's edge in metres
///   ORBIS_PANEL_HEIGHT     how high it hangs
///   ORBIS_SHADOW_LIGHT     which light the Shadows example casts with: Sun,
///                          Spot or Point
///   ORBIS_SHADOW_KIND      its edge: Sharp, Soft, Area or Variance
///   ORBIS_SHADOW_MAP       the map's size in pixels
///   ORBIS_SHADOW_CASCADES  how many cascades a sun's map is split into
///   ORBIS_SHADOW_SPLIT     place the splits by hand, the first at this
///                          fraction of the shadow distance
///   ORBIS_SHADOW_CONTACT=1 screen-space contact shadows
///   ORBIS_SHADOW_CONTACT_DISTANCE  how far each pixel marches, in metres
///   ORBIS_SHADOW_SIZE      the light's size in metres, for the Area edge
///   ORBIS_VSM_BLUR         the Variance edge's blur, in texels
///   ORBIS_GODRAYS          how strong the god rays are; over any example
///                          but God rays itself, turns them on
///   ORBIS_SUN_BEARING      the God rays sun's bearing in degrees, 180
///                          behind the camera
///   ORBIS_SUN_ALTITUDE     and its height above the horizon
///   ORBIS_COVER            the God rays sky's cloud cover, 0 to 1
///   ORBIS_GODRAY_SAMPLES / _DECAY / _DENSITY   the rest of its settings
///   ORBIS_SHOCKWAVE=0      leave the Distortion example's wave out
///   ORBIS_HAZE=0           and its heat haze
///   ORBIS_LENS             its lens warp, negative for pincushion
///   ORBIS_CHROMATIC        its chromatic split
///   ORBIS_WAVE             its wave's strength
///   ORBIS_MOTION=0         turn the Motion blur example's blur off
///   ORBIS_MOTION_OBJECTS=0 blur by the camera's motion only
///   ORBIS_PAN=1            pan the Motion blur example's camera
///   ORBIS_SHUTTER          its shutter, in seconds
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:orbis_examples/orbis_examples.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'orbis_env.dart';

void main() => runApp(const Gallery());

/// Every `ORBIS_*` switch this gallery was started with.
///
/// Where they come from depends on where this is running — a real process
/// environment on macOS, iOS and Android, the page's query string in a
/// browser — so the reading sits behind a conditional import rather than
/// here. The native half is the code that used to be in this file, moved
/// unchanged, including the dart:ffi reading the iOS simulator needs;
/// orbis_env.dart says why.
final Map<String, String> _orbisEnv = readOrbisEnvironment();

double? _number(String name) => double.tryParse(_orbisEnv[name] ?? '');

class Gallery extends StatelessWidget {
  const Gallery({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Orbis Gallery',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const _Stage(),
  );
}

class _Stage extends StatefulWidget {
  const _Stage();

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> with SingleTickerProviderStateMixin {
  late final List<Example> _all = engineExamples();
  late final Example _example = _chosen();
  late final GalleryCamera _look = GalleryCamera.from(_example.viewpoint);
  late final Ticker _clock;

  double _seconds = 0;

  /// A scene that is one model and nothing else.
  ///
  /// Not an example — a way to point the renderer at a file and see what it
  /// makes of it, which is how a question like "does this decode" gets an
  /// answer rather than an opinion.
  OrbisScene _justTheMesh(String path) {
    // Two passes when a sharpen is asked for, one otherwise. An effect reads
    // what another pass drew, so the world has to land in a texture before
    // anything can be done to it.
    // The whole chain: the world into a texture, its edges into another, the
    // weights into a third, and the blend onto the screen reading the first
    // and the third.
    final smaa = _orbisEnv['ORBIS_SMAA'];
    if (smaa == 'edgetarget') {
      // Edges into a target, then blitted to the screen by a sharpen set to
      // nothing. Tells apart "the weights shader is wrong" from "a target
      // does not carry what was drawn into it", which look identical from
      // the far end.
      return _sceneWith(
        path,
        OrbisRenderGraph(
          targets: const [
            OrbisTarget(name: 'frame'),
            OrbisTarget(name: 'edges'),
          ],
          passes: const [
            OrbisPass(name: 'world', into: 'frame'),
            OrbisPass(
              name: 'edges',
              kind: OrbisPassKind.effect,
              effect: OrbisEffect.smaaEdges,
              reads: ['frame'],
              into: 'edges',
            ),
            OrbisPass(
              name: 'show',
              kind: OrbisPassKind.effect,
              effect: OrbisEffect.sharpen,
              reads: ['edges'],
            ),
          ],
        ),
      );
    }
    if (smaa == 'weights') {
      // The chain stopped one short, so the weights land on the screen. What
      // pass two decided is otherwise invisible, and a weights pass that
      // quietly outputs nothing looks exactly like one that works.
      return _sceneWith(
        path,
        OrbisRenderGraph(
          targets: const [
            OrbisTarget(name: 'frame'),
            OrbisTarget(name: 'edges'),
          ],
          passes: const [
            OrbisPass(name: 'world', into: 'frame'),
            OrbisPass(
              name: 'edges',
              kind: OrbisPassKind.effect,
              effect: OrbisEffect.smaaEdges,
              reads: ['frame'],
              into: 'edges',
            ),
            OrbisPass(
              name: 'weights',
              kind: OrbisPassKind.effect,
              effect: OrbisEffect.smaaWeights,
              reads: ['edges'],
            ),
          ],
        ),
      );
    }
    if (smaa == '1') {
      return _sceneWith(
        path,
        OrbisRenderGraph(
          targets: const [
            OrbisTarget(name: 'frame'),
            OrbisTarget(name: 'edges'),
            OrbisTarget(name: 'weights'),
          ],
          passes: const [
            OrbisPass(name: 'world', into: 'frame'),
            OrbisPass(
              name: 'edges',
              kind: OrbisPassKind.effect,
              effect: OrbisEffect.smaaEdges,
              reads: ['frame'],
              into: 'edges',
            ),
            OrbisPass(
              name: 'weights',
              kind: OrbisPassKind.effect,
              effect: OrbisEffect.smaaWeights,
              reads: ['edges'],
              into: 'weights',
            ),
            // The picture first, the weights second. The blend reads both and
            // the order is what tells it which is which.
            OrbisPass(
              name: 'blend',
              kind: OrbisPassKind.effect,
              effect: OrbisEffect.smaaBlend,
              reads: ['frame', 'weights'],
            ),
          ],
        ),
      );
    }

    return _sceneWith(path, _effectGraph());
  }

  /// The one-effect graph the environment asks for, or null for none.
  OrbisRenderGraph? _effectGraph() {
    final named = _orbisEnv['ORBIS_EFFECT'];
    final amount = _number('ORBIS_SHARPEN');
    final effect = named == null || named.isEmpty
        ? (amount == null ? null : OrbisEffect.sharpen)
        : OrbisEffect.values.firstWhere(
            (one) => one.name.toLowerCase() == named.toLowerCase(),
          );
    return effect == null
        ? null
        : OrbisRenderGraph(
            targets: const [OrbisTarget(name: 'frame')],
            passes: [
              const OrbisPass(name: 'world', into: 'frame'),
              OrbisPass(
                name: 'effect',
                kind: OrbisPassKind.effect,
                effect: effect,
                reads: const ['frame'],
                // The dials ride in the plane's four numbers, which a scene
                // pass uses for its mirror and an effect has no use for.
                // Sharpen reads the first; the bounce reads all four as
                // radius, strength, thickness and how many directions.
                plane: [
                  _number('ORBIS_BOUNCE_RADIUS') ?? amount ?? 0,
                  _number('ORBIS_BOUNCE') ?? 0,
                  _number('ORBIS_BOUNCE_THICKNESS') ?? 0,
                  _number('ORBIS_BOUNCE_SLICES') ?? 0,
                ],
              ),
            ],
          );
  }

  /// The scene as the example built it, put through whatever effect the
  /// environment asked for.
  OrbisScene _underEffect(OrbisScene scene) {
    // God rays over an example that never asked for any — the Day and night
    // sky, the Weather's cloud. The God rays example takes the same switch
    // as its own strength instead.
    final rays = _number('ORBIS_GODRAYS');
    final lit = rays != null && _example is! GodRaysExample
        ? scene.copyWith(godRays: OrbisGodRays(strength: rays))
        : scene;
    final graph = _effectGraph();
    final drawn = graph == null ? lit : lit.copyWith(graph: graph);
    // Batching forced one way or the other, over whatever the example chose,
    // so one frame can be drawn both ways and the two compared pixel by pixel.
    // The pipeline and the post-processing are the example's own and are built
    // afresh for every frame, so setting them here cannot leak into the next
    // one.
    if (_orbisEnv['ORBIS_SHADOWS'] == '0') {
      drawn.pipeline.shadows.enabled = false;
    }
    if (_orbisEnv['ORBIS_POST'] == '0') drawn.post.enabled = false;
    return switch (_orbisEnv['ORBIS_BATCHING']) {
      '1' => drawn.copyWith(batching: true),
      '0' => drawn.copyWith(batching: false),
      _ => drawn,
    };
  }

  /// One model, one light, and whatever graph was asked for.
  OrbisScene _sceneWith(String path, OrbisRenderGraph? graph) {
    return OrbisScene(
      graph: graph,
      camera: _look.toRenderCamera(),
      objects: [
        OrbisObject(
          key: 1,
          mesh: path,
          transform: Matrix4.identity(),
          colour: Vector3(1, 1, 1),
          morphWeights: switch (_orbisEnv['ORBIS_MORPH']) {
            final set? when set.isNotEmpty =>
              set.split(',').map((one) => double.parse(one.trim())).toList(),
            _ => null,
          },
        ),
      ],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.5, -0.7, -0.4)..normalize(),
          colour: Vector3(1, 0.97, 0.92),
          intensity: 90000,
          castShadows: true,
        ),
      ],
      sky: OrbisSky(
        zenith: Vector3(0.30, 0.50, 0.78),
        horizon: Vector3(0.72, 0.84, 0.94),
        ambient: 24000,
      ),
    );
  }

  Example _chosen() {
    final wanted = _orbisEnv['ORBIS_EXAMPLE'];
    if (wanted == null || wanted.isEmpty) return _all.first;
    return _all.firstWhere(
      (one) => one.name.toLowerCase() == wanted.toLowerCase(),
      orElse: () {
        warn(
          'no example called "$wanted" — there is '
          '${_all.map((e) => e.name).join(', ')}',
        );
        return _all.first;
      },
    );
  }

  @override
  void initState() {
    super.initState();

    // An example that puts somebody inside it drives the camera itself, which
    // is right for playing and useless for looking at a particular corner of
    // it. This hands the camera back.
    final example = _example;
    if (example is VoxelExample) {
      if (_orbisEnv['ORBIS_WALK'] == '0') example.walking = false;
      final far = _number('ORBIS_RANGE');
      if (far != null) example.range = far;
      if (_orbisEnv['ORBIS_TREES'] == '0') example.trees = false;
    }
    if (example is ProbesExample) {
      example.intensity = _number('ORBIS_PROBE') ?? example.intensity;
      example.roughness = _number('ORBIS_ROUGHNESS') ?? example.roughness;
      if (_orbisEnv['ORBIS_PROBE_OFF'] == '1') example.on = false;
    }
    if (example is LightsExample) {
      final kind = _orbisEnv['ORBIS_LIGHT'];
      if (kind != null) example.kind = kind;
      final lumens = _number('ORBIS_LUMENS');
      if (lumens != null) example.intensity = lumens;
      example.panelWidth = _number('ORBIS_PANEL_W') ?? example.panelWidth;
      example.panelHeight = _number('ORBIS_PANEL_H') ?? example.panelHeight;
      // Still, so two renders of the same angle are the same picture.
      if (_orbisEnv['ORBIS_CIRCLING'] == '0') {
        example.orbiting = false;
      }
    }
    if (example is PanelShadowExample) {
      if (_orbisEnv['ORBIS_PANEL_SHADOW'] == '0') {
        example.shadows = false;
      }
      example.panel = _number('ORBIS_PANEL') ?? example.panel;
      example.height = _number('ORBIS_PANEL_HEIGHT') ?? example.height;
    }
    if (example is ShadowsExample) {
      final light = _orbisEnv['ORBIS_SHADOW_LIGHT'];
      if (light != null) {
        example.light = ShadowLight.values.firstWhere(
          (one) => one.label == light,
          orElse: () => example.light,
        );
      }
      final shadows = example.shadows;
      final kind = _orbisEnv['ORBIS_SHADOW_KIND'];
      if (kind != null) {
        shadows.kind = OrbisShadowKind.values.firstWhere(
          (one) => one.label == kind,
          orElse: () => shadows.kind,
        );
      }
      shadows.mapSize = _number('ORBIS_SHADOW_MAP')?.round() ?? shadows.mapSize;
      shadows.cascades =
          _number('ORBIS_SHADOW_CASCADES')?.round() ?? shadows.cascades;
      final split = _number('ORBIS_SHADOW_SPLIT');
      if (split != null) {
        example.handSplits = true;
        example.firstSplit = split;
      }
      if (_orbisEnv['ORBIS_SHADOW_CONTACT'] == '1') {
        shadows.contact = true;
      }
      shadows.contactDistance =
          _number('ORBIS_SHADOW_CONTACT_DISTANCE') ?? shadows.contactDistance;
      example.lightSize = _number('ORBIS_SHADOW_SIZE') ?? example.lightSize;
      shadows.variance.blur = _number('ORBIS_VSM_BLUR') ?? shadows.variance.blur;
    }
    if (example is FieldExample) {
      example.intensity = _number('ORBIS_FIELD') ?? example.intensity;
      example.retention = _number('ORBIS_RETENTION') ?? example.retention;
      if (_orbisEnv['ORBIS_FIELD_OFF'] == '1') example.on = false;
    }
    if (example is BatchingExample) {
      example.count = _number('ORBIS_CRATES') ?? example.count;
      example.palette = _orbisEnv['ORBIS_PALETTE'] ?? example.palette;
      if (_orbisEnv['ORBIS_BATCH_MATERIAL'] == '1') {
        example.material = true;
      }
      final mesh = _orbisEnv['ORBIS_BATCH_MESH'];
      if (mesh != null && mesh.isNotEmpty) example.mesh = mesh;
      if (_orbisEnv['ORBIS_MOVING'] == '0') example.moving = false;
    }
    if (example is OverdrawExample) {
      example.slabs = _number('ORBIS_SLABS') ?? example.slabs;
    }
    if (example is GodRaysExample) {
      example.strength = _number('ORBIS_GODRAYS') ?? example.strength;
      example.bearing = _number('ORBIS_SUN_BEARING') ?? example.bearing;
      example.altitude = _number('ORBIS_SUN_ALTITUDE') ?? example.altitude;
      example.cover = _number('ORBIS_COVER') ?? example.cover;
      example.samples = _number('ORBIS_GODRAY_SAMPLES') ?? example.samples;
      example.decay = _number('ORBIS_GODRAY_DECAY') ?? example.decay;
      example.density = _number('ORBIS_GODRAY_DENSITY') ?? example.density;
    }
    if (example is DistortionExample) {
      if (_orbisEnv['ORBIS_SHOCKWAVE'] == '0') {
        example.shockwave = false;
      }
      if (_orbisEnv['ORBIS_HAZE'] == '0') example.haze = false;
      example.lens = _number('ORBIS_LENS') ?? example.lens;
      example.chromatic = _number('ORBIS_CHROMATIC') ?? example.chromatic;
      example.strength = _number('ORBIS_WAVE') ?? example.strength;
    }
    if (example is BounceExample) {
      example.strength = _number('ORBIS_BOUNCE') ?? example.strength;
      example.reach = _number('ORBIS_BOUNCE_RADIUS') ?? example.reach;
      if (_orbisEnv['ORBIS_BOUNCE_OFF'] == '1') example.on = false;
    }
    if (example is DecalsExample) {
      final environment = _orbisEnv;
      if (environment['ORBIS_DECALS_OFF'] == '1') example.on = false;
      if (environment['ORBIS_DECAL_FADE_OFF'] == '1') example.angleFade = false;
      if (environment['ORBIS_DECAL_MASK_OFF'] == '1') {
        example.spareTheCrate = false;
      }
      example.only = _number('ORBIS_DECAL_ONLY')?.round();
    }

    if (example is EnvironmentVolumesExample) {
      final at = _number('ORBIS_VOLUME_AT');
      if (at != null) {
        example.walking = false;
        example.along = at;
      }
      example.blend = _number('ORBIS_VOLUME_BLEND') ?? example.blend;
      if (_orbisEnv['ORBIS_VOLUMES_OFF'] == '1') {
        example.volumes = false;
      }
      // The numbers the frame was drawn with, beside the frame. A blend is
      // checked for a step by reading these along a sweep, not by eye.
      if (at != null) {
        final scene = example.scene(_look.toRenderCamera(), 0);
        final seen = scene.resolved();
        String three(Vector3 v) => [
          v.x,
          v.y,
          v.z,
        ].map((c) => c.toStringAsFixed(4)).join(',');
        warn(
          '[volumes] at=$at z=${scene.camera.position.z.toStringAsFixed(3)} '
          'fogDensity=${seen.fog.density.toStringAsFixed(5)} '
          'fogColour=${three(seen.fog.colour)} '
          'ambient=${seen.sky.ambient.toStringAsFixed(1)} '
          'skyColour=${three(seen.sky.colour)} '
          'shutter=${seen.camera.shutterSpeed.toStringAsFixed(6)}',
        );
      }
    }

    if (example is OutlineExample) {
      if (_orbisEnv['ORBIS_OUTLINE'] == '0') example.on = false;
      if (_orbisEnv['ORBIS_OUTLINE_OTHERS'] == '0') {
        example.others = false;
      }
      example.width = _number('ORBIS_OUTLINE_WIDTH') ?? example.width;
      final hidden = _orbisEnv['ORBIS_OUTLINE_HIDDEN'];
      if (hidden != null && hidden.isNotEmpty) {
        example.occluded = OrbisOccluded.values.byName(hidden);
      }
      final aa = _orbisEnv['ORBIS_AA'];
      if (aa != null && aa.isNotEmpty) {
        example.antiAliasing = AntiAliasing.values.byName(aa);
      }
    }

    if (example is SplatsExample) {
      final capture = _orbisEnv['ORBIS_SPLAT'];
      if (capture != null && capture.isNotEmpty) example.path = capture;
      example.count = _number('ORBIS_SPLAT_COUNT')?.round() ?? example.count;
      if (_orbisEnv['ORBIS_SPLAT_SORT'] == '0') {
        example.sorted = false;
      }
      if (_orbisEnv['ORBIS_SPLAT_PILLAR'] == '0') {
        example.pillar = false;
      }
    }

    if (example is MotionBlurExample) {
      if (_orbisEnv['ORBIS_MOTION'] == '0') example.on = false;
      if (_orbisEnv['ORBIS_MOTION_OBJECTS'] == '0') {
        example.objects = false;
      }
      if (_orbisEnv['ORBIS_PAN'] == '1') example.panning = true;
      example.shutter = _number('ORBIS_SHUTTER') ?? example.shutter;
    }

    _look.yaw = _number('ORBIS_YAW') ?? _look.yaw;
    _look.pitch = _number('ORBIS_PITCH') ?? _look.pitch;
    _look.distance = _number('ORBIS_DISTANCE') ?? _look.distance;

    // A fixed clock when one is asked for, so two runs of an animating scene
    // are the same picture and can be compared.
    final held = _number('ORBIS_SECONDS');
    if (held != null) {
      _seconds = held;
      _clock = Ticker((_) => setState(() {}))..start();
    } else {
      _clock = Ticker((elapsed) {
        setState(() => _seconds = elapsed.inMicroseconds / 1e6);
      })..start();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: GestureDetector(
      onPanUpdate: (details) => setState(() => _look.orbit(details.delta)),
      child: OrbisView(
        scene: switch (_orbisEnv['ORBIS_MESH']) {
          final path? when path.isNotEmpty => _justTheMesh(path),
          // An effect over a real scene rather than only over a lone model.
          // An effect that has only ever been seen against one mesh on a
          // plain background is an effect nobody has actually looked at.
          _ => _underEffect(_example.scene(_look.toRenderCamera(), _seconds)),
        },
      ),
    ),
  );
}
