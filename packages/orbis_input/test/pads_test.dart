import 'package:orbis_input/orbis_input.dart';
import 'package:test/test.dart';

const btnSouth = 0x130;
const btnStart = 0x13b;
const absX = 0x00;
const absY = 0x01;
const absZ = 0x02;
const absHat0X = 0x10;
const absHat0Y = 0x11;

RecordedPad pad({
  String name = 'Orbis Virtual Pad',
  int vendor = 0x28de,
  int product = 0x1205,
  String uniq = '',
  String path = 'usb-0000:00:14.0-1/input0',
  Set<int>? held,
  Map<int, int>? resting,
}) => RecordedPad(
  identity: PadIdentity(
    name: name,
    vendor: vendor,
    product: product,
    uniq: uniq,
    path: path,
  ),
  capabilities: EvdevCapabilities.parse(
    ev: 'b',
    key: '3000000000000 0 0 0 0',
    abs: '30003',
  ),
  ranges: const {
    absX: PadAxisRange.stick,
    absY: PadAxisRange.stick,
    absZ: PadAxisRange.trigger,
    absHat0X: PadAxisRange(minimum: -1, maximum: 1),
    absHat0Y: PadAxisRange(minimum: -1, maximum: 1),
  },
  held: held,
  resting: resting,
);

void main() {
  group('state and edges', () {
    test('a button held reads as down on every poll', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));

      device.button(btnSouth, down: true);
      expect(pads.poll().first.isDown(PadButton.south), isTrue);
      expect(pads.poll().first.isDown(PadButton.south), isTrue);
    });

    test('a press is reported for exactly one poll', () {
      // The thing every game writes for itself if the engine does not: a jump
      // that fires once rather than every frame the button is held.
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));

      // Connected first. A pad is adopted at the moment it is seen, taking
      // whatever it is already holding as its starting point — so a press
      // queued before that first poll is indistinguishable from a button that
      // was already down when the game started, and is deliberately not an
      // edge.
      pads.poll();

      device.button(btnSouth, down: true);
      expect(pads.poll().first.wasPressed(PadButton.south), isTrue);
      expect(pads.poll().first.wasPressed(PadButton.south), isFalse);

      device.button(btnSouth, down: false);
      final let = pads.poll().first;
      expect(let.wasReleased(PadButton.south), isTrue);
      expect(let.isDown(PadButton.south), isFalse);
    });

    test('a key repeat is not a new press', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      device.button(btnSouth, down: true);
      pads.poll();

      // Value 2 is the kernel saying the key is still held.
      device
        ..send(evKey, btnSouth, 2)
        ..send(evSyn, synReport, 0);
      final frame = pads.poll();
      expect(frame.first.wasPressed(PadButton.south), isFalse);
      expect(frame.first.isDown(PadButton.south), isTrue);
    });
  });

  group('events carry what a snapshot cannot', () {
    test(
      'a tap inside one frame is invisible to the state and is an event',
      () {
        // The case that justifies having events at all. Between two polls the
        // button went down and came back up; the state at both ends says "up".
        final device = pad();
        final pads = Pads(backend: RecordedPads([device]));
        pads.poll();

        device
          ..button(btnSouth, down: true)
          ..button(btnSouth, down: false);

        final frame = pads.poll();
        expect(
          frame.first.isDown(PadButton.south),
          isFalse,
          reason: 'it is not held at the moment the frame asked',
        );
        expect(
          frame.events.whereType<PadPressed>().map((e) => e.button),
          contains(PadButton.south),
          reason: 'but it was pressed, and a state alone would have lost it',
        );
        expect(
          frame.events.whereType<PadReleased>().map((e) => e.button),
          contains(PadButton.south),
        );
      },
    );

    test('events arrive in the order they happened', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      pads.poll();

      device
        ..button(btnSouth, down: true)
        ..button(btnStart, down: true)
        ..button(btnSouth, down: false);

      final buttons = pads
          .poll()
          .events
          .whereType<PadEvent>()
          .map((e) => e.toString())
          .toList();
      expect(buttons, [
        'PadPressed(0, south)',
        'PadPressed(0, start)',
        'PadReleased(0, south)',
      ]);
    });
  });

  group('axes', () {
    test('up is positive, whatever the hardware says', () {
      // evdev has positive Y pointing down; a stick pushed away from the
      // player should walk forwards without a minus sign in the game.
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      device.axis(absY, -32768);
      expect(pads.poll().first.stick(PadStick.left).y, greaterThan(0.9));
    });

    test('a trigger runs nought to one and never negative', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      device.axis(absZ, 0);
      expect(pads.poll().first.trigger(PadSide.left), 0);
      device.axis(absZ, 255);
      expect(pads.poll().first.trigger(PadSide.left), closeTo(1, 1e-6));
    });

    test('a trigger past half way is also a button', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      device.axis(absZ, 255);
      expect(pads.poll().first.isDown(PadButton.leftTrigger), isTrue);
      device.axis(absZ, 0);
      expect(pads.poll().first.isDown(PadButton.leftTrigger), isFalse);
    });

    test('the raw value is kept alongside the shaped one', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      device.axis(absX, 3000); // Inside the default dead zone.
      final state = pads.poll().first;
      expect(state.axis(PadAxis.leftX), 0, reason: 'shaped away');
      expect(state.rawAxis(PadAxis.leftX), greaterThan(0), reason: 'but seen');
    });

    test('the hat is the d-pad, as four buttons', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));

      device.axis(absHat0Y, -1);
      var state = pads.poll().first;
      expect(state.isDown(PadButton.dpadUp), isTrue);
      expect(state.dpad.y, 1, reason: 'and up is positive there too');

      device.axis(absHat0Y, 0);
      device.axis(absHat0X, 1);
      state = pads.poll().first;
      expect(state.isDown(PadButton.dpadUp), isFalse);
      expect(state.isDown(PadButton.dpadRight), isTrue);
      expect(state.dpad.x, 1);
    });
  });

  group('hot-plug', () {
    test('a pad already held when the game starts is not missed', () {
      // Without adopting the device's current state, a trigger held at launch
      // reads as released until somebody lets go of it.
      final device = pad(held: {btnSouth});
      final pads = Pads(backend: RecordedPads([device]));
      expect(pads.poll().first.isDown(PadButton.south), isTrue);
    });

    test('arriving and leaving are events', () {
      final backend = RecordedPads();
      final pads = Pads(backend: backend);
      expect(pads.poll().count, 0);

      final device = pad();
      backend.attach(device);
      final arrived = pads.poll();
      expect(arrived.events.whereType<PadConnected>(), hasLength(1));
      expect(arrived.count, 1);

      backend.detach(device);
      final left = pads.poll();
      expect(left.events.whereType<PadDisconnected>(), hasLength(1));
      expect(left.count, 0);
    });

    test('a pad that vanishes reads as neutral, not as whatever it held', () {
      // A controller whose battery dies mid-corner must not leave the car
      // turning left forever.
      final backend = RecordedPads();
      final device = pad();
      backend.attach(device);
      final pads = Pads(backend: backend);

      device
        ..button(btnSouth, down: true)
        ..axis(absX, 32767);
      final holding = pads.poll().first;
      expect(holding.isDown(PadButton.south), isTrue);
      expect(holding.stick(PadStick.left).x, greaterThan(0.9));

      backend.detach(device);
      final gone = pads.poll().pad(0);
      expect(gone.connected, isFalse);
      expect(gone.isDown(PadButton.south), isFalse);
      expect(gone.stick(PadStick.left).length, 0);
      expect(gone.trigger(PadSide.left), 0);
    });

    test('a pad that comes back gets its own player number again', () {
      final backend = RecordedPads();
      final one = pad(path: 'port-a');
      final two = pad(path: 'port-b');
      backend
        ..attach(one)
        ..attach(two);
      final pads = Pads(backend: backend);
      pads.poll();
      expect(pads.poll().pad(0).identity.path, 'port-a');

      // Player one's battery dies, and is changed.
      backend.detach(one);
      pads.poll();
      expect(pads.poll().pad(0).connected, isFalse);
      expect(pads.poll().pad(1).identity.path, 'port-b');

      final again = pad(path: 'port-a');
      backend.attach(again);
      final back = pads.poll();
      expect(
        back.pad(0).identity.path,
        'port-a',
        reason: 'player one is player one again, not player three',
      );
      expect(back.pad(1).identity.path, 'port-b');
    });

    test('a pad with a serial number is followed between ports', () {
      final backend = RecordedPads();
      final wireless = pad(uniq: 'aa:bb:cc', path: 'dongle-1');
      backend.attach(wireless);
      final pads = Pads(backend: backend);
      pads.poll();
      backend.detach(wireless);
      pads.poll();

      // Same pad, different dongle.
      backend.attach(pad(uniq: 'aa:bb:cc', path: 'dongle-2'));
      expect(pads.poll().pad(0).connected, isTrue);
      expect(pads.poll().pad(0).identity.uniq, 'aa:bb:cc');
    });

    test('more pads than there are slots for are ignored, not shuffled in', () {
      final backend = RecordedPads();
      final pads = Pads(backend: backend, maxPads: 2);
      for (final port in ['a', 'b', 'c']) {
        backend.attach(pad(path: 'port-$port'));
      }
      final frame = pads.poll();
      expect(frame.count, 2);
      expect(frame.pad(0).identity.path, 'port-a');
      expect(frame.pad(1).identity.path, 'port-b');
    });
  });

  group('the kernel dropping events', () {
    test('state is asked for again rather than carried on from', () {
      // After SYN_DROPPED everything being tracked is wrong by an unknown
      // amount. The pad below is holding start; our running total says south.
      final device = pad(held: {btnStart});
      final pads = Pads(backend: RecordedPads([device]));

      device.button(btnSouth, down: true);
      final before = pads.poll().first;
      expect(before.isDown(PadButton.south), isTrue);
      expect(before.isDown(PadButton.start), isTrue);

      // South is let go of, and the record saying so is among what the kernel
      // threw away. The pad's real state is now start alone, while everything
      // tracked up here still says both — which is precisely the divergence
      // SYN_DROPPED exists to announce.
      device.drift(buttons: {btnStart});
      device.send(evSyn, synDropped, 0);
      final after = pads.poll().first;
      expect(
        after.isDown(PadButton.south),
        isFalse,
        reason: 'a difference applied to a diverged state stays diverged',
      );
      expect(after.isDown(PadButton.start), isTrue);
    });

    test('the resync reports the difference as ordinary events', () {
      final device = pad(held: {btnStart});
      final pads = Pads(backend: RecordedPads([device]));
      device.button(btnSouth, down: true);
      pads.poll();

      device.drift(buttons: {btnStart});
      device.send(evSyn, synDropped, 0);
      final frame = pads.poll();
      expect(
        frame.events.whereType<PadReleased>().map((e) => e.button),
        contains(PadButton.south),
      );
    });
  });

  group('the front door', () {
    test('no pads is a state, not a failure', () {
      final pads = Pads(backend: noPads);
      final frame = pads.poll();
      expect(frame.count, 0);
      expect(frame.first.connected, isFalse);
      expect(frame.first.isDown(PadButton.south), isFalse);
      expect(frame.pad(99).connected, isFalse);
      expect(frame.isActive, isFalse);
    });

    test('first is the lowest connected pad', () {
      final backend = RecordedPads();
      final pads = Pads(backend: backend);
      backend
        ..attach(pad(path: 'a'))
        ..attach(pad(path: 'b'));
      pads.poll();
      expect(pads.poll().first.slot, 0);
    });

    test('a truncated read does not produce a wrong event', () {
      // Half a record arriving is the case a decoder gets wrong quietly.
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      pads.poll();

      final whole = encodeEvdevEvent(evKey, btnSouth, 1);
      device.sendBytes(whole.sublist(0, 12));
      expect(pads.poll().first.isDown(PadButton.south), isFalse);

      device.sendBytes(whole.sublist(12));
      expect(pads.poll().first.isDown(PadButton.south), isTrue);
    });

    test('closing lets go of everything', () {
      final device = pad();
      final pads = Pads(backend: RecordedPads([device]));
      pads.poll();
      pads.close();
      expect(device.isAlive, isFalse);
    });
  });
}
