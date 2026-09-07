import 'dart:math' as math;

import 'package:orbis_camera/orbis_camera.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

const lens = Lens(fieldOfView: 60);
const aspect = 16 / 9;

Matcher near(double value, [double tolerance = 1e-6]) =>
    closeTo(value, tolerance);

void main() {
  _guideTests();
  _flatTests();
  _headTests();
  _robustnessTests();

  group('rotation maths', () {
    test('a camera looking down -Z has that as its forward', () {
      final rotation = lookRotation(Vector3(0, 0, -1));
      final forward = rotateVector(rotation, Vector3(0, 0, -1));
      expect(forward.x, near(0, 1e-9));
      expect(forward.z, near(-1, 1e-9));
    });

    test('looking at a point turns the camera towards it', () {
      // Camera at the origin, target to its right.
      final rotation = lookRotation(Vector3(1, 0, 0));
      final forward = rotateVector(rotation, Vector3(0, 0, -1));
      expect(forward.x, near(1, 1e-9));
    });

    test('looking straight down does not produce a rolled camera', () {
      // Parallel to the up vector, the case that spikes if it is not handled.
      final rotation = lookRotation(Vector3(0, -1, 0));
      final forward = rotateVector(rotation, Vector3(0, 0, -1));
      expect(forward.y, near(-1, 1e-6));
      expect(forward.length, near(1, 1e-9));
    });

    test('a blend takes the short way round', () {
      // Almost a full turn one way is a small turn the other. Halfway along
      // the short arc the camera still faces roughly where it started; halfway
      // along the long one it would be facing behind itself.
      final a = Quaternion.axisAngle(Vector3(0, 1, 0), 0);
      final b = Quaternion.axisAngle(Vector3(0, 1, 0), math.pi * 2 - 0.175);

      final half = slerpShortest(a, b, 0.5);
      final forward = rotateVector(half, Vector3(0, 0, -1));

      expect(
        forward.z,
        lessThan(0),
        reason: 'the long way round would have turned it to face +Z',
      );
      expect(
        forward.x.abs(),
        lessThan(0.2),
        reason: 'and only a few degrees off, not most of a turn',
      );
    });
  });

  group('projection', () {
    test('a target dead ahead lands at the centre', () {
      final seen = project(
        Vector3(0, 0, 5),
        lookRotation(Vector3(0, 0, -1)),
        Vector3.zero(),
        lens: lens,
        aspect: aspect,
      );
      expect(seen.inFront, isTrue);
      expect(seen.x, near(0, 1e-9));
      expect(seen.y, near(0, 1e-9));
    });

    test('a target behind the camera is reported as behind', () {
      final seen = project(
        Vector3(0, 0, 5),
        lookRotation(Vector3(0, 0, -1)),
        Vector3(0, 0, 20),
        lens: lens,
        aspect: aspect,
      );
      expect(
        seen.inFront,
        isFalse,
        reason:
            'projection folds over behind the camera, so a point there '
            'would otherwise be reported at a plausible screen position',
      );
    });

    test('placing a point puts it exactly where it was asked for', () {
      // The round trip that says the whole composer is trustworthy: if solving
      // for a screen position and then projecting does not agree, every dead
      // zone in the engine is subtly wrong.
      final camera = Vector3.zero();
      for (final ndc in [(0.0, 0.0), (0.3, -0.2), (-0.6, 0.45), (0.9, 0.9)]) {
        final target = Vector3(2, 1, -8);
        final rotation = rotationPlacing(
          camera,
          target,
          ndcX: ndc.$1,
          ndcY: ndc.$2,
          lens: lens,
          aspect: aspect,
        );
        final seen = project(
          camera,
          rotation,
          target,
          lens: lens,
          aspect: aspect,
        );

        expect(seen.inFront, isTrue);
        expect(seen.x, near(ndc.$1, 1e-6), reason: 'x for $ndc');
        expect(seen.y, near(ndc.$2, 1e-6), reason: 'y for $ndc');
      }
    });
  });

  group('damping', () {
    test('closes most of the gap over its stated time', () {
      // A damping of one second should be most of the way there after one.
      expect(dampingFactor(1, 1), closeTo(0.632, 0.001));
    });

    test('lands in the same place at any framerate', () {
      // The property that matters: a camera must not drift when the machine
      // is busy, or the bug is unreproducible by definition.
      var coarse = 0.0;
      for (var i = 0; i < 30; i++) {
        coarse = damp(coarse, 10, 0.5, 1 / 30);
      }
      var fine = 0.0;
      for (var i = 0; i < 240; i++) {
        fine = damp(fine, 10, 0.5, 1 / 240);
      }
      expect(coarse, closeTo(fine, 0.02));
    });

    test('zero damping arrives immediately', () {
      expect(damp(0, 10, 0, 1 / 60), 10);
    });
  });

  group('lenses', () {
    test('field of view blends logarithmically', () {
      // Halfway between 20 and 80 degrees is 40, not 50: the perceived change
      // is multiplicative, and a linear blend reads as an accelerating zoom.
      final middle = Lens.lerp(
        const Lens(fieldOfView: 20),
        const Lens(fieldOfView: 80),
        0.5,
      );
      expect(middle.fieldOfView, closeTo(40, 0.001));
    });
  });

  group('bodies', () {
    test('a follow camera reaches its offset', () {
      final body = FollowBody(
        offset: Vector3(0, 2, 6),
        damping: Vector3.zero(),
      );
      final target = FixedTarget(Vector3(10, 0, 0));
      final position = body.solve(
        Vector3.zero(),
        target,
        rotation: Quaternion.identity(),
        lens: const Lens(),
        aspect: 16 / 9,
        delta: 1 / 60,
      );
      expect(position.x, near(10, 1e-6));
      expect(position.y, near(2, 1e-6));
      expect(position.z, near(6, 1e-6));
    });

    test('damping makes it arrive late rather than not at all', () {
      final body = FollowBody(
        offset: Vector3(0, 0, 5),
        damping: Vector3.all(0.5),
      );
      final target = FixedTarget(Vector3(100, 0, 0));

      var position = Vector3.zero();
      position = body.solve(
        position,
        target,
        rotation: Quaternion.identity(),
        lens: const Lens(),
        aspect: 16 / 9,
        delta: 1 / 60,
      );
      expect(position.x, greaterThan(0));
      expect(
        position.x,
        lessThan(100),
        reason: 'it should still be catching up',
      );

      for (var i = 0; i < 600; i++) {
        position = body.solve(
          position,
          target,
          rotation: Quaternion.identity(),
          lens: const Lens(),
          aspect: 16 / 9,
          delta: 1 / 60,
        );
      }
      expect(position.x, closeTo(100, 0.01), reason: 'and then get there');
    });

    test('heading binding ignores a target that is pitching', () {
      final body = FollowBody(
        offset: Vector3(0, 0, 5),
        binding: FollowBinding.targetHeading,
        damping: Vector3.zero(),
      );
      // Target tipped forwards; the camera should not tip with it.
      final target = FixedTarget(
        Vector3.zero(),
        Quaternion.axisAngle(Vector3(1, 0, 0), 0.6),
      );
      final position = body.solve(
        Vector3.zero(),
        target,
        rotation: Quaternion.identity(),
        lens: const Lens(),
        aspect: 16 / 9,
        delta: 1 / 60,
      );
      expect(
        position.y,
        near(0, 1e-6),
        reason:
            'a camera that tips when a character walks uphill is the '
            'classic third-person complaint',
      );
    });

    test('an orbit holds its radius', () {
      final body = OrbitBody(radius: 7, elevation: 30, damping: 0);
      final target = FixedTarget(Vector3(1, 2, 3));
      final position = body.solve(
        Vector3.zero(),
        target,
        rotation: Quaternion.identity(),
        lens: const Lens(),
        aspect: 16 / 9,
        delta: 1 / 60,
      );
      expect((position - target.position).length, closeTo(7, 1e-6));
    });
  });

  group('aiming', () {
    test('a hard look-at centres the target', () {
      final aim = const HardLookAt();
      final camera = Vector3(0, 0, 5);
      final target = FixedTarget(Vector3(3, 1, 0));

      final rotation = aim.solve(
        Quaternion.identity(),
        camera,
        target,
        lens: lens,
        aspect: aspect,
        delta: 1 / 60,
      );
      final seen = project(
        camera,
        rotation,
        target.position,
        lens: lens,
        aspect: aspect,
      );

      expect(seen.x, near(0, 1e-6));
      expect(seen.y, near(0, 1e-6));
    });

    test('a composer ignores movement inside the dead zone', () {
      final aim = ComposerAim(deadZoneWidth: 0.3, deadZoneHeight: 0.3);
      final camera = Vector3(0, 0, 5);

      // Start centred, then nudge the target a little.
      final centred = lookRotation(Vector3(0, 0, -1));
      final target = FixedTarget(Vector3(0.4, 0, 0));

      final rotation = aim.solve(
        centred,
        camera,
        target,
        lens: lens,
        aspect: aspect,
        delta: 1 / 60,
      );

      // The camera should not have moved: the whole point of a dead zone is
      // that small motion does not make the frame twitch.
      expect(rotation.x, near(centred.x, 1e-9));
      expect(rotation.y, near(centred.y, 1e-9));
      expect(rotation.z, near(centred.z, 1e-9));
    });

    test('a composer follows once the target leaves the dead zone', () {
      final aim = ComposerAim(
        deadZoneWidth: 0.1,
        deadZoneHeight: 0.1,
        damping: 0,
      );
      final camera = Vector3(0, 0, 5);
      final target = FixedTarget(Vector3(4, 0, 0));

      final rotation = aim.solve(
        lookRotation(Vector3(0, 0, -1)),
        camera,
        target,
        lens: lens,
        aspect: aspect,
        delta: 1 / 60,
      );
      final seen = project(
        camera,
        rotation,
        target.position,
        lens: lens,
        aspect: aspect,
      );

      // Brought back to the dead zone edge, not to the centre: the rectangle
      // describes where the subject may sit, not where it must.
      expect(seen.x, closeTo(0.1, 1e-4));
    });

    test('a composer never lets the target leave the soft zone', () {
      final aim = ComposerAim(
        deadZoneWidth: 0.05,
        deadZoneHeight: 0.05,
        softZoneWidth: 0.3,
        softZoneHeight: 0.3,
        // Heavy lag, so without the clamp the target would escape.
        damping: 10,
      );
      final camera = Vector3(0, 0, 5);
      final target = FixedTarget(Vector3(6, 0, 0));

      final rotation = aim.solve(
        lookRotation(Vector3(0, 0, -1)),
        camera,
        target,
        lens: lens,
        aspect: aspect,
        delta: 1 / 60,
      );
      final seen = project(
        camera,
        rotation,
        target.position,
        lens: lens,
        aspect: aspect,
      );

      expect(
        seen.x.abs(),
        lessThanOrEqualTo(0.3 + 1e-4),
        reason: 'the soft zone is a promise, not a preference',
      );
    });

    test('a composer recovers a target that got behind the camera', () {
      final aim = ComposerAim(damping: 0.5);
      final camera = Vector3.zero();
      final target = FixedTarget(Vector3(0, 0, 10));

      final rotation = aim.solve(
        lookRotation(Vector3(0, 0, -1)),
        camera,
        target,
        lens: lens,
        aspect: aspect,
        delta: 1 / 60,
      );
      final seen = project(
        camera,
        rotation,
        target.position,
        lens: lens,
        aspect: aspect,
      );

      expect(seen.inFront, isTrue);
      expect(seen.x, near(0, 1e-6));
    });

    test('a point-of-view aim clamps its pitch', () {
      final aim = PovAim(pitch: 300, maximumPitch: 85);
      final rotation = aim.solve(
        Quaternion.identity(),
        Vector3.zero(),
        null,
        lens: lens,
        aspect: aspect,
        delta: 1 / 60,
      );
      final forward = rotateVector(rotation, Vector3(0, 0, -1));
      // Clamped short of straight up, where the horizon would flip.
      expect(forward.y, lessThan(1.0));
    });
  });

  group('the brain', () {
    VirtualCamera camera(String name, int priority, Vector3 at) =>
        VirtualCamera(name: name, priority: priority, position: at);

    test('picks the highest priority', () {
      final brain = CameraBrain();
      brain
        ..add(camera('wide', 10, Vector3(0, 0, 20)))
        ..add(camera('close', 20, Vector3(0, 0, 2)))
        ..update(1 / 60);

      expect(brain.live?.name, 'close');
      expect(brain.state.position.z, closeTo(2, 1e-6));
    });

    test('a disabled camera is not chosen however high its priority', () {
      final brain = CameraBrain();
      final close = camera('close', 100, Vector3(0, 0, 2))..enabled = false;
      brain
        ..add(camera('wide', 10, Vector3(0, 0, 20)))
        ..add(close)
        ..update(1 / 60);

      expect(brain.live?.name, 'wide');
    });

    test('raising a priority is how you cut', () {
      final brain = CameraBrain(
        blends: BlendTable(defaultBlend: const Blend.cut()),
      );
      final wide = camera('wide', 10, Vector3(0, 0, 20));
      final close = camera('close', 5, Vector3(0, 0, 2));
      brain
        ..add(wide)
        ..add(close)
        ..update(1 / 60);
      expect(brain.live?.name, 'wide');

      // Nothing was moved; a number changed.
      close.priority = 50;
      brain.update(1 / 60);
      expect(brain.live?.name, 'close');
      expect(brain.state.position.z, closeTo(2, 1e-6));
    });

    test('blends over its duration rather than jumping', () {
      final brain = CameraBrain(
        blends: BlendTable(defaultBlend: const Blend(BlendStyle.linear, 1.0)),
      );
      final wide = camera('wide', 10, Vector3(0, 0, 20));
      final close = camera('close', 5, Vector3(0, 0, 0));
      brain
        ..add(wide)
        ..add(close)
        ..update(1 / 60);

      close.priority = 50;
      brain.update(0.5);

      expect(brain.isBlending, isTrue);
      // Halfway through a linear blend from z=20 to z=0.
      expect(brain.state.position.z, closeTo(10, 0.5));

      brain.update(0.6);
      expect(brain.isBlending, isFalse);
      expect(brain.state.position.z, closeTo(0, 1e-6));
    });

    test('interrupting a blend continues from what is on screen', () {
      final brain = CameraBrain(
        blends: BlendTable(defaultBlend: const Blend(BlendStyle.linear, 1.0)),
      );
      final a = camera('a', 30, Vector3(0, 0, 0));
      final b = camera('b', 20, Vector3(0, 0, 100));
      final c = camera('c', 10, Vector3(0, 0, 50));
      brain
        ..add(a)
        ..add(b)
        ..add(c)
        ..update(1 / 60);

      b.priority = 40;
      brain.update(0.5);
      final midBlend = brain.state.position.z;
      expect(midBlend, closeTo(50, 5));

      // Cut away mid-transition; the new blend must start from here, not from
      // where the interrupted one began.
      c.priority = 90;
      brain.update(0.0001);
      expect(
        brain.state.position.z,
        closeTo(midBlend, 1),
        reason:
            'a jump here is the visible artefact of blending from a '
            'camera rather than from the picture',
      );
    });

    test('a blend table can single out one transition', () {
      final table = BlendTable(defaultBlend: const Blend(BlendStyle.linear, 2))
        ..set('wide', 'close', const Blend.cut());

      expect(table.between('wide', 'close').duration, 0);
      expect(table.between('close', 'wide').duration, 2);
    });

    test('a new camera starts where it wants to be, not where it was', () {
      final brain = CameraBrain();
      final follower = VirtualCamera(
        name: 'follow',
        priority: 10,
        follow: FixedTarget(Vector3(100, 0, 0)),
        body: FollowBody(offset: Vector3(0, 0, 5), damping: Vector3.all(2)),
      );
      brain
        ..add(follower)
        ..update(1 / 60);

      // Snapped on add: a camera that eased in from the origin on its first
      // frame would swoop across the level for no reason.
      expect(brain.state.position.x, closeTo(100, 0.01));
    });
  });

  group('noise', () {
    test('is the same every time for the same moment', () {
      final noise = CameraNoise(seed: 7);
      expect(noise.positionAt(3.5).x, noise.positionAt(3.5).x);
    });

    test('stays inside its amplitude', () {
      final noise = CameraNoise(positionAmplitude: Vector3.all(0.1));
      for (var t = 0.0; t < 20; t += 0.05) {
        expect(noise.positionAt(t).x.abs(), lessThanOrEqualTo(0.1 + 1e-9));
      }
    });

    test('two cameras with different seeds do not sway together', () {
      final a = CameraNoise(seed: 1).positionAt(2.0);
      final b = CameraNoise(seed: 2).positionAt(2.0);
      expect((a - b).length, greaterThan(1e-6));
    });
  });
}

void _robustnessTests() {
  group('a camera that has to survive a frame', () {
    test('a surface with no size yet does not poison the camera', () {
      // A host reads the aspect off its own surface, and a surface before
      // layout is zero by zero — which is a NaN, not a small number. One of
      // those through the projection comes back as a NaN rotation, and the
      // next frame damps towards it from a value that is already NaN. Nothing
      // recovers: one frame during startup points the camera nowhere for the
      // rest of the run.
      final subject = FixedTarget(Vector3(0, 0, -10));
      final brain = CameraBrain()
        ..add(
          VirtualCamera(
            name: 'Chase',
            lookAt: subject,
            body: StaticBody(Vector3.zero()),
            aim: ComposerAim(),
          ),
        )
        ..snap();

      brain.aspect = 0 / 0;
      brain.aspect = 1 / 0;
      brain.aspect = 0;
      brain.aspect = -2;

      for (var i = 0; i < 5; i++) {
        subject.position = Vector3(i * 0.4, 0, -10);
        brain.update(1 / 60);
      }

      final forward = brain.state.forward;
      expect(forward.x.isNaN, isFalse);
      expect(forward.y.isNaN, isFalse);
      expect(forward.z.isNaN, isFalse);
      expect(brain.aspect, 16 / 9);
    });

    test('a real ratio is still taken', () {
      final brain = CameraBrain()..aspect = 4 / 3;
      expect(brain.aspect, closeTo(4 / 3, 1e-9));
    });

    test('a composed camera stays level', () {
      // The shortest rotation from the centre of the frame to where the
      // subject should sit is the obvious construction, and it rolls: an
      // offset that is both sideways and vertical turns about an oblique
      // axis, and the part of that along the view direction is roll. It then
      // accumulates, because the next frame damps towards a rotation that is
      // already leaning. This subject wanders diagonally on purpose.
      final subject = FixedTarget(Vector3.zero());
      Vector3 pathAt(double s) =>
          Vector3(math.sin(s * 0.45) * 9, 0, math.sin(s * 0.9) * 5.5);

      final brain = CameraBrain()
        ..add(
          VirtualCamera(
            name: 'Chase',
            follow: subject,
            lookAt: subject,
            body: FollowBody(
              offset: Vector3(0, 2.4, 7),
              damping: Vector3(0.35, 0.18, 0.5),
            ),
            // Off centre both ways, which is what makes the offset oblique.
            aim: ComposerAim(screenX: 0.42, screenY: 0.45, damping: 0.4),
          ),
        )
        ..snap();

      var worst = 0.0;
      var seconds = 0.0;
      for (var i = 0; i < 600; i++) {
        seconds += 1 / 60;
        final at = pathAt(seconds);
        subject
          ..position = at
          ..rotation = lookRotation(pathAt(seconds + 0.12) - at);
        brain.update(1 / 60);
        worst = math.max(worst, brain.state.right.y.abs());
      }

      // A tenth of this is a degree. It used to reach nineteen.
      expect(worst, lessThan(0.02));
    });

    test('following a subject on a path never produces a NaN', () {
      final subject = FixedTarget(Vector3.zero());
      Vector3 pathAt(double s) =>
          Vector3(math.sin(s * 0.45) * 9, 0, math.sin(s * 0.9) * 5.5);

      final brain = CameraBrain()
        ..add(
          VirtualCamera(
            name: 'Chase',
            follow: subject,
            lookAt: subject,
            body: FollowBody(
              offset: Vector3(0, 2.4, 7),
              damping: Vector3(0.35, 0.18, 0.5),
            ),
            aim: ComposerAim(screenY: 0.45, damping: 0.4),
          ),
        )
        ..snap();

      var seconds = 0.0;
      for (var i = 0; i < 400; i++) {
        seconds += 1 / 60;
        final at = pathAt(seconds);
        subject
          ..position = at
          ..rotation = lookRotation(pathAt(seconds + 0.12) - at);
        brain.update(1 / 60);
        expect(
          brain.state.forward.length,
          closeTo(1, 1e-6),
          reason: 'frame $i',
        );
      }
    });
  });
}

void _headTests() {
  group('first person', () {
    test('looks exactly where the target looks, with no lag by default', () {
      // The whole contract. A camera on a character's eyes that composes, or
      // damps, or frames, puts the view somewhere other than where they are
      // looking — and then the player is aiming at one thing and shooting at
      // another.
      final facing = lookRotation(Vector3(1, 0, -1));
      final target = FixedTarget(Vector3.zero(), facing);
      final aim = HeadAim();

      final got = aim.solve(
        Quaternion.identity(),
        Vector3.zero(),
        target,
        lens: const Lens(),
        aspect: 16 / 9,
        delta: 1 / 60,
      );

      final wanted = rotateVector(facing, Vector3(0, 0, -1));
      final looking = rotateVector(got, Vector3(0, 0, -1));
      expect((looking - wanted).length, lessThan(1e-6));
    });

    test('a vehicle can lag behind its own chassis', () {
      final target = FixedTarget(
        Vector3.zero(),
        lookRotation(Vector3(1, 0, 0)),
      );
      final aim = HeadAim(damping: 0.5);

      final got = aim.solve(
        Quaternion.identity(),
        Vector3.zero(),
        target,
        lens: const Lens(),
        aspect: 16 / 9,
        delta: 1 / 60,
      );

      // Started to turn, but nowhere near arrived.
      final looking = rotateVector(got, Vector3(0, 0, -1));
      expect(looking.x, greaterThan(0.0));
      expect(looking.x, lessThan(0.5));
    });
  });
}

void _flatTests() {
  group('a game seen flat on', () {
    Vector3 solveOnce(
      ScreenFollowBody body,
      Vector3 at,
      Vector3 subject, {
      Lens lens = const Lens.flat(height: 10),
      double delta = 1e6,
    }) {
      return body.solve(
        at,
        FixedTarget(subject),
        // Looking down -Z, level, which is what a flat game is seen from.
        rotation: Quaternion.identity(),
        lens: lens,
        aspect: 16 / 9,
        delta: delta,
      );
    }

    test('a flat lens does not care how far away a thing is', () {
      // The whole of what orthographic means, and the reason a camera over a
      // flat game has to move rather than turn: turning sweeps a perspective
      // view across the world and does nothing at all to a flat one.
      const lens = Lens.flat(height: 10);
      final near = project(
        Vector3.zero(),
        Quaternion.identity(),
        Vector3(2, 0, -5),
        lens: lens,
        aspect: 1,
      );
      final far = project(
        Vector3.zero(),
        Quaternion.identity(),
        Vector3(2, 0, -50),
        lens: lens,
        aspect: 1,
      );

      expect(near.x, closeTo(far.x, 1e-9));
      expect(near.x, closeTo(2 / 5, 1e-9));
    });

    test('a subject inside the dead zone is left alone', () {
      // The point of a dead zone. A camera that corrects for every step of a
      // walking character reads as a nervous operator rather than a steady
      // one, and in two dimensions it makes the whole background jitter.
      final body = ScreenFollowBody(deadZoneWidth: 0.2, deadZoneHeight: 0.2);
      final at = Vector3(0, 0, 10);

      // A tenth of the frame across is well inside a fifth.
      final after = solveOnce(body, at, Vector3(0.4, 0, 0));
      expect((after - at).length, lessThan(1e-6));
    });

    test('a subject past the dead zone is followed, by moving', () {
      final body = ScreenFollowBody(deadZoneWidth: 0.1, deadZoneHeight: 0.1);
      final at = Vector3(0, 0, 10);
      final after = solveOnce(body, at, Vector3(6, 0, 0));

      // Moved towards it along the frame's own right, and not turned: the
      // rotation is not this body's to change.
      expect(after.x, greaterThan(0.5));
      expect(after.y, closeTo(0, 1e-6));
    });

    test('the shot distance is held however far the framing moves it', () {
      final body = ScreenFollowBody(distance: 10, deadZoneWidth: 0);
      final after = solveOnce(body, Vector3(0, 0, 10), Vector3(7, 3, 0));

      // Still ten in front of the subject along the view direction, so
      // framing sideways never drifts the camera in or out.
      expect(after.z - 0.0, closeTo(10, 1e-5));
    });

    test('bounds are a wall, not a preference', () {
      // What stops a camera following a character to the edge of a level and
      // showing whatever is past it.
      final body = ScreenFollowBody(
        deadZoneWidth: 0,
        bounds: (minimum: Vector3(-2, -2, -100), maximum: Vector3(2, 2, 100)),
      );
      final after = solveOnce(body, Vector3(0, 0, 10), Vector3(40, 0, 0));
      expect(after.x, lessThanOrEqualTo(2.0000001));
    });

    test('it hands out the zones it frames by', () {
      final body = ScreenFollowBody(screenX: 0.5, deadZoneWidth: 0.15);
      expect(body.guides.dead.width, closeTo(0.3, 1e-9));

      // And a camera using it reports them, since the framing is the body's
      // here rather than the aim's.
      final camera = VirtualCamera(
        name: 'Flat',
        lookAt: FixedTarget(Vector3.zero()),
        body: body,
        aim: StaticAim(Quaternion.identity()),
        lens: const Lens.flat(height: 10),
      );
      expect(camera.guides, isNotNull);
      expect(camera.guides!.dead.width, closeTo(0.3, 1e-9));
    });

    test('a flat lens blends its height, not its angle', () {
      const near = Lens.flat(height: 5);
      const far = Lens.flat(height: 20);
      final middle = Lens.lerp(near, far, 0.5);

      expect(middle.orthographic, isTrue);
      // Through the logarithm, so a zoom looks even: halfway between five and
      // twenty is ten, not twelve and a half.
      expect(middle.height, closeTo(10, 1e-6));
    });
  });
}

void _guideTests() {
  group('the guides', () {
    test('a composer hands out the zones it is actually using', () {
      final aim = ComposerAim(
        screenX: 0.5,
        screenY: 0.4,
        deadZoneWidth: 0.1,
        deadZoneHeight: 0.15,
        softZoneWidth: 0.4,
        softZoneHeight: 0.3,
      );

      final guides = aim.guides;

      // The widths are half-extents in normalised coordinates, where the
      // frame runs from minus one to one. A half-extent of a tenth is
      // therefore a fifth of the frame across — get that factor wrong and
      // the box drawn is half the one the camera is using, which is worse
      // than drawing none.
      expect(guides.dead.width, closeTo(0.2, 1e-9));
      expect(guides.dead.height, closeTo(0.3, 1e-9));
      expect(guides.soft.width, closeTo(0.8, 1e-9));

      // Centred on where the subject is meant to sit, not on the frame.
      expect(guides.dead.left + guides.dead.width / 2, closeTo(0.5, 1e-9));
      expect(guides.dead.top + guides.dead.height / 2, closeTo(0.4, 1e-9));
      expect(guides.screenY, 0.4);
    });

    test('the dead zone sits inside the soft zone', () {
      final guides = ComposerAim().guides;
      expect(guides.soft.contains(guides.dead.left, guides.dead.top), isTrue);
      expect(
        guides.soft.contains(guides.dead.right, guides.dead.bottom),
        isTrue,
      );
    });

    test(
      'an aim with nothing to compose says so rather than drawing a dot',
      () {
        expect(HardLookAt().guides, isNull);
        expect(StaticAim(Quaternion.identity()).guides, isNull);
        expect(PovAim().guides, isNull);
      },
    );

    test('the zones move with the screen position', () {
      final left = ComposerAim(screenX: 0.25).guides;
      final right = ComposerAim(screenX: 0.75).guides;
      expect(right.dead.left - left.dead.left, closeTo(0.5, 1e-9));
      expect(right.dead.width, closeTo(left.dead.width, 1e-9));
    });
  });
}
