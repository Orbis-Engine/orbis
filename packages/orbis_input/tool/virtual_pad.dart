/// A gamepad that does not exist, for exercising the one that would.
///
/// There is no controller attached to the machine this was written on, and no
/// Steam Deck. Linux can be asked to invent one: `/dev/uinput` takes the same
/// description a driver would give — which buttons, which axes, what each axis
/// can report — and creates a real event device that the rest of the system,
/// including [LinuxPads], cannot tell from hardware. That is what makes the
/// read path testable rather than merely reviewable: the bytes come from the
/// kernel through the same device node a real pad's would.
///
/// What it does not prove is written down in the report rather than here, but
/// the short version is that this exercises every line of ours and none of any
/// real driver's.
///
/// Run it on its own to leave a pad sitting there for something else to read:
///
///   dart run tool/virtual_pad.dart --seconds 10
///
/// It needs `/dev/uinput`, which means root or membership of a group that can
/// write it. In a container that is `--privileged`; see
/// tool/check_input_linux.sh for the whole recipe.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// The same measured constants the backend uses, and measured the same way:
// printed from the kernel headers on aarch64 and x86_64, identical on both.
const int _oRdWr = 2;
const int _oNonBlock = 0x800;

const int _uiSetEvBit = 0x40045564;
const int _uiSetKeyBit = 0x40045565;
const int _uiSetAbsBit = 0x40045567;
const int _uiDevSetup = 0x405c5503;
const int _uiAbsSetup = 0x401c5504;
const int _uiDevCreate = 0x5501;
const int _uiDevDestroy = 0x5502;

const int _evSyn = 0x00;
const int _evKey = 0x01;
const int _evAbs = 0x03;
const int _synReport = 0;

/// `struct uinput_setup`: an eight-byte id, an eighty-byte name, and a count.
const int _setupBytes = 92;

/// `struct uinput_abs_setup`: a code, two bytes of padding, and an absinfo.
const int _absSetupBytes = 28;

/// One record, on a 64-bit kernel.
const int _eventBytes = 24;

typedef _OpenNative = Int Function(Pointer<Utf8>, Int);
typedef _OpenDart = int Function(Pointer<Utf8>, int);
typedef _IoctlNative = Int Function(Int, UnsignedLong, Pointer<Void>);
typedef _IoctlDart = int Function(int, int, Pointer<Void>);
typedef _WriteNative = IntPtr Function(Int, Pointer<Void>, IntPtr);
typedef _WriteDart = int Function(int, Pointer<Void>, int);
typedef _CloseNative = Int Function(Int);
typedef _CloseDart = int Function(int);

/// A pad invented through uinput.
class VirtualPad {
  VirtualPad._(this._fd, this._libc);

  /// Creates one, or throws with what went wrong.
  ///
  /// Defaults to what a Steam Deck reports: Valve's vendor id, the Deck's
  /// product id, the kernel's standard gamepad buttons, two sticks on a signed
  /// 16-bit range, two triggers on a byte, and the d-pad as a hat.
  factory VirtualPad.create({
    String name = 'Orbis Virtual Pad',
    int vendor = 0x28de,
    int product = 0x1205,
    int version = 0x0111,
    List<int>? buttons,
    Map<int, List<int>>? axes,
  }) {
    final process = DynamicLibrary.process();
    final libc = _Libc(
      process.lookupFunction<_OpenNative, _OpenDart>('open'),
      process.lookupFunction<_IoctlNative, _IoctlDart>('ioctl'),
      process.lookupFunction<_WriteNative, _WriteDart>('write'),
      process.lookupFunction<_CloseNative, _CloseDart>('close'),
    );

    final path = '/dev/uinput'.toNativeUtf8();
    final int fd;
    try {
      fd = libc.open(path, _oRdWr | _oNonBlock);
    } finally {
      calloc.free(path);
    }
    if (fd < 0) {
      throw StateError(
        'could not open /dev/uinput. It needs the uinput module and write '
        'permission on the node — in a container, --privileged.',
      );
    }

    final pad = VirtualPad._(fd, libc);
    final keys = buttons ?? standardButtons;
    final ranges = axes ?? standardAxes;

    pad._must(
      libc.ioctl(fd, _uiSetEvBit, Pointer.fromAddress(_evKey)),
      'UI_SET_EVBIT EV_KEY',
    );
    for (final key in keys) {
      pad._must(
        libc.ioctl(fd, _uiSetKeyBit, Pointer.fromAddress(key)),
        'UI_SET_KEYBIT $key',
      );
    }
    pad._must(
      libc.ioctl(fd, _uiSetEvBit, Pointer.fromAddress(_evAbs)),
      'UI_SET_EVBIT EV_ABS',
    );

    final absSetup = calloc<Uint8>(_absSetupBytes);
    try {
      for (final entry in ranges.entries) {
        pad._must(
          libc.ioctl(fd, _uiSetAbsBit, Pointer.fromAddress(entry.key)),
          'UI_SET_ABSBIT ${entry.key}',
        );
        final view = ByteData.view(
          absSetup.asTypedList(_absSetupBytes).buffer,
          0,
          _absSetupBytes,
        );
        for (var i = 0; i < _absSetupBytes; i++) {
          view.setUint8(i, 0);
        }
        view.setUint16(0, entry.key, Endian.host);
        view.setInt32(4 + 4, entry.value[0], Endian.host); // minimum
        view.setInt32(4 + 8, entry.value[1], Endian.host); // maximum
        pad._must(
          libc.ioctl(fd, _uiAbsSetup, absSetup.cast()),
          'UI_ABS_SETUP ${entry.key}',
        );
      }
    } finally {
      calloc.free(absSetup);
    }

    final setup = calloc<Uint8>(_setupBytes);
    try {
      final view = ByteData.view(
        setup.asTypedList(_setupBytes).buffer,
        0,
        _setupBytes,
      );
      view.setUint16(0, 0x03, Endian.host); // BUS_USB
      view.setUint16(2, vendor, Endian.host);
      view.setUint16(4, product, Endian.host);
      view.setUint16(6, version, Endian.host);
      final bytes = name.codeUnits.take(79).toList();
      for (var i = 0; i < bytes.length; i++) {
        view.setUint8(8 + i, bytes[i]);
      }
      pad._must(libc.ioctl(fd, _uiDevSetup, setup.cast()), 'UI_DEV_SETUP');
    } finally {
      calloc.free(setup);
    }

    pad._must(libc.ioctl(fd, _uiDevCreate, nullptr), 'UI_DEV_CREATE');
    return pad;
  }

  /// The kernel's gamepad buttons: four faces, two shoulders, two triggers,
  /// select, start, guide and the two sticks.
  static const List<int> standardButtons = [
    0x130, 0x131, 0x133, 0x134, // south east north west
    0x136, 0x137, 0x138, 0x139, // shoulders and triggers
    0x13a, 0x13b, 0x13c, // select start guide
    0x13d, 0x13e, // the sticks pressed in
  ];

  /// Two sticks on a signed sixteen-bit range, two triggers on a byte, and
  /// the d-pad as a hat.
  static const Map<int, List<int>> standardAxes = {
    0x00: [-32768, 32767], // ABS_X
    0x01: [-32768, 32767], // ABS_Y
    0x03: [-32768, 32767], // ABS_RX
    0x04: [-32768, 32767], // ABS_RY
    0x02: [0, 255], // ABS_Z
    0x05: [0, 255], // ABS_RZ
    0x10: [-1, 1], // ABS_HAT0X
    0x11: [-1, 1], // ABS_HAT0Y
  };

  final int _fd;
  final _Libc _libc;
  bool _alive = true;

  void _must(int result, String what) {
    if (result < 0) {
      destroy();
      throw StateError('$what failed');
    }
  }

  /// Sends one record.
  void send(int type, int code, int value) {
    if (!_alive) return;
    final record = calloc<Uint8>(_eventBytes);
    try {
      final view = ByteData.view(
        record.asTypedList(_eventBytes).buffer,
        0,
        _eventBytes,
      );
      view.setUint16(16, type, Endian.host);
      view.setUint16(18, code, Endian.host);
      view.setInt32(20, value, Endian.host);
      _libc.write(_fd, record.cast(), _eventBytes);
    } finally {
      calloc.free(record);
    }
  }

  /// Ends a group of changes, which is what makes the kernel deliver them.
  void report() => send(_evSyn, _synReport, 0);

  /// A button down or up, and the report that publishes it.
  void button(int code, {required bool down}) {
    send(_evKey, code, down ? 1 : 0);
    report();
  }

  /// An axis moving, and the report that publishes it.
  void axis(int code, int value) {
    send(_evAbs, code, value);
    report();
  }

  /// Unplugs it. The event node disappears, exactly as it would for a pad
  /// whose battery has died.
  void destroy() {
    if (!_alive) return;
    _alive = false;
    _libc.ioctl(_fd, _uiDevDestroy, nullptr);
    _libc.close(_fd);
  }
}

class _Libc {
  _Libc(this.open, this.ioctl, this.write, this.close);

  final _OpenDart open;
  final _IoctlDart ioctl;
  final _WriteDart write;
  final _CloseDart close;
}

/// Leaves a pad attached for as long as it is asked to, moving a little so
/// something watching has changes to see.
Future<void> main(List<String> arguments) async {
  if (!Platform.isLinux) {
    stderr.writeln('uinput is Linux only');
    exit(2);
  }
  var seconds = 5;
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--seconds') {
      seconds = int.tryParse(arguments[i + 1]) ?? seconds;
    }
  }

  final pad = VirtualPad.create();
  stdout.writeln('[virtual-pad] created; holding for ${seconds}s');

  final until = DateTime.now().add(Duration(seconds: seconds));
  var tick = 0;
  while (DateTime.now().isBefore(until)) {
    pad
      ..button(0x130, down: tick.isEven)
      ..axis(0x00, tick.isEven ? 32767 : -32768)
      ..axis(0x02, tick.isEven ? 255 : 0);
    tick++;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  pad.destroy();
  stdout.writeln('[virtual-pad] destroyed');
}
