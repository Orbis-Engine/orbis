import 'dart:typed_data';

import 'evdev.dart';
import 'layout.dart';
import 'pad.dart';

/// Where pads come from.
///
/// The seam that keeps everything above it testable. [Pads] never opens a file
/// or calls a platform: it asks a backend what is attached and for whatever
/// bytes have arrived, which means the whole of the interesting behaviour —
/// slots, edges, hot-plug, shaping, resynchronisation — is exercised against a
/// recording rather than against hardware.
abstract class PadBackend {
  /// What is attached now.
  ///
  /// Called on every poll, so it has to be cheap. The Linux implementation
  /// rescans a directory, which is a handful of microseconds and is how a pad
  /// plugged in mid-game is noticed at all.
  List<PadDevice> scan();

  /// Lets go of everything.
  void close();
}

/// One pad, as the platform presents it.
abstract class PadDevice {
  PadIdentity get identity;

  /// What it says it can do.
  EvdevCapabilities get capabilities;

  /// What each axis can report, by its platform code. An axis missing from
  /// here is normalised against [PadAxisRange.stick], which is right for every
  /// pad whose driver bothers to describe itself and harmless for the rest.
  Map<int, PadAxisRange> get ranges;

  /// Whether the device is still usable.
  bool get isAlive;

  /// Everything that has arrived since the last call, as bytes.
  ///
  /// Bytes rather than events, so the decoding — including a read that lands
  /// mid-record — belongs to the part of this package that has tests.
  Uint8List drain();

  /// What is held down and where the axes are, asked of the device directly.
  ///
  /// For two moments: when a pad is first seen, so a trigger already held when
  /// the game starts is not missed, and after the kernel says it dropped
  /// events, when everything being tracked is wrong by an unknown amount.
  ///
  /// Returns the raw button codes and axis values, in the platform's own
  /// numbering — the mapping to names is [PadLayout]'s job, above.
  ({Set<int> buttons, Map<int, int> axes}) resync();

  void close();
}

/// A backend with nothing attached, for a platform with no implementation.
///
/// Not a failure. A game built for the Deck and run on a Mac to check a shader
/// should report no pads and carry on, not refuse to start — and a headless
/// test runner is the same case.
const PadBackend noPads = _NoPads();

class _NoPads implements PadBackend {
  const _NoPads();

  @override
  List<PadDevice> scan() => const [];

  @override
  void close() {}
}

/// A pad driven by a script, for tests and for exercising the layers above
/// without hardware.
class RecordedPad implements PadDevice {
  RecordedPad({
    required this.identity,
    this.capabilities = EvdevCapabilities.none,
    Map<int, PadAxisRange>? ranges,
    Set<int>? held,
    Map<int, int>? resting,
  }) : ranges = ranges ?? const {},
       _held = held ?? <int>{},
       _resting = resting ?? <int, int>{};

  @override
  final PadIdentity identity;

  @override
  final EvdevCapabilities capabilities;

  @override
  final Map<int, PadAxisRange> ranges;

  final Set<int> _held;
  final Map<int, int> _resting;
  final BytesBuilder _queued = BytesBuilder(copy: true);

  bool _alive = true;

  /// Whether the device has been unplugged, as far as anything above can tell.
  @override
  bool get isAlive => _alive;

  /// Unplugs it.
  void unplug() => _alive = false;

  /// Queues one record, as the kernel would have written it.
  void send(int type, int code, int value) =>
      _queued.add(encodeEvdevEvent(type, code, value));

  /// Queues raw bytes, including a deliberately truncated record.
  void sendBytes(List<int> bytes) => _queued.add(bytes);

  /// Queues a button going down or up, and the report that ends the group.
  void button(int code, {required bool down}) {
    send(evKey, code, down ? 1 : 0);
    send(evSyn, synReport, 0);
    if (down) {
      _held.add(code);
    } else {
      _held.remove(code);
    }
  }

  /// Queues an axis moving, and the report that ends the group.
  void axis(int code, int value) {
    send(evAbs, code, value);
    send(evSyn, synReport, 0);
    _resting[code] = value;
  }

  /// Changes what the device would say if asked, without queuing anything.
  ///
  /// What the kernel dropping events looks like from up here: the pad really
  /// is in some state, and the records that would have got us there no longer
  /// exist. There is no other way to set that up, because every other method
  /// on this class both queues a record and moves the state — which is the
  /// whole point of them and exactly what a dropped event is not.
  void drift({Set<int>? buttons, Map<int, int>? axes}) {
    if (buttons != null) {
      _held
        ..clear()
        ..addAll(buttons);
    }
    if (axes != null) {
      _resting
        ..clear()
        ..addAll(axes);
    }
  }

  @override
  Uint8List drain() => _queued.takeBytes();

  @override
  ({Set<int> buttons, Map<int, int> axes}) resync() =>
      (buttons: Set<int>.of(_held), axes: Map<int, int>.of(_resting));

  @override
  void close() => _alive = false;
}

/// A backend whose devices are handed to it.
class RecordedPads implements PadBackend {
  RecordedPads([List<RecordedPad>? pads]) : devices = pads ?? <RecordedPad>[];

  final List<RecordedPad> devices;

  /// Attaches a pad, as though it had just been plugged in.
  void attach(RecordedPad pad) => devices.add(pad);

  /// Detaches one, as though it had been pulled out.
  void detach(RecordedPad pad) {
    pad.unplug();
    devices.remove(pad);
  }

  @override
  List<PadDevice> scan() => devices.where((pad) => pad.isAlive).toList();

  @override
  void close() {
    for (final pad in devices) {
      pad.close();
    }
    devices.clear();
  }
}
