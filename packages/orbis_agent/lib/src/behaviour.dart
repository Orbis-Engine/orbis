/// How a node answered this tick.
enum Status {
  /// It is still working, and wants to be asked again next tick.
  ///
  /// The one that makes a behaviour tree a tree rather than a decision table.
  /// Without it every node has to finish inside one frame, which rules out
  /// walking anywhere, waiting for anything, or playing an animation to its
  /// end.
  running,

  /// It did what it set out to do.
  success,

  /// It could not.
  failure,
}

/// What a tick is given to work with.
///
/// A bag rather than a typed thing on purpose: a tree is authored against one
/// game's ideas — a target, a patrol route, how frightened something is — and
/// a library that named those would be a library that only fits one game.
/// What this does own is the clock, because every node that waits needs one
/// and each of them keeping its own would be a tree that ran at several
/// speeds.
class Tick {
  Tick({required this.seconds, Map<String, Object?>? blackboard})
    : blackboard = blackboard ?? <String, Object?>{};

  /// How long since the last tick.
  final double seconds;

  /// What the tree knows. Written by nodes, read by nodes, owned by neither.
  final Map<String, Object?> blackboard;

  T? read<T>(String key) {
    final value = blackboard[key];
    return value is T ? value : null;
  }

  void write(String key, Object? value) => blackboard[key] = value;
}

/// One node of a behaviour tree.
///
/// Nodes are stateless; everything that has to survive a tick lives in
/// [Memory], keyed by the node. That is what lets one tree be shared by a
/// hundred agents — a patrol tree is a description of patrolling, not a
/// description of one guard patrolling — and it is why a node is a `const`
/// object rather than something with fields that change.
abstract class Node {
  const Node();

  Status tick(Tick tick, Memory memory);

  /// A name for a trace. Not required to be unique.
  String get label => runtimeType.toString();
}

/// Where a tree keeps what it is in the middle of.
///
/// One of these per agent. The keys are the nodes themselves, by identity, so
/// two copies of the same node type in one tree do not share a place.
class Memory {
  final Map<Node, Object?> _state = {};

  /// What [node] last stored, or [orElse] if it has stored nothing.
  T of<T>(Node node, T orElse) {
    final held = _state[node];
    return held is T ? held : orElse;
  }

  void put(Node node, Object? state) => _state[node] = state;

  /// Forgets what [node] was in the middle of.
  void reset(Node node) => _state.remove(node);

  /// Forgets everything. For an agent that has been killed, teleported, or
  /// handed a new tree.
  void clear() => _state.clear();

  int get length => _state.length;
}

// ---------------------------------------------------------------------------
// Composites
// ---------------------------------------------------------------------------

/// Each child in turn, stopping at the first that fails.
///
/// "Do all of these." Open the door, walk through it, close it behind you —
/// and if the door will not open, do not walk into it.
///
/// **It resumes where it was.** A sequence whose third child returned running
/// asks the third child again next tick rather than starting from the first.
/// Restarting is the commonest thing to get wrong here, and what it produces
/// is an agent that re-opens a door it is halfway through.
class Sequence extends Node {
  const Sequence(this.children);

  final List<Node> children;

  @override
  Status tick(Tick tick, Memory memory) {
    var start = memory.of<int>(this, 0);
    if (start >= children.length) start = 0;

    for (var i = start; i < children.length; i++) {
      final status = children[i].tick(tick, memory);
      if (status == Status.running) {
        memory.put(this, i);
        return Status.running;
      }
      if (status == Status.failure) {
        memory.reset(this);
        return Status.failure;
      }
    }
    memory.reset(this);
    return Status.success;
  }

  @override
  String get label => 'sequence';
}

/// Each child in turn, stopping at the first that succeeds.
///
/// "Try these until one works." Attack if something is in range, otherwise
/// chase it, otherwise go back to patrolling — the fallback chain that most
/// of an agent's behaviour actually is.
class Selector extends Node {
  const Selector(this.children);

  final List<Node> children;

  @override
  Status tick(Tick tick, Memory memory) {
    var start = memory.of<int>(this, 0);
    if (start >= children.length) start = 0;

    for (var i = start; i < children.length; i++) {
      final status = children[i].tick(tick, memory);
      if (status == Status.running) {
        memory.put(this, i);
        return Status.running;
      }
      if (status == Status.success) {
        memory.reset(this);
        return Status.success;
      }
    }
    memory.reset(this);
    return Status.failure;
  }

  @override
  String get label => 'selector';
}

/// Every child, every tick.
///
/// For the things an agent does at the same time as other things: walking
/// while looking around, bleeding while fighting. [succeedAfter] is how many
/// have to succeed for the whole to succeed; null means all of them.
class Parallel extends Node {
  const Parallel(this.children, {this.succeedAfter, this.failAfter = 1});

  final List<Node> children;
  final int? succeedAfter;

  /// How many failures end it. One by default — a parallel that ignored
  /// failures would keep running a child that has already given up.
  final int failAfter;

  @override
  Status tick(Tick tick, Memory memory) {
    var succeeded = 0;
    var failed = 0;

    // Every child is ticked even once the answer is known. A parallel that
    // returned early would leave the rest of its children un-ticked this
    // frame, which for anything holding a timer means a clock that runs slow
    // whenever a sibling finishes first.
    for (final child in children) {
      switch (child.tick(tick, memory)) {
        case Status.success:
          succeeded++;
        case Status.failure:
          failed++;
        case Status.running:
          break;
      }
    }

    if (failed >= failAfter) return Status.failure;
    if (succeeded >= (succeedAfter ?? children.length)) return Status.success;
    return Status.running;
  }

  @override
  String get label => 'parallel';
}

// ---------------------------------------------------------------------------
// Decorators
// ---------------------------------------------------------------------------

/// Success for failure and failure for success. Running is left alone.
class Invert extends Node {
  const Invert(this.child);

  final Node child;

  @override
  Status tick(Tick tick, Memory memory) => switch (child.tick(tick, memory)) {
    Status.success => Status.failure,
    Status.failure => Status.success,
    Status.running => Status.running,
  };

  @override
  String get label => 'invert';
}

/// Whatever the child says, called success.
///
/// For a step that is worth trying and not worth stopping for — reloading
/// when there is nothing to reload with.
class Succeed extends Node {
  const Succeed(this.child);

  final Node child;

  @override
  Status tick(Tick tick, Memory memory) {
    final status = child.tick(tick, memory);
    return status == Status.running ? Status.running : Status.success;
  }

  @override
  String get label => 'succeed';
}

/// The child again, up to [times], or for ever when that is null.
class Repeat extends Node {
  const Repeat(this.child, {this.times});

  final Node child;
  final int? times;

  @override
  Status tick(Tick tick, Memory memory) {
    var done = memory.of<int>(this, 0);

    final status = child.tick(tick, memory);
    if (status == Status.running) return Status.running;
    if (status == Status.failure) {
      memory.reset(this);
      return Status.failure;
    }

    done++;
    if (times != null && done >= times!) {
      memory.reset(this);
      return Status.success;
    }
    memory.put(this, done);
    return Status.running;
  }

  @override
  String get label => times == null ? 'repeat' : 'repeat $times';
}

/// Nothing for a while, then success.
///
/// The clock comes from the tick rather than from a real one, so a tree runs
/// the same way at any frame rate and can be stepped by hand in a test.
class Wait extends Node {
  const Wait(this.seconds);

  final double seconds;

  @override
  Status tick(Tick tick, Memory memory) {
    final waited = memory.of<double>(this, 0) + tick.seconds;
    if (waited >= seconds) {
      memory.reset(this);
      return Status.success;
    }
    memory.put(this, waited);
    return Status.running;
  }

  @override
  String get label => 'wait ${seconds}s';
}

/// The child, but not again for [seconds] after it finishes.
///
/// What stops an agent doing the expensive thing every frame it is allowed
/// to: shouting, searching, re-planning a route.
class Cooldown extends Node {
  const Cooldown(this.child, this.seconds);

  final Node child;
  final double seconds;

  @override
  Status tick(Tick tick, Memory memory) {
    final left = memory.of<double>(this, 0);
    if (left > 0) {
      memory.put(this, left - tick.seconds);
      return Status.failure;
    }

    final status = child.tick(tick, memory);
    if (status != Status.running) memory.put(this, seconds);
    return status;
  }

  @override
  String get label => 'cooldown ${seconds}s';
}

/// The child until it finishes, giving up after [seconds].
///
/// Named for what it is rather than `Timeout`, which every test package in
/// Dart also exports — a node nobody can import beside their own test
/// framework is a node nobody uses.
class Deadline extends Node {
  const Deadline(this.child, this.seconds);

  final Node child;
  final double seconds;

  @override
  Status tick(Tick tick, Memory memory) {
    final spent = memory.of<double>(this, 0) + tick.seconds;
    if (spent > seconds) {
      memory.reset(this);
      return Status.failure;
    }

    final status = child.tick(tick, memory);
    if (status == Status.running) {
      memory.put(this, spent);
      return Status.running;
    }
    memory.reset(this);
    return status;
  }

  @override
  String get label => 'deadline ${seconds}s';
}

// ---------------------------------------------------------------------------
// Leaves
// ---------------------------------------------------------------------------

/// Something the game does, which may take more than one tick.
class Do extends Node {
  const Do(this.name, this.run);

  final String name;
  final Status Function(Tick tick) run;

  @override
  Status tick(Tick tick, Memory memory) => run(tick);

  @override
  String get label => name;
}

/// Something the game does that finishes immediately.
class Act extends Node {
  const Act(this.name, this.run);

  final String name;
  final void Function(Tick tick) run;

  @override
  Status tick(Tick tick, Memory memory) {
    run(tick);
    return Status.success;
  }

  @override
  String get label => name;
}

/// A question. Success for yes.
class Check extends Node {
  const Check(this.name, this.ask);

  final String name;
  final bool Function(Tick tick) ask;

  @override
  Status tick(Tick tick, Memory memory) =>
      ask(tick) ? Status.success : Status.failure;

  @override
  String get label => name;
}

/// A tree and one agent's place in it.
///
/// The tree is shared and this is not: a hundred guards patrolling run one
/// tree and a hundred of these.
class Brain {
  Brain(this.root);

  final Node root;
  final Memory memory = Memory();

  Status? _last;

  /// What the tree said last time it was asked.
  Status? get status => _last;

  Status tick(double seconds, {Map<String, Object?>? blackboard}) {
    _last = root.tick(Tick(seconds: seconds, blackboard: blackboard), memory);
    return _last!;
  }

  /// Forgets what it was in the middle of, without forgetting the tree.
  void interrupt() {
    memory.clear();
    _last = null;
  }
}
