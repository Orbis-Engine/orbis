import 'package:orbis_agent/orbis_agent.dart';
import 'package:test/test.dart';

void main() {
  /// A leaf that returns whatever it is told, and counts how often it is run.
  ({Node node, List<Status> calls}) counted(Status answer) {
    final calls = <Status>[];
    return (
      node: Do('counted', (tick) {
        calls.add(answer);
        return answer;
      }),
      calls: calls,
    );
  }

  group('a sequence', () {
    test('succeeds only when every child does', () {
      const tree = Sequence([Check('yes', _always), Check('yes', _always)]);
      expect(Brain(tree).tick(0.1), Status.success);
    });

    test('stops at the first failure', () {
      final after = counted(Status.success);
      final tree = Sequence([const Check('no', _never), after.node]);

      expect(Brain(tree).tick(0.1), Status.failure);
      // The step after a failed one is not run. Walking through a door that
      // did not open is the whole thing this prevents.
      expect(after.calls, isEmpty);
    });

    test('resumes at the child that was running, not at the first', () {
      // The commonest thing to get wrong. Restarting produces an agent that
      // re-opens a door it is halfway through.
      final first = counted(Status.success);
      var opened = 0;
      final tree = Sequence([
        first.node,
        Do('walk', (tick) => opened++ < 2 ? Status.running : Status.success),
      ]);

      final brain = Brain(tree);
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.success);

      // Three ticks, and the first child ran once — on the first tick only.
      expect(first.calls, hasLength(1));
    });

    test('starts again once it has finished', () {
      final first = counted(Status.success);
      final tree = Sequence([first.node]);
      final brain = Brain(tree);

      expect(brain.tick(0.1), Status.success);
      expect(brain.tick(0.1), Status.success);
      expect(first.calls, hasLength(2));
    });
  });

  group('a selector', () {
    test('takes the first child that works', () {
      final second = counted(Status.success);
      final tree = Selector([const Check('no', _never), second.node]);

      expect(Brain(tree).tick(0.1), Status.success);
      expect(second.calls, hasLength(1));
    });

    test('fails only when every child does', () {
      const tree = Selector([Check('no', _never), Check('no', _never)]);
      expect(Brain(tree).tick(0.1), Status.failure);
    });

    test('resumes at the child that was running', () {
      final first = counted(Status.failure);
      var chased = 0;
      final tree = Selector([
        first.node,
        Do('chase', (tick) => chased++ < 1 ? Status.running : Status.success),
      ]);

      final brain = Brain(tree);
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.success);

      // The condition in front of the running child is not re-asked while it
      // runs — an agent that re-checked would abandon its chase the moment
      // the thing it is chasing left range, mid-stride.
      expect(first.calls, hasLength(1));
    });
  });

  group('a parallel', () {
    test('runs every child even once the answer is known', () {
      // A child that returned early would leave its siblings un-ticked, and
      // anything holding a timer would run slow whenever a sibling finished.
      final late = counted(Status.running);
      final tree = Parallel([const Check('no', _never), late.node]);

      expect(Brain(tree).tick(0.1), Status.failure);
      expect(late.calls, hasLength(1));
    });

    test('succeeds when enough children have', () {
      const two = Parallel(
        [Check('yes', _always), Check('yes', _always), Check('no', _never)],
        succeedAfter: 2,
        failAfter: 2,
      );
      expect(Brain(two).tick(0.1), Status.success);
    });
  });

  group('decorators', () {
    test('invert swaps the two answers and leaves running alone', () {
      expect(
        Brain(const Invert(Check('yes', _always))).tick(0.1),
        Status.failure,
      );
      expect(
        Brain(const Invert(Check('no', _never))).tick(0.1),
        Status.success,
      );
      expect(
        Brain(Invert(Do('busy', (tick) => Status.running))).tick(0.1),
        Status.running,
      );
    });

    test('succeed hides a failure worth trying anyway', () {
      expect(
        Brain(const Succeed(Check('no', _never))).tick(0.1),
        Status.success,
      );
    });

    test('wait runs on the tick clock, not a real one', () {
      final brain = Brain(const Wait(0.25));
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.success);
      // And it is ready to wait again.
      expect(brain.tick(0.3), Status.success);
    });

    test('repeat runs its child a fixed number of times', () {
      final child = counted(Status.success);
      final brain = Brain(Repeat(child.node, times: 3));

      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.success);
      expect(child.calls, hasLength(3));
    });

    test('cooldown refuses for a while after its child finishes', () {
      final child = counted(Status.success);
      final brain = Brain(Cooldown(child.node, 0.3));

      expect(brain.tick(0.1), Status.success);
      expect(brain.tick(0.1), Status.failure);
      expect(brain.tick(0.1), Status.failure);
      expect(brain.tick(0.1), Status.failure);
      expect(brain.tick(0.1), Status.success);

      // Twice in five ticks rather than five times. Stopping an agent doing
      // the expensive thing every frame it is allowed to is the whole job.
      expect(child.calls, hasLength(2));
    });

    test('a deadline gives up on a child that will not finish', () {
      final brain = Brain(Deadline(Do('forever', (t) => Status.running), 0.25));
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.running);
      expect(brain.tick(0.1), Status.failure);
    });
  });

  group('a brain', () {
    test('two agents on one tree do not share where they are in it', () {
      // The reason nodes are stateless: a patrol tree is a description of
      // patrolling, not a description of one guard patrolling.
      const tree = Sequence([Wait(0.2), Check('yes', _always)]);
      final one = Brain(tree);
      final two = Brain(tree);

      expect(one.tick(0.15), Status.running);
      expect(two.tick(0.05), Status.running);
      expect(one.tick(0.1), Status.success);
      // The second is still waiting on its own clock.
      expect(two.tick(0.05), Status.running);
    });

    test('interrupting forgets the middle without forgetting the tree', () {
      final brain = Brain(const Wait(0.3));
      expect(brain.tick(0.2), Status.running);

      brain.interrupt();
      expect(brain.status, isNull);

      // Waiting starts again rather than finishing early.
      expect(brain.tick(0.2), Status.running);
    });

    test('the blackboard carries what the game knows', () {
      final seen = <String>[];
      final tree = Sequence([
        Act('spot', (tick) => tick.write('target', 'crate')),
        Do('name', (tick) {
          seen.add(tick.read<String>('target') ?? 'nothing');
          return Status.success;
        }),
      ]);

      expect(Brain(tree).tick(0.1), Status.success);
      expect(seen, ['crate']);
    });
  });

  group('a guard', () {
    test('falls back down its choices as the world changes', () {
      // The shape most of an agent's behaviour actually is: attack if it can,
      // otherwise chase, otherwise patrol.
      var distance = 20.0;
      final log = <String>[];

      final tree = Selector([
        Sequence([
          Check('in range', (tick) => distance < 2),
          Act('attack', (tick) => log.add('attack')),
        ]),
        Sequence([
          Check('seen', (tick) => distance < 10),
          Act('chase', (tick) => log.add('chase')),
        ]),
        Act('patrol', (tick) => log.add('patrol')),
      ]);

      final brain = Brain(tree);
      brain.tick(0.1);
      distance = 8;
      brain.tick(0.1);
      distance = 1;
      brain.tick(0.1);

      expect(log, ['patrol', 'chase', 'attack']);
    });
  });
}

bool _always(Tick tick) => true;
bool _never(Tick tick) => false;
