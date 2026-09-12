/// Reading gamepads on Linux, through evdev.
///
/// Two halves, and neither of them is compiled code of ours. Finding pads and
/// deciding which event devices are pads is done by reading sysfs, which is
/// plain text files; reading a pad is done with `dart:ffi` straight to libc,
/// because the four calls involved — open, read, ioctl, close — are the whole
/// of the interface and wrapping them in a plugin would mean a build system, a
/// shared library and a platform channel to carry four integers across.
///
/// **Why evdev rather than the joystick interface.** `/dev/input/js*` is the
/// older interface and is easier to read — fixed-size records, no ioctls
/// needed to get going. It is also deprecated, provides no way to ask what a
/// button means, reports axes without their ranges, and on a modern
/// distribution is provided by a compatibility layer that may not be loaded at
/// all. evdev is what everything else on a Linux desktop uses, it is what the
/// kernel's gamepad drivers describe themselves in, and it is what a Steam
/// Deck presents.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'backend.dart';
import 'evdev.dart';
import 'layout.dart';
import 'pad.dart';

// Measured rather than assumed: a small C program printed each of these from
// the kernel headers on aarch64 and on x86_64, and every value below is
// identical on both. They are built by the same `_IOC` macro from an
// architecture-independent encoding, which is why — but a constant that is
// wrong by one bit fails as a device that reports nothing, so it was checked.
const int _oRdOnly = 0;
const int _oNonBlock = 0x800; // 04000
const int _oCloExec = 0x80000; // 02000000

const int _eviocgid = 0x80084502;
const int _eviocgname256 = 0x81004506;

/// `EVIOCGABS(code)`, which is one request per axis.
int _eviocgabs(int code) => 0x80184540 + code;

/// `EVIOCGKEY(96)` — 96 bytes is 768 bits, enough for every key code.
const int _eviocgkey96 = 0x80604518;

const int _eagain = 11;
const int _enodev = 19;
const int _eintr = 4;

/// One `struct input_absinfo`: six 32-bit fields.
const int _absinfoBytes = 24;

typedef _OpenNative = Int Function(Pointer<Utf8>, Int);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _ReadNative = IntPtr Function(Int, Pointer<Void>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Void>, int);
typedef _CloseNative = Int Function(Int);
typedef _CloseDart = int Function(int);

// ioctl is variadic in C. Declared here with its third argument fixed, which
// is correct on the two architectures this runs on: on Linux's x86-64 and
// AArch64 ABIs a variadic argument in a register position is passed exactly as
// a fixed one would be. It is *not* true on Apple's AArch64, which is why this
// file is Linux-only rather than merely Linux-first.
typedef _IoctlNative = Int Function(Int, UnsignedLong, Pointer<Void>);
typedef _IoctlDart = int Function(int, int, Pointer<Void>);

/// libc, as the process already has it.
class _Libc {
  _Libc._(this.open, this.read, this.close, this.ioctl, this._errno);

  factory _Libc.process() {
    final process = DynamicLibrary.process();
    return _Libc._(
      process.lookupFunction<_OpenNative, _OpenDart>('open'),
      process.lookupFunction<_ReadNative, _ReadDart>('read'),
      process.lookupFunction<_CloseNative, _CloseDart>('close'),
      process.lookupFunction<_IoctlNative, _IoctlDart>('ioctl'),
      process
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__errno_location',
          ),
    );
  }

  final _OpenDart open;
  final _ReadDart read;
  final _CloseDart close;
  final _IoctlDart ioctl;
  final Pointer<Int32> Function() _errno;

  /// Why the last call failed.
  ///
  /// Read through `__errno_location` rather than from a global, because errno
  /// is per-thread and Dart's FFI calls may not be on the thread a global
  /// would have been captured on.
  int get errno => _errno().value;
}

/// Gamepads on this Linux machine.
class LinuxPads implements PadBackend {
  LinuxPads({this.devices = '/dev/input', this.sysfs = '/sys/class/input'}) {
    // Checked before libc is looked up rather than after. `__errno_location`
    // is glibc's spelling and does not exist on macOS, so an accidental
    // construction there would fail as a missing symbol rather than as the
    // plain statement that this is the wrong platform.
    if (!Platform.isLinux) {
      throw UnsupportedError('LinuxPads reads evdev, which is Linux only');
    }
    _libc = _Libc.process();
  }

  /// Where the device nodes are.
  ///
  /// Settable because a container's `/dev` is a tmpfs with nothing in it, so
  /// the harness that exercises this mounts a real devtmpfs elsewhere and
  /// points here at it. A test tree does the same.
  final String devices;

  /// Where the descriptions are.
  final String sysfs;

  late final _Libc _libc;
  final Map<String, _LinuxDevice> _open = {};

  /// Devices that look like pads but could not be opened, and why.
  ///
  /// Almost always a permission: reading an event device needs membership of
  /// the `input` group on most distributions. Worth being able to say, because
  /// the alternative is a game that reports no controller while one is plainly
  /// plugged in.
  final List<String> problems = [];

  @override
  List<PadDevice> scan() {
    problems.clear();
    final found = <String, _LinuxDevice>{};

    final root = Directory(sysfs);
    if (!root.existsSync()) return const [];

    for (final entry in root.listSync()) {
      final node = entry.path.split(Platform.pathSeparator).last;
      if (!RegExp(r'^event\d+$').hasMatch(node)) continue;

      final already = _open[node];
      if (already != null && already.isAlive) {
        found[node] = already;
        continue;
      }

      final description = '${entry.path}/device';
      final capabilities = EvdevCapabilities.parse(
        ev: _text('$description/capabilities/ev'),
        key: _text('$description/capabilities/key'),
        abs: _text('$description/capabilities/abs'),
      );
      if (!capabilities.isGamepad) continue;

      final identity = PadIdentity(
        name: _text('$description/name'),
        vendor: _hex('$description/id/vendor'),
        product: _hex('$description/id/product'),
        version: _hex('$description/id/version'),
        bus: _hex('$description/id/bustype'),
        uniq: _text('$description/uniq'),
        path: _text('$description/phys'),
      );

      final device = _openNode('$devices/$node', identity, capabilities);
      if (device != null) found[node] = device;
    }

    // Anything that was open and is no longer listed has gone.
    for (final entry in _open.entries.toList()) {
      if (!found.containsKey(entry.key)) {
        entry.value.close();
        _open.remove(entry.key);
      }
    }
    _open
      ..clear()
      ..addAll(found);
    return found.values.toList();
  }

  _LinuxDevice? _openNode(
    String path,
    PadIdentity identity,
    EvdevCapabilities capabilities,
  ) {
    final name = path.toNativeUtf8();
    try {
      final fd = _libc.open(name, _oRdOnly | _oNonBlock | _oCloExec);
      if (fd < 0) {
        problems.add('$path: errno ${_libc.errno}');
        return null;
      }
      return _LinuxDevice(_libc, fd, identity, capabilities);
    } finally {
      calloc.free(name);
    }
  }

  String _text(String path) {
    try {
      return File(path).readAsStringSync().trim();
    } on FileSystemException {
      return '';
    }
  }

  int _hex(String path) => int.tryParse(_text(path), radix: 16) ?? 0;

  @override
  void close() {
    for (final device in _open.values) {
      device.close();
    }
    _open.clear();
  }
}

/// One open event device.
class _LinuxDevice implements PadDevice {
  _LinuxDevice(this._libc, this._fd, this.identity, this.capabilities) {
    _buffer = calloc<Uint8>(_bufferBytes);
    _scratch = calloc<Uint8>(_scratchBytes);
    _readRanges();

    // Whatever sysfs did not give, asked of the driver directly. A device
    // opened by path — anything outside the usual sysfs layout, including a
    // node created for a test — has no description sitting beside it, and a
    // pad with no vendor or product would be handed the fallback layout when
    // the driver knows perfectly well what it is.
    final named = identity.name.isEmpty ? _name() : identity.name;
    final id = identity.vendor == 0 && identity.product == 0
        ? _id()
        : (
            bus: identity.bus,
            vendor: identity.vendor,
            product: identity.product,
            version: identity.version,
          );
    if (named != identity.name ||
        id.vendor != identity.vendor ||
        id.product != identity.product) {
      identity = PadIdentity(
        name: named,
        vendor: id.vendor,
        product: id.product,
        version: id.version,
        bus: id.bus,
        uniq: identity.uniq,
        path: identity.path,
      );
    }
  }

  /// What the driver says this device is: bus, vendor, product and version,
  /// as four sixteen-bit numbers.
  ({int bus, int vendor, int product, int version}) _id() {
    if (_libc.ioctl(_fd, _eviocgid, _scratch.cast()) < 0) {
      return (bus: 0, vendor: 0, product: 0, version: 0);
    }
    final view = ByteData.view(_scratch.asTypedList(8).buffer, 0, 8);
    return (
      bus: view.getUint16(0, Endian.host),
      vendor: view.getUint16(2, Endian.host),
      product: view.getUint16(4, Endian.host),
      version: view.getUint16(6, Endian.host),
    );
  }

  /// Sixteen records at a time. A pad at its fastest sends a few hundred
  /// records a second, so this empties it in one call at any frame rate worth
  /// having, and the loop in [drain] covers the rest.
  static const int _bufferBytes = 24 * 16;
  static const int _scratchBytes = 256;

  final _Libc _libc;
  final int _fd;

  @override
  PadIdentity identity;

  @override
  final EvdevCapabilities capabilities;

  @override
  final Map<int, PadAxisRange> ranges = {};

  late final Pointer<Uint8> _buffer;
  late final Pointer<Uint8> _scratch;

  bool _alive = true;

  @override
  bool get isAlive => _alive;

  String _name() {
    if (_libc.ioctl(_fd, _eviocgname256, _scratch.cast()) < 0) return '';
    final bytes = _scratch.asTypedList(_scratchBytes);
    final end = bytes.indexOf(0);
    return String.fromCharCodes(bytes.sublist(0, end < 0 ? 0 : end));
  }

  /// Asks the driver what each axis can report.
  ///
  /// The one thing sysfs does not expose, and the one thing that cannot be
  /// guessed: a trigger that runs 0 to 255 and one that runs 0 to 1023 look
  /// identical until somebody pulls them, at which point the second is at a
  /// quarter strength for its whole travel.
  void _readRanges() {
    for (final code in capabilities.axes) {
      if (_libc.ioctl(_fd, _eviocgabs(code), _scratch.cast()) < 0) continue;
      final view = ByteData.view(
        _scratch.asTypedList(_absinfoBytes).buffer,
        0,
        _absinfoBytes,
      );
      ranges[code] = PadAxisRange(
        minimum: view.getInt32(4, Endian.host),
        maximum: view.getInt32(8, Endian.host),
        fuzz: view.getInt32(12, Endian.host),
        flat: view.getInt32(16, Endian.host),
      );
    }
  }

  @override
  Uint8List drain() {
    if (!_alive) return Uint8List(0);
    final out = BytesBuilder(copy: true);
    while (true) {
      final n = _libc.read(_fd, _buffer.cast(), _bufferBytes);
      if (n > 0) {
        out.add(_buffer.asTypedList(n));
        // A short read has emptied the queue; a full one may not have.
        if (n < _bufferBytes) break;
        continue;
      }
      if (n == 0) break;
      final errno = _libc.errno;
      if (errno == _eagain) break;
      if (errno == _eintr) continue;
      // ENODEV is the pad being unplugged while we were reading it, which is
      // the ordinary way a wireless pad goes away rather than an error.
      if (errno == _enodev) _alive = false;
      break;
    }
    return out.takeBytes();
  }

  @override
  ({Set<int> buttons, Map<int, int> axes}) resync() {
    final buttons = <int>{};
    if (_alive && _libc.ioctl(_fd, _eviocgkey96, _scratch.cast()) >= 0) {
      final bits = _scratch.asTypedList(96);
      for (var byte = 0; byte < bits.length; byte++) {
        if (bits[byte] == 0) continue;
        for (var bit = 0; bit < 8; bit++) {
          if (bits[byte] & (1 << bit) != 0) buttons.add(byte * 8 + bit);
        }
      }
    }

    final axes = <int, int>{};
    if (_alive) {
      for (final code in capabilities.axes) {
        if (_libc.ioctl(_fd, _eviocgabs(code), _scratch.cast()) < 0) continue;
        final view = ByteData.view(
          _scratch.asTypedList(_absinfoBytes).buffer,
          0,
          _absinfoBytes,
        );
        axes[code] = view.getInt32(0, Endian.host);
      }
    }
    return (buttons: buttons, axes: axes);
  }

  /// Whether the native memory has already been given back.
  ///
  /// Separate from [_alive], which says whether the pad is still there — a
  /// device can stop being alive several ways (unplugged mid-read, dropped by
  /// a rescan) without anything having been freed yet, so one flag cannot
  /// answer both questions.
  bool _closed = false;

  @override
  void close() {
    // Idempotent, because being closed twice is the ordinary path rather than
    // a mistake: a rescan closes a device that has gone, and the poll that
    // notices the same absence closes it again on the way to reporting the
    // disconnection. Guarding on liveness instead let both through and freed
    // the same two buffers twice, which libc catches as a double free and
    // takes the process down with.
    if (_closed) return;
    _closed = true;
    _alive = false;
    _libc.close(_fd);
    calloc.free(_buffer);
    calloc.free(_scratch);
  }
}
