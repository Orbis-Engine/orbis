import 'package:orbis_input/orbis_input.dart';
import 'package:test/test.dart';

const deck = PadIdentity(
  name: 'Microsoft X-Box 360 pad 0',
  vendor: 0x28de,
  product: 0x1205,
);

void main() {
  group('choosing a layout', () {
    test('a known pad is found by vendor and product', () {
      expect(PadLayout.of(deck).name, 'Steam Deck');
    });

    test('a Sony pad gets Sony labels', () {
      const dualSense = PadIdentity(
        name: 'DualSense Wireless Controller',
        vendor: 0x054c,
        product: 0x0ce6,
      );
      expect(PadLayout.of(dualSense).labels.south, 'Cross');
      expect(PadLayout.of(dualSense).labels.east, 'Circle');
    });

    test('a Nintendo pad swaps the letters and not the positions', () {
      const pro = PadIdentity(
        name: 'Nintendo Switch Pro Controller',
        vendor: 0x057e,
        product: 0x2009,
      );
      final layout = PadLayout.of(pro);
      // The bottom button is still the bottom button...
      expect(layout.buttons[0x130], PadButton.south);
      // ...and it has a B on it.
      expect(layout.labels.of(PadButton.south), 'B');
      expect(layout.labels.of(PadButton.east), 'A');
    });

    test('an unknown pad falls back to the name', () {
      const clone = PadIdentity(
        name: 'Generic X-Box pad',
        vendor: 0x1234,
        product: 0x5678,
      );
      expect(PadLayout.of(clone).name, 'Xbox Controller');
    });

    test('a pad in no table at all still works', () {
      // The point of leaning on the kernel's codes: a pad nobody has ever
      // heard of is read correctly because its driver already did the mapping.
      const nobody = PadIdentity(name: 'Handmade Thing', vendor: 1, product: 2);
      final layout = PadLayout.of(nobody);
      expect(layout.name, 'Standard');
      expect(layout.buttons[0x130], PadButton.south);
      expect(layout.buttons[0x13b], PadButton.start);
      expect(layout.axes[0x00], PadAxis.leftX);
      expect(layout.axes[0x05], PadAxis.rightTrigger);
    });

    test('a pad with no right-stick axes puts the stick where it really is', () {
      // An older pad reports its right stick on the axes a modern one uses for
      // triggers. Decided from what the device says it has rather than from a
      // table, so it is right for a pad nobody has listed.
      const older = PadIdentity(name: 'Old Pad', vendor: 3, product: 4);
      final layout = PadLayout.of(
        older,
        capabilities: EvdevCapabilities.parse(ev: 'b', key: '', abs: '25'),
      );
      expect(layout.axes[0x02], PadAxis.rightX);
      expect(layout.axes[0x05], PadAxis.rightY);
      expect(layout.axes[0x03], isNull);
    });

    test('a pad that has the modern axes keeps the standard mapping', () {
      const modern = PadIdentity(name: 'New Pad', vendor: 5, product: 6);
      final layout = PadLayout.of(
        modern,
        capabilities: EvdevCapabilities.parse(ev: 'b', key: '', abs: '3f'),
      );
      expect(layout.axes[0x02], PadAxis.leftTrigger);
      expect(layout.axes[0x03], PadAxis.rightX);
    });
  });

  group('axis ranges', () {
    test('a stick is centred on the middle of its travel', () {
      const range = PadAxisRange(minimum: -32768, maximum: 32767);
      expect(range.toSigned(-32768), closeTo(-1, 1e-3));
      expect(range.toSigned(32767), closeTo(1, 1e-3));
      expect(range.toSigned(0), closeTo(0, 1e-4));
    });

    test('a trigger runs nought to one', () {
      const range = PadAxisRange(minimum: 0, maximum: 1023);
      expect(range.toUnsigned(0), 0);
      expect(range.toUnsigned(1023), 1);
      expect(range.toUnsigned(512), closeTo(0.5, 1e-2));
    });

    test('a ten-bit trigger is not read as an eight-bit one', () {
      // The thing that cannot be guessed and has to be asked of the driver: a
      // trigger fully pulled reads as 1023, and normalising it against 255
      // would leave it clamped at full for three quarters of its travel.
      const wide = PadAxisRange(minimum: 0, maximum: 1023);
      const narrow = PadAxisRange(minimum: 0, maximum: 255);
      expect(wide.toUnsigned(255), closeTo(0.249, 1e-3));
      expect(narrow.toUnsigned(255), 1);
    });

    test('a symmetric range is not a trigger', () {
      expect(PadAxisRange.stick.isUnipolar, isFalse);
      expect(PadAxisRange.trigger.isUnipolar, isTrue);
    });

    test('a range of no width answers rather than dividing by nothing', () {
      const broken = PadAxisRange(minimum: 7, maximum: 7);
      expect(broken.toSigned(7), 0);
      expect(broken.toUnsigned(7), 0);
    });

    test('a value beyond the stated range is clamped', () {
      const range = PadAxisRange(minimum: -100, maximum: 100);
      expect(range.toSigned(1000), 1);
      expect(range.toSigned(-1000), -1);
    });
  });
}
