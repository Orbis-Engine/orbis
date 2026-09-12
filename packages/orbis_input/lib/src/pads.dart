import 'dart:io';

import 'package:vector_math/vector_math_64.dart';

import 'backend.dart';
import 'evdev.dart';
import 'layout.dart';
import 'linux.dart';
import 'pad.dart';
import 'shaping.dart';

/// Something that happened between two polls.
///
/// The half a snapshot cannot hold. Two cases, and only two, which is why this
/// is a short list rather than a second way of reading everything: a button
/// pressed and released inside one frame is invisible to a state that is only
/// looked at at the ends of frames, and a pad arriving or leaving is not a
/// state at all — it is the moment the state changed meaning.
sealed class PadEvent {
  const PadEvent(this.slot);

  /// Which player it happened to.
  final int slot;
}

/// A pad was plugged in, or was already there when the game started.
class PadConnected extends PadEvent {
  const PadConnected(super.slot, this.identity, this.layout);

  final PadIdentity identity;
  final PadLayout layout;

  @override
  String toString() => 'PadConnected($slot, ${identity.name})';
}

/// A pad went away.
class PadDisconnected extends PadEvent {
  const PadDisconnected(super.slot, this.identity);

  final PadIdentity identity;

  @override
  String toString() => 'PadDisconnected($slot, ${identity.name})';
}

/// A button went down.
class PadPressed extends PadEvent {
  const PadPressed(super.slot, this.button);

  final PadButton button;

  @override
  String toString() => 'PadPressed($slot, ${button.name})';
}

/// A button came up.
class PadReleased extends PadEvent {
  const PadReleased(super.slot, this.button);

  final PadButton button;

  @override
  String toString() => 'PadReleased($slot, ${button.name})';
}

/// Where every pad stands, and what happened getting here.
///
/// Shaped after `Director.advance` in `orbis_sequence`, deliberately: that is
/// the one other place in this engine where something genuinely has to be
/// advanced rather than sampled, and it answers with both the new state and
/// the discrete things crossed on the way. Input has exactly the same problem
/// and deserves exactly the same answer rather than a second idea of how a
/// frame asks what changed.
class PadFrame {
  const PadFrame(this.pads, this.events);

  /// Every slot, connected or not, so a two-player game can index by player
  /// number without checking a length first.
  final List<PadState> pads;

  /// What happened since the last poll, in the order it happened.
  final List<PadEvent> events;

  /// One player's pad. [PadState.absent] when nobody is in that slot, which
  /// reads as a pad holding nothing.
  PadState pad(int slot) =>
      slot >= 0 && slot < pads.length ? pads[slot] : PadState.absent;

  /// The lowest-numbered pad that is actually there.
  ///
  /// What a single-player game wants, and what it should keep wanting when the
  /// player unplugs a pad and plugs in a different one.
  PadState get first =>
      pads.firstWhere((pad) => pad.connected, orElse: () => PadState.absent);

  /// Every pad that is there.
  Iterable<PadState> get connected => pads.where((pad) => pad.connected);

  /// How many are attached.
  int get count => connected.length;

  /// Whether anybody is touching anything.
  bool get isActive => connected.any((pad) => pad.isActive);
}

/// The gamepads attached to this machine.
///
/// Opened once and polled once a frame. The poll is what drains the devices,
/// so the state a frame reads is as new as the frame — and a game that stops
/// polling stops seeing input rather than accumulating a backlog of it.
class Pads {
  Pads({
    PadBackend? backend,
    this.sticks = const Shaping(),
    this.triggers = Shaping.triggers,
    this.maxPads = 8,
  }) : _backend = backend ?? noPads;

  /// The pads on this machine, through whichever backend the platform has.
  ///
  /// A platform with no backend gets one that reports nothing, rather than an
  /// exception: a game run on a machine it was not built for should be short
  /// of a controller, not dead.
  factory Pads.open({
    Shaping sticks = const Shaping(),
    Shaping triggers = Shaping.triggers,
    int maxPads = 8,
  }) {
    PadBackend backend = noPads;
    if (Platform.isLinux) {
      backend = LinuxPads();
    }
    return Pads(
      backend: backend,
      sticks: sticks,
      triggers: triggers,
      maxPads: maxPads,
    );
  }

  final PadBackend _backend;

  /// How every pad's sticks are shaped, unless its layout says otherwise.
  final Shaping sticks;

  /// How every pad's triggers are shaped.
  final Shaping triggers;

  /// How many players are possible. A ninth pad is ignored rather than
  /// displacing somebody.
  final int maxPads;

  final Map<int, _Slot> _slots = {};

  /// Which slot a pad had last time it was here, by its own token.
  ///
  /// So a controller whose battery dies mid-game comes back as the same player
  /// rather than as whoever happens to be next in line. Kept for the life of
  /// the process, because that is how long "player two" means anything.
  final Map<String, int> _remembered = {};

  /// Drains every pad and says where things stand.
  PadFrame poll() {
    final events = <PadEvent>[];
    final seen = <String, PadDevice>{};
    for (final device in _backend.scan()) {
      seen[device.identity.token] = device;
    }

    // Gone first, so a pad unplugged and another plugged into the same port
    // between two polls does not fight over the slot.
    for (final entry in _slots.entries.toList()) {
      final slot = entry.value;
      final still = seen[slot.token];
      if (still == null || !still.isAlive || !identical(still, slot.device)) {
        events.add(PadDisconnected(entry.key, slot.device.identity));
        _remembered[slot.token] = entry.key;
        slot.device.close();
        _slots.remove(entry.key);
      }
    }

    // Then arrivals.
    for (final entry in seen.entries) {
      if (_slots.values.any((slot) => identical(slot.device, entry.value))) {
        continue;
      }
      final at = _slotFor(entry.key);
      if (at == null) continue;
      final slot = _Slot(entry.value)..adopt();
      _slots[at] = slot;
      events.add(PadConnected(at, slot.device.identity, slot.layout));
    }

    // Then what each of them has to say.
    for (final entry in _slots.entries) {
      entry.value.pump(entry.key, events);
    }

    final pads = <PadState>[];
    for (var i = 0; i < maxPads; i++) {
      final slot = _slots[i];
      pads.add(slot == null ? PadState.absent : slot.stateAt(i, this));
    }
    return PadFrame(pads, events);
  }

  /// The slot a newly seen pad should take: the one it had before if that is
  /// free, and the lowest free one otherwise.
  int? _slotFor(String token) {
    final remembered = _remembered[token];
    if (remembered != null &&
        remembered < maxPads &&
        !_slots.containsKey(remembered)) {
      return remembered;
    }
    for (var i = 0; i < maxPads; i++) {
      if (!_slots.containsKey(i)) return i;
    }
    return null;
  }

  /// Lets go of every device.
  void close() {
    for (final slot in _slots.values) {
      slot.device.close();
    }
    _slots.clear();
    _backend.close();
  }
}

/// One player's pad, and everything being tracked about it between polls.
class _Slot {
  _Slot(this.device)
    : layout = PadLayout.of(device.identity, capabilities: device.capabilities);

  final PadDevice device;
  final PadLayout layout;
  final EvdevDecoder _decoder = EvdevDecoder();

  String get token => device.identity.token;

  /// Raw axis values by platform code.
  final Map<int, int> _axes = {};

  /// Button codes held now, and as of the last poll.
  Set<int> _down = {};
  Set<int> _was = {};

  /// Takes the device's current state as the starting point.
  ///
  /// Without this, a trigger already held when the game starts reads as
  /// released until somebody lets go of it and pulls it again — the state is
  /// only ever a running total of differences, and a total needs a first term.
  void adopt() {
    final now = device.resync();
    _down = now.buttons;
    _was = Set<int>.of(now.buttons);
    _axes
      ..clear()
      ..addAll(now.axes);
  }

  /// Reads whatever has arrived and folds it in.
  void pump(int slot, List<PadEvent> events) {
    _was = Set<int>.of(_down);

    final bytes = device.drain();
    if (bytes.isEmpty) return;

    for (final event in _decoder.decode(bytes)) {
      switch (event.type) {
        case evKey:
          // A value of 2 is the kernel repeating a held key. Ignored: a
          // gamepad button that is being held is already down, and treating a
          // repeat as a fresh press would fire a jump every few frames.
          if (event.value == 1) {
            if (_down.add(event.code)) {
              final button = layout.buttons[event.code];
              if (button != null) events.add(PadPressed(slot, button));
            }
          } else if (event.value == 0) {
            if (_down.remove(event.code)) {
              final button = layout.buttons[event.code];
              if (button != null) events.add(PadReleased(slot, button));
            }
          }
        case evAbs:
          _axes[event.code] = event.value;
        case evSyn:
          if (event.value == synDropped || event.code == synDropped) {
            // The kernel threw events away, so every difference since is
            // unreliable. Ask the device what it actually is rather than
            // carrying on from a state that has already diverged.
            _decoder.reset();
            final now = device.resync();
            for (final code in _down.difference(now.buttons)) {
              final button = layout.buttons[code];
              if (button != null) events.add(PadReleased(slot, button));
            }
            for (final code in now.buttons.difference(_down)) {
              final button = layout.buttons[code];
              if (button != null) events.add(PadPressed(slot, button));
            }
            _down = now.buttons;
            _axes
              ..clear()
              ..addAll(now.axes);
          }
      }
    }
  }

  /// What this pad looks like to a frame.
  PadState stateAt(int slot, Pads owner) {
    final named = <PadButton>{};
    for (final code in _down) {
      final button = layout.buttons[code];
      if (button != null) named.add(button);
    }

    final raw = <PadAxis, double>{};
    for (final entry in _axes.entries) {
      // The hats are the d-pad, not axes. A hat rests at nought and goes to
      // -1 or 1, and every game wants that as four buttons.
      if (entry.key == PadLayout.hatX) {
        if (entry.value < 0) named.add(PadButton.dpadLeft);
        if (entry.value > 0) named.add(PadButton.dpadRight);
        continue;
      }
      if (entry.key == PadLayout.hatY) {
        // Positive is down in the hardware's numbering, as it is everywhere
        // else here, and up in ours.
        if (entry.value < 0) named.add(PadButton.dpadUp);
        if (entry.value > 0) named.add(PadButton.dpadDown);
        continue;
      }

      final axis = layout.axes[entry.key];
      if (axis == null) continue;
      final range = device.ranges[entry.key] ?? _defaultRange(axis);
      final isTrigger =
          axis == PadAxis.leftTrigger || axis == PadAxis.rightTrigger;
      var value = isTrigger
          ? range.toUnsigned(entry.value)
          : range.toSigned(entry.value);
      // Up is positive here and down is positive in the hardware.
      if (axis == PadAxis.leftY || axis == PadAxis.rightY) value = -value;
      raw[axis] = value;
    }

    final shaped = <PadAxis, double>{};
    final stickShaping = identical(layout.sticks, Shaping.none)
        ? owner.sticks
        : layout.sticks;
    shaped.addAll(
      _shapeStick(
        stickShaping,
        raw[PadAxis.leftX] ?? 0,
        raw[PadAxis.leftY] ?? 0,
        PadAxis.leftX,
        PadAxis.leftY,
      ),
    );
    shaped.addAll(
      _shapeStick(
        stickShaping,
        raw[PadAxis.rightX] ?? 0,
        raw[PadAxis.rightY] ?? 0,
        PadAxis.rightX,
        PadAxis.rightY,
      ),
    );
    for (final axis in [PadAxis.leftTrigger, PadAxis.rightTrigger]) {
      shaped[axis] = owner.triggers.scalar(raw[axis] ?? 0);
    }

    // A trigger that travels is also a button, so a game can treat it as
    // either without every game choosing its own threshold. Half way, which is
    // far enough not to fire on a resting trigger and near enough to feel
    // immediate.
    if ((shaped[PadAxis.leftTrigger] ?? 0) > 0.5) {
      named.add(PadButton.leftTrigger);
    }
    if ((shaped[PadAxis.rightTrigger] ?? 0) > 0.5) {
      named.add(PadButton.rightTrigger);
    }

    final wasNamed = <PadButton>{};
    for (final code in _was) {
      final button = layout.buttons[code];
      if (button != null) wasNamed.add(button);
    }

    return PadState(
      slot: slot,
      identity: device.identity,
      down: named,
      pressed: named.difference(wasNamed),
      released: wasNamed.difference(named),
      axes: shaped,
      raw: raw,
    );
  }

  Map<PadAxis, double> _shapeStick(
    Shaping shaping,
    double x,
    double y,
    PadAxis xAxis,
    PadAxis yAxis,
  ) {
    final shaped = shaping.stick(Vector2(x, y));
    return {xAxis: shaped.x, yAxis: shaped.y};
  }

  static PadAxisRange _defaultRange(PadAxis axis) =>
      axis == PadAxis.leftTrigger || axis == PadAxis.rightTrigger
      ? PadAxisRange.trigger
      : PadAxisRange.stick;
}
