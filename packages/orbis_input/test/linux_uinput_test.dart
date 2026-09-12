/// The read path, end to end, against a gamepad the kernel invented.
///
/// This is the test that says the Linux backend actually works rather than
/// merely parses: uinput creates a real event device, the kernel delivers real
/// records through a real device node, and [LinuxPads] opens it, classifies it
/// from sysfs, asks the driver for its axis ranges and reads it — every step
/// the same as it would be for hardware.
///
/// Skipped everywhere it cannot run, which is most places: it needs Linux, a
/// writable `/dev/uinput`, and a directory where the device nodes actually
/// appear. A container's `/dev` is a tmpfs that devtmpfs never populates, so
/// the node is created and no file shows up for it — the harness mounts a real
/// devtmpfs elsewhere and names it in ORBIS_INPUT_DEV. See
/// tool/check_input_linux.sh for the whole recipe.
@TestOn('linux')
library;

import 'dart:io';

import 'package:orbis_input/orbis_input.dart';
import 'package:test/test.dart';

import '../tool/virtual_pad.dart';

/// Where device nodes appear. `/dev/input` on a real machine.
final String deviceDirectory =
    Platform.environment['ORBIS_INPUT_DEV'] ?? '/dev/input';

/// uinput delivers through the kernel, so a write and the read that sees it
/// are not in the same instant.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 120));

/// Polls until [test] holds or the time runs out, so a slow container does not
/// turn into a flake.
Future<PadFrame> until(Pads pads, bool Function(PadFrame) test) async {
  PadFrame frame = pads.poll();
  for (var i = 0; i < 50 && !test(frame); i++) {
    await settle();
    frame = pads.poll();
  }
  return frame;
}

void main() {
  final reasons = <String>[];
  if (!File('/dev/uinput').existsSync()) reasons.add('no /dev/uinput');
  if (!Directory(deviceDirectory).existsSync()) {
    reasons.add('no $deviceDirectory');
  }
  final skip = reasons.isEmpty
      ? null
      : 'needs a writable uinput and real device nodes: '
            '${reasons.join(', ')}';

  group('a pad the kernel invented', () {
    late VirtualPad pad;
    late Pads pads;

    setUp(() async {
      pad = VirtualPad.create();
      pads = Pads(backend: LinuxPads(devices: deviceDirectory));
      await settle();
    });

    tearDown(() {
      pads.close();
      pad.destroy();
    });

    test('is found, and is the pad we made', () async {
      final frame = await until(pads, (frame) => frame.count > 0);
      expect(frame.count, 1, reason: 'exactly the one pad we created');

      final state = frame.first;
      expect(state.connected, isTrue);
      expect(state.identity.name, 'Orbis Virtual Pad');
      expect(state.identity.vendor, 0x28de, reason: "Valve's vendor id");
      expect(state.identity.product, 0x1205, reason: "a Deck's product id");
      expect(
        frame.events.whereType<PadConnected>(),
        hasLength(1),
        reason: 'and arriving was an event',
      );
    }, skip: skip);

    test('reports a button through the real device node', () async {
      await until(pads, (frame) => frame.count > 0);

      pad.button(0x130, down: true); // BTN_SOUTH
      final down = await until(
        pads,
        (frame) => frame.first.isDown(PadButton.south),
      );
      expect(down.first.isDown(PadButton.south), isTrue);

      pad.button(0x130, down: false);
      final up = await until(
        pads,
        (frame) => !frame.first.isDown(PadButton.south),
      );
      expect(up.first.isDown(PadButton.south), isFalse);
    }, skip: skip);

    test('reads a stick, with up positive', () async {
      await until(pads, (frame) => frame.count > 0);

      pad.axis(0x01, -32768); // ABS_Y, fully away from the player
      final pushed = await until(
        pads,
        (frame) => frame.first.stick(PadStick.left).y > 0.5,
      );
      expect(
        pushed.first.stick(PadStick.left).y,
        greaterThan(0.9),
        reason: 'evdev says positive is down; this engine says up',
      );

      pad.axis(0x01, 0);
      final centred = await until(
        pads,
        (frame) => frame.first.stick(PadStick.left).length < 0.1,
      );
      expect(centred.first.stick(PadStick.left).length, 0);
    }, skip: skip);

    test('reads a trigger against the range the driver reported', () async {
      await until(pads, (frame) => frame.count > 0);

      pad.axis(0x02, 255); // ABS_Z, fully pulled on a byte-wide trigger
      final pulled = await until(
        pads,
        (frame) => frame.first.trigger(PadSide.left) > 0.5,
      );
      expect(pulled.first.trigger(PadSide.left), closeTo(1, 1e-6));
      expect(pulled.first.isDown(PadButton.leftTrigger), isTrue);
    }, skip: skip);

    test('the d-pad arrives as buttons, not as an axis', () async {
      await until(pads, (frame) => frame.count > 0);

      pad.axis(0x11, -1); // ABS_HAT0Y
      final up = await until(
        pads,
        (frame) => frame.first.isDown(PadButton.dpadUp),
      );
      expect(up.first.isDown(PadButton.dpadUp), isTrue);
      expect(up.first.dpad.y, 1);
    }, skip: skip);

    test('unplugging it mid-press leaves nothing held', () async {
      await until(pads, (frame) => frame.count > 0);
      pad.button(0x130, down: true);
      await until(pads, (frame) => frame.first.isDown(PadButton.south));

      // The battery dies with the button down.
      pad.destroy();

      final gone = await until(pads, (frame) => frame.count == 0);
      expect(gone.count, 0);
      expect(
        gone.pad(0).isDown(PadButton.south),
        isFalse,
        reason: 'a vanished pad reads as neutral, not as what it was holding',
      );
      expect(gone.events.whereType<PadDisconnected>(), hasLength(1));
    }, skip: skip);
  });

  test('a second pad gets the second slot', () async {
    final one = VirtualPad.create(name: 'Orbis Virtual Pad One');
    final pads = Pads(backend: LinuxPads(devices: deviceDirectory));
    await until(pads, (frame) => frame.count > 0);

    final two = VirtualPad.create(name: 'Orbis Virtual Pad Two');
    final both = await until(pads, (frame) => frame.count > 1);
    expect(both.count, 2);
    expect(both.pad(0).connected, isTrue);
    expect(both.pad(1).connected, isTrue);

    one.destroy();
    two.destroy();
    pads.close();
  }, skip: skip);
}
