import 'dart:typed_data';

/// What a pass draws into, when it is not drawing into the frame.
///
/// A named image the renderer keeps between passes: the scene from a mirror's
/// point of view, a depth buffer an outline is traced from, a thumbnail. It is
/// a declaration rather than an allocation — the renderer makes it when
/// something writes it, keeps it while something reads it, and drops it when
/// nothing does.
class OrbisTarget {
  const OrbisTarget({
    required this.name,
    this.width = 0,
    this.height = 0,
    this.scale = 1.0,
    this.depth = true,
    this.colour = true,
  });

  /// What passes call it. Unique within a graph.
  final String name;

  /// Its size in pixels, or zero to follow the view's own size.
  ///
  /// Following is the right default and the one most passes want: a reflection
  /// or a depth buffer that did not resize with the window would be sampled at
  /// the wrong scale from the first drag of its corner.
  final int width;
  final int height;

  /// A fraction of the view's size, applied when [width] and [height] are
  /// zero.
  ///
  /// Half-resolution is the usual answer for anything blurred afterwards —
  /// reflections, occlusion — and costs a quarter of the pixels.
  final double scale;

  /// Whether it keeps depth, and whether it keeps colour.
  ///
  /// A depth prepass writes depth and no colour; a purely two-dimensional
  /// overlay writes colour and no depth. Both would otherwise pay for a buffer
  /// nothing reads.
  final bool depth;
  final bool colour;

  OrbisTarget copyWith({
    String? name,
    int? width,
    int? height,
    double? scale,
    bool? depth,
    bool? colour,
  }) => OrbisTarget(
    name: name ?? this.name,
    width: width ?? this.width,
    height: height ?? this.height,
    scale: scale ?? this.scale,
    depth: depth ?? this.depth,
    colour: colour ?? this.colour,
  );

  @override
  String toString() => 'OrbisTarget($name)';
}

/// What a pass is for.
///
/// Not a free-form shader hook. Each kind is something the renderer already
/// knows how to do, and the graph decides how many of them there are, in what
/// order, and against which targets — which is the part that changes from
/// scene to scene. A kind nobody has implemented cannot be declared, so a
/// graph that schedules is a graph that draws.
///
/// Short on purpose, and it will stay short until each addition is a pass
/// that actually runs. A list of kinds longer than the list of things the
/// renderer does is a list where declaring a pass and getting nothing is a
/// normal outcome, and there is no way for a host to tell that from a bug.
/// The screen-space effects the renderer knows how to run.
///
/// Each is a compiled shader inside the renderer, so this list is what exists
/// rather than what a host can invent.
enum OrbisEffect {
  /// Puts back the edge the anti-aliasing took off.
  ///
  /// Temporal anti-aliasing works by spreading a pixel's history over several
  /// frames, and the cost of that is a softer picture — the sharpest thing a
  /// TAA image can be is slightly blurred. This is the usual answer: a small
  /// contrast-adaptive sharpen afterwards, which lifts detail back without
  /// ringing the way a plain unsharp mask does, because how much it applies
  /// depends on how much local contrast is already there.
  sharpen('Sharpen'),

  /// SMAA, pass one: where the edges are.
  ///
  /// Enhanced subpixel morphological anti-aliasing works on the finished
  /// image, like FXAA, but instead of guessing at an edge and blurring along
  /// it, it works out the *shape* the edge belongs to and blends by how much
  /// of the pixel that shape covers. No history, so unlike temporal it cannot
  /// smear; no guess, so unlike FXAA it does not soften what it should leave
  /// alone.
  ///
  /// Three passes, chained: this one writes a picture of the edges, which
  /// [smaaWeights] reads.
  smaaEdges('SMAA edges'),

  /// SMAA, pass two: how much of each pixel the edge covers.
  ///
  /// Walks along each edge to find the shape it belongs to and looks that
  /// shape's coverage up in a precomputed table. Reads what [smaaEdges] wrote.
  smaaWeights('SMAA weights'),

  /// SMAA, pass three: the blend itself.
  ///
  /// Mixes each pixel with its neighbour by the weight pass two decided.
  /// Reads the original image *and* the weights, in that order, so a graph
  /// lists both in [OrbisPass.reads].
  smaaBlend('SMAA blend');

  const OrbisEffect(this.label);

  final String label;
}

enum OrbisPassKind {
  /// Everything the scene contains, lit, from the scene's own camera.
  ///
  /// Into the frame it is the ordinary picture; into a target it is a
  /// thumbnail, a security monitor, a portal, or the same world seen by
  /// another eye.
  scene('Scene'),

  /// The scene reflected in a plane — a mirror, still water.
  ///
  /// The same pass from a camera mirrored about [OrbisPass.plane], with the
  /// winding turned inside out because reflecting the world reverses which
  /// side of a triangle is facing.
  reflection('Reflection'),

  /// A material run over every pixel of what another pass drew, rather than a
  /// camera pointed at the world.
  ///
  /// The rails every screen-space effect runs on: it reads a target, writes a
  /// target, and draws one triangle covering the lot. Which effect it runs is
  /// [OrbisPass.effect].
  effect('Effect');

  const OrbisPassKind(this.label);

  final String label;
}

/// One step of a frame.
///
/// A pass says what it draws, where it draws it, and what it needs to have
/// been drawn first. The order it actually runs in is worked out from the last
/// of those rather than declared, because an order somebody maintains by hand
/// is an order that goes wrong the first time a pass is inserted in the middle
/// — and goes wrong silently, as a frame that samples a target from last
/// frame.
class OrbisPass {
  const OrbisPass({
    required this.name,
    this.kind = OrbisPassKind.scene,
    this.into,
    this.reads = const [],
    this.layers = 0xFF,
    this.enabled = true,
    this.clear = true,
    this.plane,
    this.effect,
  });

  /// What this pass is called, and what a capture reports it as. Unique
  /// within a graph.
  final String name;

  final OrbisPassKind kind;

  /// The target it writes, or null for the frame itself.
  ///
  /// Exactly one pass may write the frame. Two would mean the second
  /// overwriting the first, which is not a graph anybody meant to draw.
  final String? into;

  /// The targets it samples. What the schedule is worked out from.
  final List<String> reads;

  /// Which render layers it draws.
  ///
  /// A bitfield against [OrbisObject.layer]. This is what makes one scene
  /// serve several passes: a reflection that leaves out the water it is
  /// reflecting, a thumbnail without the editor's own gizmos, a shadow-only
  /// object that is never drawn directly.
  final int layers;

  /// Whether it happens at all. A pass switched off is skipped and everything
  /// that reads it gets whatever it held last, rather than the graph refusing
  /// to schedule.
  final bool enabled;

  /// Whether its target is cleared first.
  final bool clear;

  /// The mirror, for a reflection pass: a plane as `nx, ny, nz, d`.
  final List<double>? plane;

  /// Which screen-space effect this pass runs, for [OrbisPassKind.effect].
  ///
  /// One of a set the renderer knows rather than a material somebody wrote:
  /// an effect needs its own compiled shader, and compiling one at runtime is
  /// a different and much larger door than this.
  final OrbisEffect? effect;

  OrbisPass copyWith({
    String? name,
    OrbisPassKind? kind,
    String? into,
    List<String>? reads,
    int? layers,
    bool? enabled,
    bool? clear,
    List<double>? plane,
    OrbisEffect? effect,
  }) => OrbisPass(
    name: name ?? this.name,
    kind: kind ?? this.kind,
    into: into ?? this.into,
    reads: reads ?? this.reads,
    layers: layers ?? this.layers,
    enabled: enabled ?? this.enabled,
    clear: clear ?? this.clear,
    plane: plane ?? this.plane,
    effect: effect ?? this.effect,
  );

  @override
  String toString() => 'OrbisPass($name → ${into ?? 'frame'})';
}

/// Something a graph says that the renderer cannot do.
///
/// Reported rather than thrown. A graph is edited a pass at a time, and half
/// of the intermediate states are incomplete — a target named before it is
/// declared, a read added before the pass that writes it. Refusing to draw at
/// each of those is an editor that goes black while somebody types.
class OrbisGraphProblem {
  const OrbisGraphProblem(this.pass, this.what);

  /// The pass it is about, or the empty string for the graph as a whole.
  final String pass;

  final String what;

  @override
  String toString() => pass.isEmpty ? what : '$pass: $what';
}

/// How a frame gets put together.
///
/// The passes, the targets between them, and the order that falls out of what
/// each one reads. [OrbisPipeline] says how much of each step happens; this
/// says which steps there are.
///
/// The default is one pass into the frame, which is exactly what the renderer
/// did before there was a graph — so a host that never mentions one draws the
/// same frame it always drew, and nothing pays for the generality until it is
/// used.
class OrbisRenderGraph {
  const OrbisRenderGraph({this.passes = const [], this.targets = const []});

  /// The frame as it was before anything else was possible: everything, lit,
  /// straight into the picture.
  factory OrbisRenderGraph.standard() =>
      const OrbisRenderGraph(passes: [OrbisPass(name: 'scene')]);

  final List<OrbisPass> passes;
  final List<OrbisTarget> targets;

  /// The most passes a graph may hold.
  ///
  /// A limit rather than none, because every pass is a view and a target the
  /// renderer allocates, and a graph built in a loop that ran away should hit
  /// something that names the problem rather than the memory ceiling.
  static const int maxPasses = 32;

  OrbisRenderGraph copyWith({
    List<OrbisPass>? passes,
    List<OrbisTarget>? targets,
  }) => OrbisRenderGraph(
    passes: passes ?? this.passes,
    targets: targets ?? this.targets,
  );

  OrbisRenderGraph with_(OrbisPass pass) => copyWith(passes: [...passes, pass]);

  OrbisRenderGraph withTarget(OrbisTarget target) =>
      copyWith(targets: [...targets, target]);

  /// The passes that will run, in the order they will run in.
  ///
  /// A pass that writes a target comes before every pass that reads it. Among
  /// passes that do not depend on each other, the order they were declared in
  /// is kept: two independent passes have no correct order, and the one
  /// somebody wrote down is the one they will expect to see in a capture.
  ///
  /// The pass that writes the frame is last whatever it depends on, because
  /// the frame is what everything else was for.
  ///
  /// Empty when the graph cannot be scheduled at all; [problems] says why.
  List<OrbisPass> get schedule {
    if (problems.any((problem) => problem.pass.isEmpty)) return const [];

    final running = [
      for (final pass in passes)
        if (pass.enabled) pass,
    ];
    final writers = <String, String>{
      for (final pass in running)
        if (pass.into != null) pass.into!: pass.name,
    };

    final done = <String>{};
    final ordered = <OrbisPass>[];
    var remaining = [...running];

    while (remaining.isNotEmpty) {
      final ready = [
        for (final pass in remaining)
          if (pass.into != null &&
              pass.reads.every(
                (read) => !writers.containsKey(read) || done.contains(read),
              ))
            pass,
      ];

      // Nothing can go next and something is left: the passes still waiting
      // are waiting on each other. Reported by [problems]; here it simply
      // stops rather than looping.
      if (ready.isEmpty) break;

      for (final pass in ready) {
        ordered.add(pass);
        if (pass.into != null) done.add(pass.into!);
      }
      remaining = [
        for (final pass in remaining)
          if (!ready.contains(pass)) pass,
      ];
    }

    // The one that draws the picture, after everything that fed it.
    final frame = [
      for (final pass in running)
        if (pass.into == null) pass,
    ];
    return [...ordered, ...frame];
  }

  /// Everything wrong with this graph.
  ///
  /// A problem naming a pass is that pass being dropped; a problem naming no
  /// pass is the graph as a whole failing to schedule, and nothing running.
  List<OrbisGraphProblem> get problems {
    final found = <OrbisGraphProblem>[];

    if (passes.length > maxPasses) {
      found.add(OrbisGraphProblem('', 'more than $maxPasses passes'));
    }

    final declared = {for (final target in targets) target.name};
    final names = <String>{};
    final written = <String>{};
    var frames = 0;

    for (final pass in passes) {
      if (!names.add(pass.name)) {
        found.add(OrbisGraphProblem(pass.name, 'two passes with this name'));
      }
      if (pass.into == null) {
        frames++;
      } else {
        if (!declared.contains(pass.into)) {
          found.add(
            OrbisGraphProblem(
              pass.name,
              'writes ${pass.into}, which is not '
              'a target of this graph',
            ),
          );
        }
        if (!written.add(pass.into!)) {
          found.add(
            OrbisGraphProblem(
              pass.name,
              'writes ${pass.into}, which another '
              'pass already writes',
            ),
          );
        }
      }
      for (final read in pass.reads) {
        if (!declared.contains(read)) {
          found.add(
            OrbisGraphProblem(
              pass.name,
              'reads $read, which is not a target '
              'of this graph',
            ),
          );
        }
      }
      if (pass.reads.contains(pass.into)) {
        found.add(OrbisGraphProblem(pass.name, 'reads the target it writes'));
      }
      if (pass.kind == OrbisPassKind.reflection && pass.plane == null) {
        found.add(
          OrbisGraphProblem(
            pass.name,
            'is a reflection with no plane to '
            'reflect in',
          ),
        );
      }
    }

    if (frames == 0 && passes.isNotEmpty) {
      found.add(OrbisGraphProblem('', 'no pass draws the frame'));
    }
    if (frames > 1) {
      found.add(
        OrbisGraphProblem(
          '',
          '$frames passes draw the frame; the second '
              'would only overwrite the first',
        ),
      );
    }

    // A cycle is what is left when the ordering runs out of passes it can
    // place. Worked out here rather than in [schedule] so that schedule can
    // stay the answer to "what runs" and this stays the answer to "why not".
    final enabled = [
      for (final pass in passes)
        if (pass.enabled && pass.into != null) pass,
    ];
    final writers = <String, String>{
      for (final pass in enabled) pass.into!: pass.name,
    };
    final settled = <String>{};
    var moved = true;
    while (moved) {
      moved = false;
      for (final pass in enabled) {
        if (settled.contains(pass.into)) continue;
        if (pass.reads.every(
          (read) => !writers.containsKey(read) || settled.contains(read),
        )) {
          settled.add(pass.into!);
          moved = true;
        }
      }
    }
    for (final pass in enabled) {
      if (!settled.contains(pass.into)) {
        found.add(
          OrbisGraphProblem(pass.name, 'waits on a pass that waits on it'),
        );
      }
    }

    return found;
  }

  /// Whether every pass can run.
  bool get isRunnable => problems.isEmpty;

  /// The targets nothing reads.
  ///
  /// Not an error — a pass may be drawing into a target for a host to pick up
  /// itself, and a graph half-built has them constantly. Worth surfacing in an
  /// editor, because the commonest reason a reflection does not appear is that
  /// the pass that should sample it does not.
  List<String> get unreadTargets {
    final read = {for (final pass in passes) ...pass.reads};
    return [
      for (final target in targets)
        if (!read.contains(target.name)) target.name,
    ];
  }

  /// How many floats each pass takes on the wire.
  static const int passStride = 13;

  /// How many floats each target takes.
  static const int targetStride = 6;

  /// The scheduled passes, in the order the renderer runs them.
  ///
  /// Targets travel as indices into [packedTargets] rather than as names: the
  /// names are for people, and a renderer that had to match strings on every
  /// frame would be matching the same strings sixty times a second.
  Float32List get packedPasses {
    final running = schedule;
    final index = <String, int>{
      for (var i = 0; i < targets.length; i++) targets[i].name: i,
    };

    final out = Float32List(running.length * passStride);
    for (var i = 0; i < running.length; i++) {
      final pass = running[i];
      final at = i * passStride;
      out[at] = pass.kind.index.toDouble();
      out[at + 1] = (pass.into == null ? -1 : index[pass.into] ?? -1)
          .toDouble();
      out[at + 2] = pass.layers.toDouble();
      out[at + 3] = pass.clear ? 1 : 0;
      // Up to four reads, which is more than any pass here needs and few
      // enough to keep the row a fixed width.
      for (var r = 0; r < 4; r++) {
        out[at +
            4 +
            r] = (r < pass.reads.length ? index[pass.reads[r]] ?? -1 : -1)
            .toDouble();
      }
      final plane = pass.plane;
      for (var p = 0; p < 4; p++) {
        out[at + 8 + p] = plane != null && p < plane.length ? plane[p] : 0;
      }
      // Its own slot rather than sharing the plane's, which a reflection uses
      // and an effect does not. A field that means two things by the value of
      // another is a field somebody reads wrong once and never finds out.
      out[at + 12] = (pass.effect?.index ?? -1).toDouble();
    }
    return out;
  }

  Float32List get packedTargets {
    final out = Float32List(targets.length * targetStride);
    for (var i = 0; i < targets.length; i++) {
      final target = targets[i];
      final at = i * targetStride;
      out[at] = target.width.toDouble();
      out[at + 1] = target.height.toDouble();
      out[at + 2] = target.scale;
      out[at + 3] = target.depth ? 1 : 0;
      out[at + 4] = target.colour ? 1 : 0;
      out[at + 5] = 0;
    }
    return out;
  }
}

/// What one pass cost, the last time the frame was drawn.
class OrbisPassTiming {
  const OrbisPassTiming({
    required this.name,
    required this.milliseconds,
    required this.draws,
  });

  final String name;

  /// What it cost, in milliseconds.
  final double milliseconds;

  /// How many draw calls it submitted.
  final int draws;

  @override
  String toString() =>
      '$name ${milliseconds.toStringAsFixed(2)}ms, $draws draws';
}

/// What actually happened in a frame.
///
/// The point of declaring passes rather than hard-coding them: a frame that
/// says what it did can be looked at. Which passes ran, in what order, what
/// each cost — the three questions asked of a renderer that is too slow, and
/// the three a fixed pipeline cannot answer without being instrumented by
/// hand every time somebody asks.
class OrbisFrameCapture {
  const OrbisFrameCapture({this.passes = const [], this.milliseconds = 0});

  final List<OrbisPassTiming> passes;

  /// What the whole frame cost.
  final double milliseconds;

  /// Reads a capture out of what the renderer sent back.
  ///
  /// Two floats per pass — what it cost and how many draws it made — in the
  /// order the passes were scheduled, so the names come from this side rather
  /// than crossing as strings sixty times a second.
  factory OrbisFrameCapture.from(Float32List packed, List<String> names) {
    final passes = <OrbisPassTiming>[];
    for (var i = 0; i < names.length && i * 2 + 1 < packed.length; i++) {
      passes.add(
        OrbisPassTiming(
          name: names[i],
          milliseconds: packed[i * 2],
          draws: packed[i * 2 + 1].round(),
        ),
      );
    }
    return OrbisFrameCapture(
      passes: passes,
      milliseconds: passes.fold(0.0, (sum, pass) => sum + pass.milliseconds),
    );
  }

  /// The pass that cost the most, or null if nothing ran.
  OrbisPassTiming? get slowest {
    if (passes.isEmpty) return null;
    var worst = passes.first;
    for (final pass in passes) {
      if (pass.milliseconds > worst.milliseconds) worst = pass;
    }
    return worst;
  }

  int get draws => passes.fold(0, (sum, pass) => sum + pass.draws);
}
