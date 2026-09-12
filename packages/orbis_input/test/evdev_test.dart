import 'dart:typed_data';

import 'package:orbis_input/orbis_input.dart';
import 'package:test/test.dart';

/// A recorded burst: the south button going down, the left stick moving, and
/// the report that ends the group — as the kernel writes it on a 64-bit
/// machine.
Uint8List recorded() {
  final out = BytesBuilder();
  out.add(encodeEvdevEvent(evKey, 0x130, 1));
  out.add(encodeEvdevEvent(evAbs, 0x00, 12345));
  out.add(encodeEvdevEvent(evSyn, synReport, 0));
  return out.takeBytes();
}

void main() {
  group('decoding', () {
    test('a whole buffer comes out as the events that went in', () {
      final events = EvdevDecoder().decode(recorded());
      expect(events, [
        const EvdevEvent(evKey, 0x130, 1),
        const EvdevEvent(evAbs, 0x00, 12345),
        const EvdevEvent(evSyn, synReport, 0),
      ]);
    });

    test('a record is 24 bytes on a 64-bit machine', () {
      expect(EvdevDecoder().recordBytes, 24);
      expect(recorded().length, 72);
    });

    test('a 32-bit kernel writes 16', () {
      expect(EvdevDecoder(timeBytes: 8).recordBytes, 16);
    });

    test('a negative value survives the round trip', () {
      // Sticks spend half their time negative, and reading the value as
      // unsigned would put a stick pushed left at 65535 rather than at -1.
      final events = EvdevDecoder().decode(
        encodeEvdevEvent(evAbs, 0x01, -32768),
      );
      expect(events.single.value, -32768);
    });
  });

  group('a read that lands mid-record', () {
    test('the fragment is kept and finished by the next read', () {
      // The failure this exists to prevent: a decoder that dropped the tail
      // would work perfectly until the first busy frame, then lose an event.
      final bytes = recorded();
      final decoder = EvdevDecoder();

      final first = decoder.decode(bytes.sublist(0, 30));
      expect(first, hasLength(1), reason: 'one whole record and six bytes');
      expect(decoder.hasPartial, isTrue);

      final rest = decoder.decode(bytes.sublist(30));
      expect(rest, hasLength(2));
      expect(rest.last, const EvdevEvent(evSyn, synReport, 0));
      expect(decoder.hasPartial, isFalse);
    });

    test('a record split one byte at a time still arrives', () {
      final bytes = recorded();
      final decoder = EvdevDecoder();
      final events = <EvdevEvent>[];
      for (final byte in bytes) {
        events.addAll(decoder.decode([byte]));
      }
      expect(events, hasLength(3));
    });

    test('a reset throws the fragment away', () {
      final decoder = EvdevDecoder();
      decoder.decode(recorded().sublist(0, 10));
      expect(decoder.hasPartial, isTrue);
      decoder.reset();
      expect(decoder.hasPartial, isFalse);
      // And what follows is read from the start of a record, not from the
      // middle of the one that was abandoned.
      final events = decoder.decode(encodeEvdevEvent(evKey, 0x131, 1));
      expect(events.single, const EvdevEvent(evKey, 0x131, 1));
    });

    test('an empty read says nothing and keeps what it had', () {
      final decoder = EvdevDecoder();
      decoder.decode(recorded().sublist(0, 10));
      expect(decoder.decode(const []), isEmpty);
      expect(decoder.hasPartial, isTrue);
    });
  });

  group('capability bitmaps', () {
    test('words are read most significant first', () {
      // Straight from a real device: sysfs printed this for a pad with the
      // south and east buttons. Read left to right as ascending words the two
      // bits land at 48 and 49, and the pad appears to have no buttons at all.
      final keys = EvdevCapabilities.parseBitmap('3000000000000 0 0 0 0');
      expect(keys, containsAll([0x130, 0x131]));
      expect(keys, isNot(contains(48)));
    });

    test('the last word holds the low bits', () {
      expect(EvdevCapabilities.parseBitmap('0 1'), contains(0));
      expect(EvdevCapabilities.parseBitmap('1 0'), contains(64));
    });

    test('the top bit of a word is not read as a negative number', () {
      // Dart's int is signed, so 0x8000000000000000 parses as negative and a
      // naive shift of the value loses the bit.
      expect(EvdevCapabilities.parseBitmap('8000000000000000'), contains(63));
    });

    test('a pad is one that claims a gamepad button', () {
      final pad = EvdevCapabilities.parse(
        ev: 'b',
        key: '3000000000000 0 0 0 0',
        abs: '3',
      );
      expect(pad.isGamepad, isTrue);
      expect(pad.axes, containsAll([0, 1]));
    });

    test('a keyboard is not a pad', () {
      final keyboard = EvdevCapabilities.parse(
        ev: '120013',
        key: '10000000000 0 0 0',
        abs: '',
      );
      expect(keyboard.isGamepad, isFalse);
    });

    test('an unreadable device claims nothing', () {
      expect(EvdevCapabilities.none.isGamepad, isFalse);
      expect(EvdevCapabilities.parseBitmap(''), isEmpty);
      expect(EvdevCapabilities.parseBitmap('   '), isEmpty);
      expect(EvdevCapabilities.parseBitmap('zz'), isEmpty);
    });
  });
}
