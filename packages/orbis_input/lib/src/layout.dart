import 'evdev.dart';
import 'pad.dart';
import 'shaping.dart';

/// What one axis can actually report, so a reading can be put on a scale.
class PadAxisRange {
  const PadAxisRange({
    required this.minimum,
    required this.maximum,
    this.flat = 0,
    this.fuzz = 0,
  });

  /// What a stick reports when nothing is known about it: a signed 16-bit
  /// range, which is what every driver worth the name uses.
  static const PadAxisRange stick = PadAxisRange(
    minimum: -32768,
    maximum: 32767,
  );

  /// A trigger that reports one byte, which is what the Xbox 360 driver and
  /// most of the drivers modelled on it use.
  static const PadAxisRange trigger = PadAxisRange(minimum: 0, maximum: 255);

  final int minimum;
  final int maximum;

  /// The driver's own idea of a dead zone. Recorded and **not** used for
  /// shaping: drivers set it to nought, to a value that suits a desktop
  /// cursor, or to whatever the hardware's datasheet claimed, and none of
  /// those is a decision about how a game should feel.
  final int flat;

  /// How much the driver says a reading can jitter by.
  final int fuzz;

  /// Whether this looks like a trigger rather than a stick axis.
  ///
  /// A trigger rests at one end of its travel and a stick rests in the middle,
  /// so a range that does not straddle zero is a trigger. This is what makes
  /// an unknown pad degrade predictably rather than wrongly: the pads that map
  /// their right stick onto the axes a modern pad uses for triggers report a
  /// symmetric range there, and are believed rather than being forced into a
  /// table entry nobody has written.
  bool get isUnipolar => minimum >= 0;

  /// [value] on a scale of -1 to 1, centred on the middle of the travel.
  double toSigned(int value) {
    final middle = (minimum + maximum) / 2;
    final half = (maximum - minimum) / 2;
    if (half <= 0) return 0;
    return ((value - middle) / half).clamp(-1.0, 1.0);
  }

  /// [value] on a scale of nought to one.
  double toUnsigned(int value) {
    final span = maximum - minimum;
    if (span <= 0) return 0;
    return ((value - minimum) / span).clamp(0.0, 1.0);
  }
}

/// What is written on the buttons.
///
/// Separate from [PadButton] because the two questions are separate: code asks
/// where a button is, and a prompt on screen asks what it is called. Conflating
/// them is how a game ends up telling a Nintendo player to press A for a
/// button that has B written on it.
class PadLabels {
  const PadLabels(this.south, this.east, this.west, this.north);

  /// What most pads sold for a PC say.
  static const PadLabels xbox = PadLabels('A', 'B', 'X', 'Y');

  /// Sony's shapes, spelled out.
  static const PadLabels playStation = PadLabels(
    'Cross',
    'Circle',
    'Square',
    'Triangle',
  );

  /// Nintendo's, which are the Xbox letters with each pair swapped — the whole
  /// reason positions and labels are different things here.
  static const PadLabels nintendo = PadLabels('B', 'A', 'Y', 'X');

  final String south;
  final String east;
  final String west;
  final String north;

  String of(PadButton button) => switch (button) {
    PadButton.south => south,
    PadButton.east => east,
    PadButton.west => west,
    PadButton.north => north,
    _ => button.name,
  };
}

/// How one physical pad's codes become named buttons and axes.
///
/// **There is no controller database here, on purpose.** The usual approach is
/// to ship a copy of SDL's mapping file, and on the platforms that made it
/// necessary — a browser handing over eighteen numbered buttons, Windows
/// handing over a DirectInput device with no idea what any control is for —
/// it genuinely is necessary. Linux is not one of those platforms. The kernel
/// driver for each pad has already done that work: `BTN_SOUTH` means the
/// bottom face button whether an Xbox pad, a DualSense or a Steam Deck sent
/// it, because the driver author decided so. Taking on a few thousand lines of
/// somebody else's data, with its own licence and its own staleness, to redo a
/// mapping the kernel has already applied would be paying twice.
///
/// So the default layout is the kernel's own codes, and the table below is for
/// the two things the kernel does not decide: what is printed on the buttons,
/// and the handful of pads whose drivers put an axis somewhere unusual. A pad
/// in neither the table nor anybody's plans still works.
class PadLayout {
  const PadLayout({
    this.name = 'Standard',
    this.labels = PadLabels.xbox,
    this.buttons = standardButtons,
    this.axes = standardAxes,
    this.sticks = Shaping.none,
    this.triggers = Shaping.triggers,
  });

  /// The kernel's gamepad codes, which is what almost every pad reports.
  static const Map<int, PadButton> standardButtons = {
    0x130: PadButton.south, // BTN_SOUTH
    0x131: PadButton.east, // BTN_EAST
    0x133: PadButton.north, // BTN_NORTH
    0x134: PadButton.west, // BTN_WEST
    0x136: PadButton.leftShoulder, // BTN_TL
    0x137: PadButton.rightShoulder, // BTN_TR
    0x138: PadButton.leftTrigger, // BTN_TL2
    0x139: PadButton.rightTrigger, // BTN_TR2
    0x13a: PadButton.select, // BTN_SELECT
    0x13b: PadButton.start, // BTN_START
    0x13c: PadButton.guide, // BTN_MODE
    0x13d: PadButton.leftStick, // BTN_THUMBL
    0x13e: PadButton.rightStick, // BTN_THUMBR
    // Some drivers report the d-pad as four buttons rather than as a hat.
    0x220: PadButton.dpadUp, // BTN_DPAD_UP
    0x221: PadButton.dpadDown, // BTN_DPAD_DOWN
    0x222: PadButton.dpadLeft, // BTN_DPAD_LEFT
    0x223: PadButton.dpadRight, // BTN_DPAD_RIGHT
  };

  /// The kernel's axis codes. The hats are not here: they are handled as the
  /// d-pad, because a hat is four buttons that happen to be reported as two
  /// axes and every game wants them as buttons.
  static const Map<int, PadAxis> standardAxes = {
    0x00: PadAxis.leftX, // ABS_X
    0x01: PadAxis.leftY, // ABS_Y
    0x03: PadAxis.rightX, // ABS_RX
    0x04: PadAxis.rightY, // ABS_RY
    0x02: PadAxis.leftTrigger, // ABS_Z
    0x05: PadAxis.rightTrigger, // ABS_RZ
  };

  /// Where an older pad puts its right stick: on the axes a modern one uses
  /// for the triggers.
  static const Map<int, PadAxis> swappedAxes = {
    0x00: PadAxis.leftX,
    0x01: PadAxis.leftY,
    0x02: PadAxis.rightX, // ABS_Z
    0x05: PadAxis.rightY, // ABS_RZ
  };

  /// ABS_HAT0X and ABS_HAT0Y, the d-pad as a pair of axes running -1 to 1.
  static const int hatX = 0x10;
  static const int hatY = 0x11;

  final String name;
  final PadLabels labels;
  final Map<int, PadButton> buttons;
  final Map<int, PadAxis> axes;

  /// How this pad's sticks are shaped.
  ///
  /// [Shaping.none] by default, which is not an oversight: with a real range
  /// read from the driver, the dead zone that matters is the one [Pads] applies
  /// from its own settings, and a layout that also applied one would shape
  /// twice. A table entry sets this only for a pad known to need something
  /// different from the rest.
  final Shaping sticks;

  final Shaping triggers;

  /// The layout for a pad, by what it says it is.
  ///
  /// Falls through three ways of deciding, each less certain than the last:
  /// the table by vendor and product, the table by name for the drivers that
  /// report a maker's whole range under one product id, and the kernel's own
  /// codes for everything else.
  factory PadLayout.of(
    PadIdentity identity, {
    EvdevCapabilities? capabilities,
  }) {
    final keyed = _table[(identity.vendor << 16) | identity.product];
    if (keyed != null) return keyed;

    final name = identity.name.toLowerCase();
    for (final entry in _byName.entries) {
      if (name.contains(entry.key)) return entry.value;
    }

    // A pad with no right-stick axes but with the two a trigger would use is
    // an older pad putting its right stick there. Decided from what the device
    // says it has rather than from a table, so it is right for a pad nobody
    // has ever seen.
    final has = capabilities?.axes;
    if (has != null &&
        !has.contains(0x03) &&
        !has.contains(0x04) &&
        has.contains(0x02) &&
        has.contains(0x05)) {
      return const PadLayout(
        name: 'Standard (right stick on Z)',
        axes: swappedAxes,
      );
    }

    return const PadLayout();
  }

  /// The pads worth knowing about by name, and only the things about them that
  /// the kernel does not already say.
  ///
  /// Short on purpose. Every entry here is a claim about hardware that somebody
  /// has to keep true, and a table that tries to list every pad ever made is a
  /// table that is wrong about most of them.
  static final Map<int, PadLayout> _table = {
    // Valve. The Deck's own controls, and the virtual pad Steam presents to a
    // game it launches — which is what a game actually sees on a Deck, since
    // Steam Input sits between the hardware and everything it starts.
    0x28de1205: const PadLayout(name: 'Steam Deck'),
    0x28de11ff: const PadLayout(name: 'Steam Controller'),
    0x28de1102: const PadLayout(name: 'Steam Controller'),
    // Microsoft. The 360 pad is the shape every PC pad since has copied, and
    // xpad is the driver most third-party pads are read by.
    0x045e028e: const PadLayout(name: 'Xbox 360 Controller'),
    0x045e02d1: const PadLayout(name: 'Xbox One Controller'),
    0x045e02ea: const PadLayout(name: 'Xbox One S Controller'),
    0x045e0b12: const PadLayout(name: 'Xbox Series Controller'),
    0x045e0b13: const PadLayout(name: 'Xbox Series Controller'),
    // Sony. hid-playstation reports the kernel's codes correctly, so the only
    // thing worth saying is what is printed on the buttons.
    0x054c05c4: const PadLayout(
      name: 'DualShock 4',
      labels: PadLabels.playStation,
    ),
    0x054c09cc: const PadLayout(
      name: 'DualShock 4',
      labels: PadLabels.playStation,
    ),
    0x054c0ce6: const PadLayout(
      name: 'DualSense',
      labels: PadLabels.playStation,
    ),
    0x054c0df2: const PadLayout(
      name: 'DualSense Edge',
      labels: PadLabels.playStation,
    ),
    // Nintendo. The positions are the kernel's; the letters are swapped in
    // both pairs, which is the case PadLabels exists for.
    0x057e2009: const PadLayout(
      name: 'Switch Pro Controller',
      labels: PadLabels.nintendo,
    ),
    0x057e2017: const PadLayout(
      name: 'Switch Online SNES Controller',
      labels: PadLabels.nintendo,
    ),
  };

  /// For the drivers that report a whole range of pads under one identifier,
  /// where the name is the only thing that distinguishes them.
  static final Map<String, PadLayout> _byName = {
    'steam deck': const PadLayout(name: 'Steam Deck'),
    'steam controller': const PadLayout(name: 'Steam Controller'),
    'x-box': const PadLayout(name: 'Xbox Controller'),
    'xbox': const PadLayout(name: 'Xbox Controller'),
    'dualsense': const PadLayout(
      name: 'DualSense',
      labels: PadLabels.playStation,
    ),
    'dualshock': const PadLayout(
      name: 'DualShock',
      labels: PadLabels.playStation,
    ),
    'nintendo': const PadLayout(
      name: 'Nintendo Controller',
      labels: PadLabels.nintendo,
    ),
  };

  @override
  String toString() => 'PadLayout($name)';
}
