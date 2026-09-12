import 'package:vector_math/vector_math_64.dart';

/// A button, named by where it is rather than by what is printed on it.
///
/// This is the distinction that makes every cross-platform input layer either
/// right or a source of bug reports. The bottom face button is in the same
/// place on every pad ever made; what is written on it is A on an Xbox pad, B
/// on a Nintendo one, and a cross on a PlayStation one. Code that means "the
/// jump button" wants the position, and a prompt drawn on screen wants the
/// label — so the position is the name here and [PadLabels] answers the other
/// question separately.
///
/// The kernel names them the same way and for the same reason, which is why
/// the Linux backend has so little to do.
enum PadButton {
  /// The bottom face button. A, cross, B on a Nintendo pad.
  south,

  /// The right face button. B, circle, A on a Nintendo pad.
  east,

  /// The left face button. X, square, Y on a Nintendo pad.
  west,

  /// The top face button. Y, triangle, X on a Nintendo pad.
  north,

  leftShoulder,
  rightShoulder,

  /// The triggers as buttons, for a pad whose triggers do not travel, and as
  /// a threshold crossing on one whose do — see [PadState.trigger] for the
  /// analogue value.
  leftTrigger,
  rightTrigger,

  /// Back, view, select, the minus key.
  select,

  /// Start, menu, options, the plus key.
  start,

  /// The one in the middle with the maker's logo on it.
  guide,

  /// Pressing the sticks in.
  leftStick,
  rightStick,

  dpadUp,
  dpadDown,
  dpadLeft,
  dpadRight,
}

/// An analogue axis.
///
/// Sticks are reported with **positive meaning up and right**, which is not
/// what the hardware says: evdev, like most of the platforms, has positive Y
/// pointing down because it inherited the convention from screens. A stick is
/// not a screen, the rest of this engine has Y pointing up, and a control
/// scheme that needs a minus sign in front of it to walk forwards is one
/// somebody will eventually forget.
enum PadAxis {
  leftX,
  leftY,
  rightX,
  rightY,

  /// Triggers run 0 to 1, never negative, whatever the hardware's own range.
  leftTrigger,
  rightTrigger,
}

/// One of the two sticks.
enum PadStick { left, right }

/// One of the two sides, for the triggers and shoulders.
enum PadSide { left, right }

/// What a pad is, as far as anything can tell.
///
/// The vendor and product are how a layout is chosen. [uniq] is the pad's own
/// serial number where it has one and [path] is the port it is plugged into
/// where it does not — between them they are how a pad that is unplugged and
/// plugged back in is recognised as the same pad, and given its player number
/// back rather than being handed whatever slot happens to be free.
class PadIdentity {
  const PadIdentity({
    required this.name,
    this.vendor = 0,
    this.product = 0,
    this.version = 0,
    this.bus = 0,
    this.uniq = '',
    this.path = '',
  });

  /// What the driver calls it. Worth showing to a person, and the last resort
  /// for choosing a layout when the vendor and product are in no table.
  final String name;

  final int vendor;
  final int product;
  final int version;
  final int bus;

  /// The pad's own serial number, where it reports one. Usually empty.
  final String uniq;

  /// Where it is physically attached. Stable across a replug into the same
  /// port, which is the common case for a wired pad.
  final String path;

  /// What this pad is *called*, for matching against a table and for
  /// remembering which player it was.
  ///
  /// The serial number when there is one, because that follows the pad between
  /// ports; the port otherwise, because for a pad with no serial the port is
  /// the only thing that distinguishes two identical pads from each other.
  String get token =>
      uniq.isNotEmpty ? 'uniq:$uniq' : (path.isNotEmpty ? 'path:$path' : name);

  @override
  String toString() =>
      '$name (${vendor.toRadixString(16).padLeft(4, '0')}:'
      '${product.toRadixString(16).padLeft(4, '0')})';
}

/// What one pad is doing, at the moment it was asked.
///
/// Immutable, and complete: everything a frame needs to know about one pad is
/// in here, so a scene can be built from it without going back to ask a second
/// question that might get a different answer.
class PadState {
  PadState({
    required this.slot,
    required this.identity,
    required Set<PadButton> down,
    required Set<PadButton> pressed,
    required Set<PadButton> released,
    required Map<PadAxis, double> axes,
    required Map<PadAxis, double> raw,
    this.connected = true,
  }) : _down = down,
       _pressed = pressed,
       _released = released,
       _axes = axes,
       _raw = raw;

  /// A pad that is not there.
  ///
  /// Every button up and every axis at rest, rather than whatever it was
  /// holding when it vanished. A controller whose battery dies mid-corner
  /// should not leave the car turning left forever, and the only way to be
  /// sure of that is for absence to read as neutral everywhere at once.
  static final PadState absent = PadState(
    slot: -1,
    identity: const PadIdentity(name: ''),
    down: const {},
    pressed: const {},
    released: const {},
    axes: const {},
    raw: const {},
    connected: false,
  );

  /// Which player this is, counting from nought.
  final int slot;

  final PadIdentity identity;

  /// Whether there is a pad here at all.
  final bool connected;

  final Set<PadButton> _down;
  final Set<PadButton> _pressed;
  final Set<PadButton> _released;
  final Map<PadAxis, double> _axes;
  final Map<PadAxis, double> _raw;

  /// Whether [button] is held now.
  bool isDown(PadButton button) => _down.contains(button);

  /// Whether [button] went down since the last poll.
  ///
  /// True for exactly one poll per press, however many polls the button stays
  /// held for — which is what a jump wants, and what a menu wants.
  bool wasPressed(PadButton button) => _pressed.contains(button);

  /// Whether [button] came up since the last poll.
  bool wasReleased(PadButton button) => _released.contains(button);

  /// Everything held now.
  Iterable<PadButton> get held => _down;

  /// Whether anything at all is being touched.
  ///
  /// What a "press any button to start" screen asks, and what decides which
  /// pad a single-player game should listen to when three are plugged in.
  bool get isActive =>
      _down.isNotEmpty || _axes.values.any((value) => value.abs() > 0.001);

  /// One axis, dead zone and curve already applied.
  double axis(PadAxis axis) => _axes[axis] ?? 0;

  /// One axis exactly as the hardware reported it, normalised to its own range
  /// and otherwise untouched.
  ///
  /// For a calibration screen, and for a game that has a good reason to shape
  /// a stick its own way. Not for ordinary use: the shaped value is the one
  /// that has had the thought put into it.
  double rawAxis(PadAxis axis) => _raw[axis] ?? 0;

  /// A stick as a vector, positive up and to the right.
  ///
  /// Shaped as a vector rather than as two numbers, which is the whole reason
  /// [Shaping] works radially — see there for what per-axis dead zones do to a
  /// diagonal.
  Vector2 stick(PadStick which) => switch (which) {
    PadStick.left => Vector2(axis(PadAxis.leftX), axis(PadAxis.leftY)),
    PadStick.right => Vector2(axis(PadAxis.rightX), axis(PadAxis.rightY)),
  };

  /// A trigger, nought to one.
  double trigger(PadSide side) => switch (side) {
    PadSide.left => axis(PadAxis.leftTrigger),
    PadSide.right => axis(PadAxis.rightTrigger),
  };

  /// The d-pad as a vector, so it can be swapped for a stick without the
  /// caller caring which one somebody is using.
  Vector2 get dpad => Vector2(
    (isDown(PadButton.dpadRight) ? 1 : 0) -
        (isDown(PadButton.dpadLeft) ? 1 : 0),
    (isDown(PadButton.dpadUp) ? 1 : 0) - (isDown(PadButton.dpadDown) ? 1 : 0),
  );

  @override
  String toString() => connected
      ? 'PadState($slot, ${identity.name}, ${_down.length} down)'
      : 'PadState(absent)';
}
