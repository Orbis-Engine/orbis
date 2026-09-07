import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_camera/orbis_camera.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Cameras as shots, and the rules they frame by drawn over the frame.
///
/// There is one real camera. These are descriptions of what it should be
/// doing, and the brain picks between them: cutting to a different angle is
/// raising a number, not moving anything. Nothing outside the camera library
/// touches a transform, which is what stops two systems fighting over it —
/// the failure that makes cameras the worst part of most codebases.
///
/// The overlay is the other half. A composer's rules are invisible, and that
/// is the trouble with them: tuning a shot means moving numbers and guessing
/// what they mean. Drawn over the frame, the dead zone is where the camera
/// holds still and the soft zone is where it eases after the subject, and both
/// are something to look at rather than something to work out.
class CamerasExample extends Example {
  CamerasExample() {
    _brain
      ..add(_chase)
      ..add(_eyes)
      ..add(_flat)
      ..add(_watchtower)
      ..add(_orbit)
      ..snap();
  }

  @override
  String get name => 'Virtual cameras';

  @override
  String get blurb =>
      'Third person, first person and flat, blended between, framing drawn.';

  @override
  ViewPoint get viewpoint => const ViewPoint(distance: 22, pitch: 0.4);

  /// What everything is looking at. Moved along its own path each frame.
  final FixedTarget _subject = FixedTarget(Vector3.zero());

  late final ComposerAim _chaseAim = ComposerAim(
    screenY: 0.45,
    deadZoneWidth: 0.08,
    deadZoneHeight: 0.10,
    softZoneWidth: 0.35,
    softZoneHeight: 0.30,
    damping: 0.4,
  );

  late final ComposerAim _towerAim = ComposerAim(
    screenX: 0.35,
    screenY: 0.4,
    deadZoneWidth: 0.05,
    deadZoneHeight: 0.06,
    softZoneWidth: 0.30,
    softZoneHeight: 0.25,
    damping: 0.8,
  );

  late final VirtualCamera _chase = VirtualCamera(
    name: 'Chase',
    priority: 20,
    follow: _subject,
    lookAt: _subject,
    // Behind and above, in the subject's own frame, so it stays behind when
    // the subject turns rather than staying north of it.
    // Per axis, because the axes want different answers: a camera may
    // lag a long way behind and must not float up and down.
    body: FollowBody(
      offset: Vector3(0, 2.4, 7),
      damping: Vector3(0.35, 0.18, 0.5),
    ),
    aim: _chaseAim,
    lens: const Lens(fieldOfView: 55),
  );

  late final VirtualCamera _watchtower = VirtualCamera(
    name: 'Watchtower',
    priority: 10,
    lookAt: _subject,
    body: StaticBody(Vector3(-16, 9, 16)),
    aim: _towerAim,
    lens: const Lens(fieldOfView: 38),
  );

  /// First person: on the subject's own head, looking where it looks.
  ///
  /// Nothing composes, nothing damps and nothing frames. Any of those would
  /// put the view somewhere other than where the character is looking, which
  /// is the one thing a first-person camera may never do.
  late final VirtualCamera _eyes = VirtualCamera(
    name: 'First person',
    priority: 10,
    follow: _subject,
    lookAt: _subject,
    body: FollowBody(
      offset: Vector3(0, 0.75, -0.2),
      binding: FollowBinding.targetRotation,
      damping: Vector3.zero(),
    ),
    aim: HeadAim(),
    lens: const Lens(fieldOfView: 70),
  );

  /// A game seen flat on, from above. Framed by moving, because turning an
  /// orthographic view does not move anything through the frame.
  late final ScreenFollowBody _flatBody = ScreenFollowBody(
    distance: 40,
    screenY: 0.55,
    deadZoneWidth: 0.12,
    deadZoneHeight: 0.16,
    softZoneWidth: 0.38,
    softZoneHeight: 0.35,
    damping: 0.35,
    // A level has edges, and a camera that follows a character over one shows
    // whatever is past it.
    bounds: (minimum: Vector3(-6, 30, -6), maximum: Vector3(6, 50, 22)),
  );

  late final VirtualCamera _flat = VirtualCamera(
    name: 'Flat',
    priority: 10,
    follow: _subject,
    lookAt: _subject,
    body: _flatBody,
    // Looking straight down, level with the world's own axes.
    aim: StaticAim(lookRotation(Vector3(0, -1, -0.0001))),
    lens: const Lens.flat(height: 26),
  );

  late final VirtualCamera _orbit = VirtualCamera(
    name: 'Orbit',
    priority: 10,
    follow: _subject,
    lookAt: _subject,
    body: OrbitBody(radius: 11, elevation: 26, damping: 0.5),
    aim: HardLookAt(),
    lens: const Lens(fieldOfView: 48),
  );

  final CameraBrain _brain = CameraBrain(
    blends: BlendTable(defaultBlend: const Blend(BlendStyle.easeInOut, 0.9)),
  );

  String live = 'Chase';
  double blendSeconds = 0.9;
  BlendStyle blendStyle = BlendStyle.easeInOut;
  bool showGuides = true;
  double _lastSeconds = 0;

  /// Where the subject is at this moment, on a figure of eight.
  ///
  /// A path rather than a straight line, because a camera that never has to
  /// turn round shows nothing about how it turns round.
  Vector3 _pathAt(double seconds) {
    final t = seconds * 0.45;
    return Vector3(math.sin(t) * 9, 0, math.sin(t * 2) * 5.5);
  }

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final delta = (seconds - _lastSeconds).clamp(0.0, 0.1);
    _lastSeconds = seconds;

    // The subject moves, and its heading is where it is going — which is what
    // a chase camera binds to.
    final at = _pathAt(seconds);
    final ahead = _pathAt(seconds + 0.12);
    _subject
      ..position = at
      ..rotation = lookRotation(ahead - at, null);

    _brain.blends.defaultBlend = Blend(blendStyle, blendSeconds);
    for (final camera in [_chase, _eyes, _flat, _watchtower, _orbit]) {
      camera.priority = camera.name == live ? 20 : 10;
    }

    _brain.update(delta);

    return OrbisScene(
      objects: [
        // The subject.
        OrbisObject(
          key: 700,
          transform: Matrix4.compose(
            at + Vector3(0, 0.8, 0),
            _subject.rotation,
            Vector3(0.5, 0.8, 0.9),
          ),
          colour: linearOf(const Color(0xFFD9633B)),
        ),
        // Something to move past, so the motion reads as motion.
        for (var i = 0; i < 14; i++)
          OrbisObject(
            key: 710 + i,
            transform: Matrix4.identity()
              ..setTranslation(
                Vector3(
                  math.cos(i * 0.9) * (7 + (i % 4) * 3.5),
                  0.9 + (i % 3) * 0.7,
                  math.sin(i * 1.7) * (7 + (i % 5) * 2.5),
                ),
              )
              ..rotateY(i * 0.7)
              ..scaleByDouble(0.7, 0.9 + (i % 3) * 0.7, 0.7, 1),
            colour: linearOf(
              Color.lerp(
                const Color(0xFF5B6470),
                const Color(0xFF8B94A0),
                (i % 5) / 4,
              )!,
            ),
          ),
        OrbisObject(
          key: 690,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -0.1, 0))
            ..scaleByDouble(40.0, 0.06, 40.0, 1),
          colour: linearOf(const Color(0xFF3C424A)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 760,
          kind: OrbisLightKind.directional,
          intensity: 76000,
          direction: Vector3(-0.4, -0.9, -0.35)..normalize(),
          colour: linearOf(const Color(0xFFFFF3E0)),
          sunAngularRadius: 0.6,
        ),
      ],
      sky: OrbisSky(
        colour: linearOf(const Color(0xFF6E8DB4)),
        zenith: linearOf(const Color(0xFF2F5F97)),
        horizon: linearOf(const Color(0xFFB9CBDD)),
        ambient: 24000,
        bodyDirection: Vector3(0.4, 0.9, 0.35)..normalize(),
        bodyColour: linearOf(const Color(0xFFFFF6E8)),
        bodySize: 0.011,
        clouds: OrbisClouds.cumulus(cover: 0.28, wind: Vector2(4, 1.5)),
      ),
      // The brain's answer, not the orbit camera the other examples use. That
      // is the whole point: nothing here moves the camera by hand.
      camera: _asRenderCamera(),
    );
  }

  /// The brain's state, as the renderer takes a camera.
  OrbisCamera _asRenderCamera() {
    final state = _brain.state;
    return OrbisCamera(
      position: state.position,
      // A renderer wants somewhere to look; a camera has a rotation. One metre
      // along its own forward is the same thing said the other way.
      target: state.position + state.forward,
      fieldOfView: state.lens.fieldOfView,
      orthographic: state.lens.orthographic,
      viewHeight: state.lens.height,
    );
  }

  @override
  Widget? overlay(BuildContext context, VoidCallback changed) {
    if (!showGuides) return null;

    final camera = _brain.live;
    // From whichever of the two is framing: a camera frames by turning or by
    // moving, and which one depends on the shot.
    final guides = camera?.guides;
    if (guides == null) return null;

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final aspect = constraints.maxWidth / constraints.maxHeight;
          _brain.aspect = aspect;

          // Where the subject actually is on screen this frame, which is what
          // makes the zones legible: a marker sitting still inside the dead
          // box while the world slides past is the rule doing its work.
          final seen = project(
            _brain.state.position,
            _brain.state.rotation,
            _subject.position,
            lens: _brain.state.lens,
            aspect: aspect,
          );

          return CustomPaint(
            painter: _GuidePainter(
              guides: guides,
              subject: seen.inFront
                  ? Offset((seen.x + 1) / 2, (1 - seen.y) / 2)
                  : null,
              blending: _brain.isBlending,
              label: camera!.name,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Choice(
          label: 'Live',
          options: const ['Chase', 'First person', 'Flat'],
          selected: const ['Chase', 'First person', 'Flat'].contains(live)
              ? live
              : '',
          onSelect: (option) {
            live = option;
            changed();
          },
        ),
        Choice(
          label: '',
          options: const ['Watchtower', 'Orbit'],
          selected: live == 'Watchtower' || live == 'Orbit' ? live : '',
          onSelect: (option) {
            live = option;
            changed();
          },
        ),
        Choice(
          label: 'Blend',
          options: const ['Cut', 'Linear', 'Ease'],
          selected: switch (blendStyle) {
            BlendStyle.cut => 'Cut',
            BlendStyle.linear => 'Linear',
            _ => 'Ease',
          },
          onSelect: (option) {
            blendStyle = switch (option) {
              'Cut' => BlendStyle.cut,
              'Linear' => BlendStyle.linear,
              _ => BlendStyle.easeInOut,
            };
            changed();
          },
        ),
        if (blendStyle != BlendStyle.cut)
          Setting(
            label: 'Blend time',
            value: blendSeconds,
            min: 0.1,
            max: 3,
            unit: ' s',
            onChanged: (value) {
              blendSeconds = value;
              changed();
            },
          ),
        Toggle(
          label: 'Show framing',
          value: showGuides,
          onChanged: (value) {
            showGuides = value;
            changed();
          },
        ),
        Setting(
          label: 'Dead zone',
          value: _chaseAim.deadZoneWidth,
          min: 0,
          max: 0.4,
          decimals: 2,
          onChanged: (value) {
            _chaseAim.deadZoneWidth = value;
            _chaseAim.deadZoneHeight = value * 1.2;
            changed();
          },
        ),
        Setting(
          label: 'Soft zone',
          value: _chaseAim.softZoneWidth,
          min: 0.05,
          max: 0.5,
          decimals: 2,
          onChanged: (value) {
            _chaseAim.softZoneWidth = value;
            _chaseAim.softZoneHeight = value * 0.85;
            changed();
          },
        ),
        Setting(
          label: 'Aim damping',
          value: _chaseAim.damping,
          min: 0,
          max: 2,
          decimals: 2,
          unit: ' s',
          onChanged: (value) {
            _chaseAim.damping = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// One real camera, and as many shots as the scene has situations. Cutting to
// a different angle is raising a number — nothing outside the library moves a
// transform, which is what stops two systems fighting over the camera.
final subject = FixedTarget(Vector3.zero());

final chase = VirtualCamera(
  name: 'Chase',
  priority: 20,
  follow: subject,
  lookAt: subject,
  // Behind and above in the subject's own frame, so it stays behind when the
  // subject turns rather than staying north of it.
  // Per axis, because the axes want different answers: a camera may
    // lag a long way behind and must not float up and down.
    body: FollowBody(
      offset: Vector3(0, 2.4, 7),
      damping: Vector3(0.35, 0.18, 0.5),
    ),
  aim: ComposerAim(
    screenY: 0.45,
    // Inside this, the camera holds still. A camera that corrects for every
    // twitch reads as a nervous operator rather than a steady one.
    deadZoneWidth: 0.08,
    deadZoneHeight: 0.10,
    // Between the two it eases after the subject; past the soft edge it is
    // dragged, because by then keeping them in frame matters more.
    softZoneWidth: 0.35,
    softZoneHeight: 0.30,
    damping: 0.4,
  ),
);

final brain = CameraBrain(
  blends: BlendTable(defaultBlend: Blend(BlendStyle.easeInOut, 0.9)),
)..add(chase)..add(watchtower)..add(orbit)..snap();

// Every frame: move the world, then ask what the camera should be doing.
brain.update(delta);

OrbisScene(
  camera: OrbisCamera(
    position: brain.state.position,
    target: brain.state.position + brain.state.forward,
    fieldOfView: brain.state.lens.fieldOfView,
  ),
  // ...
);

// And to show the rules rather than guess at them:
final guides = brain.live?.aim.guides;   // dead and soft, in fractions
''';
}

/// Draws the framing rules over the frame.
class _GuidePainter extends CustomPainter {
  const _GuidePainter({
    required this.guides,
    required this.subject,
    required this.blending,
    required this.label,
  });

  final CameraGuides guides;

  /// Where the subject is, in fractions of the frame, or null when it is
  /// behind the camera and cannot honestly be drawn anywhere.
  final Offset? subject;

  final bool blending;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    Rect toRect(ScreenRect rect) => Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );

    final soft = toRect(guides.soft);
    final dead = toRect(guides.dead);

    // Everything outside the soft zone is where the camera stops easing and
    // starts dragging. Tinted rather than outlined, because it is a region
    // and the region is the point.
    final beyond = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(soft),
    );
    canvas.drawPath(beyond, Paint()..color = const Color(0x22E0446A));

    canvas.drawRect(
      soft,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x88E0446A),
    );

    canvas.drawRect(dead, Paint()..color = const Color(0x1A54B6F0));
    canvas.drawRect(
      dead,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xCC54B6F0),
    );

    // Where the subject is meant to sit.
    final aim = Offset(
      guides.screenX * size.width,
      guides.screenY * size.height,
    );
    final cross = Paint()
      ..color = const Color(0x9954B6F0)
      ..strokeWidth = 1;
    canvas.drawLine(aim - const Offset(7, 0), aim + const Offset(7, 0), cross);
    canvas.drawLine(aim - const Offset(0, 7), aim + const Offset(0, 7), cross);

    // And where it actually is.
    if (subject case final where?) {
      final at = Offset(where.dx * size.width, where.dy * size.height);
      canvas.drawRect(
        Rect.fromCenter(center: at, width: 11, height: 11),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFF5D65B),
      );
    }

    final text = TextPainter(
      text: TextSpan(
        text: blending ? '$label  ·  blending' : label,
        style: const TextStyle(
          color: Color(0xDDFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, const Offset(12, 10));
  }

  @override
  bool shouldRepaint(_GuidePainter old) => true;
}
