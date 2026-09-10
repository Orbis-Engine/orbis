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
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:orbis_examples/orbis_examples.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

void main() => runApp(const Gallery());

double? _number(String name) =>
    double.tryParse(Platform.environment[name] ?? '');

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
    final smaa = Platform.environment['ORBIS_SMAA'];
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
    final named = Platform.environment['ORBIS_EFFECT'];
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
    final graph = _effectGraph();
    final drawn = graph == null ? scene : scene.copyWith(graph: graph);
    // Batching forced one way or the other, over whatever the example chose,
    // so one frame can be drawn both ways and the two compared pixel by pixel.
    // The pipeline and the post-processing are the example's own and are built
    // afresh for every frame, so setting them here cannot leak into the next
    // one.
    if (Platform.environment['ORBIS_SHADOWS'] == '0') {
      drawn.pipeline.shadows.enabled = false;
    }
    if (Platform.environment['ORBIS_POST'] == '0') drawn.post.enabled = false;
    return switch (Platform.environment['ORBIS_BATCHING']) {
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
          morphWeights: switch (Platform.environment['ORBIS_MORPH']) {
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
    final wanted = Platform.environment['ORBIS_EXAMPLE'];
    if (wanted == null || wanted.isEmpty) return _all.first;
    return _all.firstWhere(
      (one) => one.name.toLowerCase() == wanted.toLowerCase(),
      orElse: () {
        stderr.writeln(
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
      if (Platform.environment['ORBIS_WALK'] == '0') example.walking = false;
      final far = _number('ORBIS_RANGE');
      if (far != null) example.range = far;
      if (Platform.environment['ORBIS_TREES'] == '0') example.trees = false;
    }
    if (example is ProbesExample) {
      example.intensity = _number('ORBIS_PROBE') ?? example.intensity;
      example.roughness = _number('ORBIS_ROUGHNESS') ?? example.roughness;
      if (Platform.environment['ORBIS_PROBE_OFF'] == '1') example.on = false;
    }
    if (example is LightsExample) {
      final kind = Platform.environment['ORBIS_LIGHT'];
      if (kind != null) example.kind = kind;
      final lumens = _number('ORBIS_LUMENS');
      if (lumens != null) example.intensity = lumens;
      example.panelWidth = _number('ORBIS_PANEL_W') ?? example.panelWidth;
      example.panelHeight = _number('ORBIS_PANEL_H') ?? example.panelHeight;
      // Still, so two renders of the same angle are the same picture.
      if (Platform.environment['ORBIS_CIRCLING'] == '0') {
        example.orbiting = false;
      }
    }
    if (example is FieldExample) {
      example.intensity = _number('ORBIS_FIELD') ?? example.intensity;
      example.retention = _number('ORBIS_RETENTION') ?? example.retention;
      if (Platform.environment['ORBIS_FIELD_OFF'] == '1') example.on = false;
    }
    if (example is BatchingExample) {
      example.count = _number('ORBIS_CRATES') ?? example.count;
      example.palette = Platform.environment['ORBIS_PALETTE'] ?? example.palette;
      if (Platform.environment['ORBIS_BATCH_MATERIAL'] == '1') {
        example.material = true;
      }
      final mesh = Platform.environment['ORBIS_BATCH_MESH'];
      if (mesh != null && mesh.isNotEmpty) example.mesh = mesh;
      if (Platform.environment['ORBIS_MOVING'] == '0') example.moving = false;
    }
    if (example is OverdrawExample) {
      example.slabs = _number('ORBIS_SLABS') ?? example.slabs;
    }
    if (example is BounceExample) {
      example.strength = _number('ORBIS_BOUNCE') ?? example.strength;
      example.reach = _number('ORBIS_BOUNCE_RADIUS') ?? example.reach;
      if (Platform.environment['ORBIS_BOUNCE_OFF'] == '1') example.on = false;
    }
    if (example is DecalsExample) {
      final environment = Platform.environment;
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
      if (Platform.environment['ORBIS_VOLUMES_OFF'] == '1') {
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
        stderr.writeln(
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
      if (Platform.environment['ORBIS_OUTLINE'] == '0') example.on = false;
      if (Platform.environment['ORBIS_OUTLINE_OTHERS'] == '0') {
        example.others = false;
      }
      example.width = _number('ORBIS_OUTLINE_WIDTH') ?? example.width;
      final hidden = Platform.environment['ORBIS_OUTLINE_HIDDEN'];
      if (hidden != null && hidden.isNotEmpty) {
        example.occluded = OrbisOccluded.values.byName(hidden);
      }
      final aa = Platform.environment['ORBIS_AA'];
      if (aa != null && aa.isNotEmpty) {
        example.antiAliasing = AntiAliasing.values.byName(aa);
      }
    }

    if (example is SplatsExample) {
      final capture = Platform.environment['ORBIS_SPLAT'];
      if (capture != null && capture.isNotEmpty) example.path = capture;
      example.count = _number('ORBIS_SPLAT_COUNT')?.round() ?? example.count;
      if (Platform.environment['ORBIS_SPLAT_SORT'] == '0') {
        example.sorted = false;
      }
      if (Platform.environment['ORBIS_SPLAT_PILLAR'] == '0') {
        example.pillar = false;
      }
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
        scene: switch (Platform.environment['ORBIS_MESH']) {
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
