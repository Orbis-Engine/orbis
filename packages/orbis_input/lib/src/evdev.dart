/// Reading Linux's input protocol, with nothing platform-specific in it.
///
/// Everything here is bytes in and values out, so the part of the Linux
/// backend where the bugs actually live — a read that stops halfway through a
/// record, a capability bitmap printed most significant word first, the
/// kernel telling us it threw events away — is testable on any machine,
/// against recordings, without a controller or a Linux box.
library;

import 'dart:typed_data';

/// Event types, from `linux/input-event-codes.h`.
const int evSyn = 0x00;
const int evKey = 0x01;
const int evRel = 0x02;
const int evAbs = 0x03;

/// The end of one consistent group of changes.
const int synReport = 0;

/// The kernel's admission that its buffer overflowed and it discarded events.
///
/// Not an error and not ignorable: whatever state we were tracking is now
/// wrong by an unknown amount, and the only correct response is to ask the
/// device what it currently is rather than to carry on applying differences to
/// a state that has already diverged.
const int synDropped = 3;

/// The first of the gamepad buttons. A device that reports this is a gamepad
/// as far as the kernel is concerned, which is the classification used here.
const int btnGamepad = 0x130;

/// One record as the kernel writes it.
class EvdevEvent {
  const EvdevEvent(this.type, this.code, this.value);

  final int type;
  final int code;
  final int value;

  @override
  String toString() => 'EvdevEvent($type, $code, $value)';

  @override
  bool operator ==(Object other) =>
      other is EvdevEvent &&
      other.type == type &&
      other.code == code &&
      other.value == value;

  @override
  int get hashCode => Object.hash(type, code, value);
}

/// Turns the bytes read from an event device into events.
///
/// A record is a timestamp, a type, a code and a value, and the timestamp is
/// two machine words — so a record is 24 bytes on the 64-bit machines this
/// engine targets and 16 on a 32-bit one. The width is a parameter rather than
/// a constant because getting it wrong does not fail, it silently reads
/// garbage: every field lands in the wrong place and the device appears to
/// report buttons nobody pressed.
///
/// **Partial records are the reason this is a class.** A read from an event
/// device returns whole records when it can, and a buffer that fills mid-record
/// returns a fragment — so the leftover has to be carried to the next read
/// rather than discarded. A decoder that assumed whole records would work
/// perfectly until the first busy frame and then drop an event, which is the
/// kind of fault that gets blamed on the hardware.
class EvdevDecoder {
  EvdevDecoder({this.timeBytes = 16});

  /// How wide the leading timestamp is: two 64-bit words on a 64-bit kernel,
  /// two 32-bit ones on a 32-bit kernel.
  final int timeBytes;

  /// How many bytes one record takes.
  int get recordBytes => timeBytes + 8;

  final BytesBuilder _spare = BytesBuilder(copy: true);

  /// Everything complete in [chunk], with any trailing fragment kept for next
  /// time.
  List<EvdevEvent> decode(List<int> chunk) {
    if (chunk.isEmpty && _spare.isEmpty) return const [];

    final Uint8List bytes;
    if (_spare.isEmpty) {
      bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    } else {
      _spare.add(chunk);
      bytes = _spare.takeBytes();
    }

    final whole = bytes.length ~/ recordBytes;
    final events = <EvdevEvent>[];
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    for (var i = 0; i < whole; i++) {
      final at = i * recordBytes;
      events.add(
        EvdevEvent(
          view.getUint16(at + timeBytes, Endian.host),
          view.getUint16(at + timeBytes + 2, Endian.host),
          view.getInt32(at + timeBytes + 4, Endian.host),
        ),
      );
    }

    final left = bytes.length - whole * recordBytes;
    if (left > 0) _spare.add(bytes.sublist(whole * recordBytes));
    return events;
  }

  /// Throws away any half-read record.
  ///
  /// For a device that has gone away, or one being resynchronised after the
  /// kernel dropped events — in both cases what is buffered describes a past
  /// that is no longer being caught up with.
  void reset() => _spare.clear();

  /// Whether a fragment is being carried. For tests, and for a log that wants
  /// to say why an event has not arrived yet.
  bool get hasPartial => _spare.isNotEmpty;
}

/// Encodes one record, which is what a test fixture and the virtual pad
/// harness both need.
Uint8List encodeEvdevEvent(
  int type,
  int code,
  int value, {
  int timeBytes = 16,
}) {
  final bytes = Uint8List(timeBytes + 8);
  final view = ByteData.view(bytes.buffer);
  view.setUint16(timeBytes, type, Endian.host);
  view.setUint16(timeBytes + 2, code, Endian.host);
  view.setInt32(timeBytes + 4, value, Endian.host);
  return bytes;
}

/// What a device says it can do, as sysfs prints it.
///
/// Read from sysfs rather than asked of the device, because it answers the
/// question "is this a gamepad" without opening anything — which matters when
/// half the event devices on a desktop are a keyboard, a mouse, a lid switch
/// and a power button that no game has any business opening.
class EvdevCapabilities {
  const EvdevCapabilities({
    required this.events,
    required this.keys,
    required this.axes,
  });

  /// Nothing at all, for a device whose sysfs entry could not be read.
  static const EvdevCapabilities none = EvdevCapabilities(
    events: {},
    keys: {},
    axes: {},
  );

  /// Which event types it reports.
  final Set<int> events;

  /// Which key and button codes it can send.
  final Set<int> keys;

  /// Which absolute axes it has.
  final Set<int> axes;

  /// Whether this is something a game should listen to.
  ///
  /// The kernel's own test, and deliberately not a cleverer one: a device that
  /// claims a gamepad button is a gamepad. Anything looser picks up a laptop's
  /// lid switch; anything tighter has to guess at what a pad ought to have,
  /// and arcade sticks, racing wheels and flight yokes all fail whichever
  /// guess is made.
  bool get isGamepad => events.contains(evKey) && keys.contains(btnGamepad);

  /// Parses one of sysfs's bitmap lines.
  ///
  /// The format is worth stating because it is the opposite of what anybody
  /// assumes: space-separated 64-bit hexadecimal words, **most significant
  /// first**, with the last word holding bits 0 to 63. So `3000000000000 0 0 0
  /// 0` is five words in which the leftmost covers bits 256 to 319, and the two
  /// bits set in it are 304 and 305 — the south and east face buttons. Reading
  /// it left to right as ascending words instead puts every capability of every
  /// pad in the wrong place, and the failure is a pad that is detected and then
  /// appears to have no buttons.
  static Set<int> parseBitmap(String line) {
    final words = line.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return const {};
    final bits = <int>{};
    final reversed = words.toList().reversed.toList();
    for (var w = 0; w < reversed.length; w++) {
      // Read as two 32-bit halves rather than as one 64-bit number, because
      // a word with its top bit set does not fit in Dart's signed int and
      // `int.tryParse` answers null rather than wrapping. Parsed whole, a
      // capability line like `8000000000000000` would therefore be dropped
      // in its entirety and the device would appear to have none of the
      // buttons in that word — a pad detected and then apparently empty.
      //
      // Sixty-four bits to a word assumes a 64-bit kernel, as the record
      // width in [EvdevDecoder] does.
      final text = reversed[w];
      if (text.length > 16) continue;
      final at = text.length > 8 ? text.length - 8 : 0;
      final low = int.tryParse(text.substring(at), radix: 16);
      final high = at == 0 ? 0 : int.tryParse(text.substring(0, at), radix: 16);
      if (low == null || high == null) continue;
      for (var bit = 0; bit < 32; bit++) {
        if (low & (1 << bit) != 0) bits.add(w * 64 + bit);
        if (high & (1 << bit) != 0) bits.add(w * 64 + 32 + bit);
      }
    }
    return bits;
  }

  /// The three bitmap lines as sysfs prints them.
  factory EvdevCapabilities.parse({
    required String ev,
    required String key,
    required String abs,
  }) => EvdevCapabilities(
    events: parseBitmap(ev),
    keys: parseBitmap(key),
    axes: parseBitmap(abs),
  );
}
