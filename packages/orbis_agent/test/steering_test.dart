import 'package:orbis_agent/orbis_agent.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Steerable agentAt(double x, {Vector3? velocity, double speed = 4}) =>
      Steerable(
        position: Vector3(x, 0, 0),
        velocity: velocity,
        maxSpeed: speed,
      );

  /// Runs [behaviour] until [until] or the clock runs out, and says how long
  /// it took. Fixed steps, so the answer is the same every run.
  ({bool arrived, double seconds}) simulate(
    Steerable self,
    Steering Function() behaviour, {
    required bool Function(Steerable) until,
    double step = 1 / 60,
    double most = 20,
  }) {
    var elapsed = 0.0;
    while (elapsed < most) {
      if (until(self)) return (arrived: true, seconds: elapsed);
      self.integrate(behaviour().force(self), step);
      elapsed += step;
    }
    return (arrived: until(self), seconds: elapsed);
  }

  group('an agent', () {
    test('never exceeds what it is capable of', () {
      final self = agentAt(0, speed: 3);
      // A force far past its limit, applied for a long step.
      self.integrate(Vector3(1000, 0, 0), 1);

      expect(self.speed, lessThanOrEqualTo(3 + 1e-9));
    });

    test('standing still is not facing anywhere', () {
      // Null rather than a stale direction: keeping the last one makes a
      // mover that stops and starts snap to an angle it had a minute ago.
      expect(agentAt(0).heading, isNull);
      expect(
        agentAt(0, velocity: Vector3(2, 0, 0)).heading!.x,
        closeTo(1, 1e-9),
      );
    });

    test('a step of no time changes nothing', () {
      final self = agentAt(5, velocity: Vector3(1, 0, 0));
      self.integrate(Vector3(10, 0, 0), 0);
      expect(self.position.x, 5);
      expect(self.velocity.x, 1);
    });
  });

  group('seek and flee', () {
    test('seek closes on its target', () {
      final self = agentAt(0);
      final run = simulate(
        self,
        () => Seek(Vector3(10, 0, 0)),
        until: (a) => (a.position - Vector3(10, 0, 0)).length < 0.5,
      );

      expect(run.arrived, isTrue);
      expect(run.seconds, lessThan(5));
    });

    test('flee opens the distance', () {
      final self = agentAt(1);
      final before = self.position.length;
      simulate(
        self,
        () => Flee(Vector3.zero()),
        until: (a) => a.position.length > 8,
        most: 5,
      );

      expect(self.position.length, greaterThan(before));
    });

    test('flee ignores what is far enough away', () {
      final self = agentAt(0);
      final force = Flee(Vector3(100, 0, 0), within: 10).force(self);
      expect(force.length, 0);
    });
  });

  group('arrive', () {
    test('it stops on the target rather than orbiting it', () {
      // The whole difference from seek: a seek at full speed overshoots and
      // comes back, over and over.
      final self = agentAt(0);
      final target = Vector3(10, 0, 0);
      simulate(self, () => Arrive(target), until: (a) => false, most: 12);

      expect((self.position - target).length, lessThan(0.2));
      expect(self.speed, lessThan(0.5));
    });

    test('it comes in slower than a seek does', () {
      // The actual difference between the two, and not the one it is usually
      // described as: both sail past, because a steering force is a velocity
      // difference applied over a frame and therefore lags. What arriving
      // buys is the speed at the door — which is why it settles where a seek
      // circles.
      final target = Vector3(10, 0, 0);

      double speedOnApproach(Steering Function() behaviour) {
        final self = agentAt(0);
        var elapsed = 0.0;
        while (elapsed < 12) {
          if ((self.position - target).length < 1) return self.speed;
          self.integrate(behaviour().force(self), 1 / 60);
          elapsed += 1 / 60;
        }
        return self.speed;
      }

      expect(
        speedOnApproach(() => Arrive(target)),
        lessThan(speedOnApproach(() => Seek(target))),
      );
    });
  });

  group('pursue and evade', () {
    test('a pursuer aims ahead of its quarry, not at it', () {
      final quarry = Steerable(
        position: Vector3(10, 0, 0),
        velocity: Vector3(0, 0, 4),
        maxSpeed: 4,
      );
      final hunter = Steerable(position: Vector3.zero(), maxSpeed: 5);

      final ahead = Pursue(quarry).force(hunter);
      final at = Seek(quarry.position).force(hunter);

      // Aiming ahead leans towards where the quarry is going — along z —
      // where aiming at it does not.
      expect(ahead.z, greaterThan(0.5));
      expect(at.z.abs(), lessThan(1e-9));
    });

    test('an evader leans away from where the hunter will be', () {
      final hunter = Steerable(
        position: Vector3(2, 0, 0),
        velocity: Vector3(4, 0, 0),
        maxSpeed: 4,
      );
      final self = Steerable(position: Vector3.zero(), maxSpeed: 4);

      expect(Evade(hunter).force(self).x, lessThan(0));
    });
  });

  group('wander', () {
    test('the same agent wanders the same way twice', () {
      // Deterministic in the seed and the clock, which is what makes a
      // wandering crowd reproducible in a replay and in a test.
      final one = Wander(seed: 7, at: 3.25).force(agentAt(0));
      final two = Wander(seed: 7, at: 3.25).force(agentAt(0));
      expect(one.x, two.x);
      expect(one.z, two.z);
    });

    test('two agents side by side do not wander in step', () {
      final one = Wander(seed: 1, at: 2).force(agentAt(0));
      final two = Wander(seed: 2, at: 2).force(agentAt(0));
      expect((one - two).length, greaterThan(0.01));
    });

    test('it drifts rather than jitters', () {
      // Independent random numbers average to nothing and make a mover that
      // vibrates on the spot. Consecutive samples have to be close.
      final self = agentAt(0);
      var worst = 0.0;
      var previous = Wander(seed: 5, at: 0).force(self).normalized();

      for (var i = 1; i < 200; i++) {
        final now = Wander(seed: 5, at: i / 60).force(self).normalized();
        final change = (now - previous).length;
        if (change > worst) worst = change;
        previous = now;
      }

      // A sixtieth of a second never swings the direction far.
      expect(worst, lessThan(0.2));
    });

    test('over time it goes somewhere rather than nowhere', () {
      final self = agentAt(0);
      var at = 0.0;
      for (var i = 0; i < 600; i++) {
        self.integrate(Wander(seed: 3, at: at).force(self), 1 / 60);
        at += 1 / 60;
      }
      expect(self.position.length, greaterThan(1));
    });
  });

  group('a crowd', () {
    test('separation pushes neighbours apart', () {
      final a = Steerable(position: Vector3(0, 0, 0));
      final b = Steerable(position: Vector3(0.5, 0, 0));
      final crowd = [a, b];

      expect(Separate(crowd).force(a).x, lessThan(0));
      expect(Separate(crowd).force(b).x, greaterThan(0));
    });

    test('it shoves harder the closer something is', () {
      // A flat force makes a crowd that shuffles as a block.
      final self = Steerable(position: Vector3.zero());
      final near = Separate([self, Steerable(position: Vector3(0.2, 0, 0))]);
      final far = Separate([self, Steerable(position: Vector3(1.8, 0, 0))]);

      expect(near.force(self).length, greaterThan(far.force(self).length));
    });

    test('an agent does not separate from itself', () {
      final self = Steerable(position: Vector3.zero());
      expect(Separate([self]).force(self).length, 0);
    });

    test('alignment turns towards how the neighbours are going', () {
      final self = Steerable(position: Vector3.zero(), maxSpeed: 4);
      final crowd = [
        self,
        Steerable(position: Vector3(1, 0, 0), velocity: Vector3(0, 0, 4)),
        Steerable(position: Vector3(2, 0, 0), velocity: Vector3(0, 0, 4)),
      ];
      expect(Align(crowd).force(self).z, greaterThan(0));
    });

    test('cohesion pulls towards where the neighbours are', () {
      final self = Steerable(position: Vector3.zero(), maxSpeed: 4);
      final crowd = [
        self,
        Steerable(position: Vector3(3, 0, 0)),
        Steerable(position: Vector3(4, 0, 0)),
      ];
      expect(Cohere(crowd).force(self).x, greaterThan(0));
    });

    test('nothing in range is no force at all', () {
      final self = Steerable(position: Vector3.zero());
      final distant = [self, Steerable(position: Vector3(500, 0, 0))];
      expect(Separate(distant).force(self).length, 0);
      expect(Align(distant).force(self).length, 0);
      expect(Cohere(distant).force(self).length, 0);
    });
  });

  group('a blend', () {
    test('it never asks for more than the agent can push', () {
      final self = Steerable(position: Vector3.zero(), maxForce: 6);
      final blended = Blend([
        (behaviour: Seek(Vector3(100, 0, 0)), weight: 10),
        (behaviour: Seek(Vector3(0, 0, 100)), weight: 10),
      ]);
      expect(blended.force(self).length, lessThanOrEqualTo(6 + 1e-9));
    });

    test('a weight of nothing contributes nothing', () {
      final self = Steerable(position: Vector3.zero());
      final only = Blend([
        (behaviour: Seek(Vector3(10, 0, 0)), weight: 1),
        (behaviour: Seek(Vector3(0, 0, 10)), weight: 0),
      ]);
      expect(only.force(self).z.abs(), lessThan(1e-9));
    });

    test('two reasons to move give one direction between them', () {
      // Blending rather than choosing: an agent that picked one behaviour per
      // tick snaps between them, and the snap is visible however good each is.
      final self = Steerable(position: Vector3.zero());
      final both = Blend([
        (behaviour: Seek(Vector3(10, 0, 0)), weight: 1),
        (behaviour: Seek(Vector3(0, 0, 10)), weight: 1),
      ]).force(self);

      expect(both.x, greaterThan(0));
      expect(both.z, greaterThan(0));
    });
  });

  group('following a path', () {
    final route = [Vector3(5, 0, 0), Vector3(5, 0, 5), Vector3(0, 0, 5)];

    test('it advances once a point is reached', () {
      final self = Steerable(position: Vector3(5, 0, 0));
      expect(FollowPath(route, index: 0).nextIndex(self), 1);
    });

    test('asking for the force does not advance anything', () {
      // A behaviour that moved an index as a side effect of being asked could
      // not be asked twice — and a test and a debug overlay both do.
      final self = Steerable(position: Vector3(5, 0, 0));
      const path = FollowPath(<Vector3>[], index: 0);
      expect(path.nextIndex(self), 0);

      final walking = FollowPath(route, index: 0);
      walking.force(self);
      walking.force(self);
      expect(walking.index, 0);
    });

    test('a loop goes back to the beginning; a route does not', () {
      final self = Steerable(position: Vector3(0, 0, 5));
      expect(FollowPath(route, index: 2, loop: true).nextIndex(self), 0);
      expect(FollowPath(route, index: 2).nextIndex(self), 2);
    });

    test('it walks a whole route and stops on the end', () {
      final self = Steerable(position: Vector3.zero(), maxSpeed: 4);
      var path = FollowPath(route, index: 0);
      var elapsed = 0.0;

      while (elapsed < 20 && !path.isDone(self)) {
        self.integrate(path.force(self), 1 / 60);
        path = FollowPath(route, index: path.nextIndex(self));
        elapsed += 1 / 60;
      }

      expect(path.isDone(self), isTrue);
      expect((self.position - route.last).length, lessThan(1.1));
    });

    test('an empty path asks for nothing', () {
      final self = Steerable(position: Vector3.zero());
      expect(const FollowPath(<Vector3>[], index: 0).force(self).length, 0);
    });
  });
}
