import 'package:orbis_input/orbis_input.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

Matcher near(double value, [double tolerance = 1e-9]) =>
    closeTo(value, tolerance);

void main() {
  group('dead zone', () {
    const shaping = Shaping(inner: 0.2, outer: 0.9);

    test('a stick at rest is exactly nothing', () {
      expect(shaping.stick(Vector2.zero()).length, near(0));
      expect(shaping.scalar(0), near(0));
    });

    test('jitter inside the zone is nothing', () {
      // What a stick that has been played for a year actually reports when
      // nobody is touching it.
      expect(shaping.stick(Vector2(0.11, -0.07)).length, near(0));
    });

    test('deflection is continuous where the zone ends', () {
      // The whole reason for rescaling. Without it the first thing past the
      // dead zone jumps straight to 0.2, and a character cannot creep.
      final justOut = shaping.stick(Vector2(0.2001, 0));
      expect(justOut.x, lessThan(0.01));
      expect(justOut.x, greaterThan(0));
    });

    test('the outside saturates before the corner', () {
      // A worn stick that cannot quite reach 1.0 still gets full speed.
      expect(shaping.stick(Vector2(0.9, 0)).x, near(1));
      expect(shaping.stick(Vector2(1.0, 0)).x, near(1));
    });

    test('a scalar keeps its sign', () {
      expect(shaping.scalar(-0.9), near(-1));
      expect(shaping.scalar(0.9), near(1));
    });
  });

  group('the zone is round, not square', () {
    const shaping = Shaping(inner: 0.2, outer: 1.0);

    test('a slow diagonal survives', () {
      // The bug a per-axis dead zone has: pushed gently up and to the right,
      // neither axis passes 0.2 on its own, but the stick is plainly being
      // pushed — a radial zone sees that and a per-axis one does not.
      final gentle = Vector2(0.16, 0.16);
      expect(gentle.x, lessThan(0.2), reason: 'neither axis alone clears it');
      expect(shaping.stick(gentle).length, greaterThan(0));
    });

    test('direction is never changed by how hard the stick is pushed', () {
      for (final magnitude in [0.3, 0.6, 0.95]) {
        final pushed = Vector2(1, 2).normalized() * magnitude;
        final shaped = shaping.stick(pushed);
        // The same bearing, whatever the length.
        expect(
          shaped.x / shaped.y,
          near(pushed.x / pushed.y, 1e-9),
          reason: 'shaping moved the direction at $magnitude',
        );
      }
    });

    test('a diagonal is not allowed to outrun a straight push', () {
      // Per-axis shaping lets a corner reach a length of about 1.41, so a
      // character walks faster diagonally. Radial shaping cannot.
      final corner = shaping.stick(Vector2(1, 1));
      expect(corner.length, lessThanOrEqualTo(1.0 + 1e-9));
    });
  });

  group('curves', () {
    test('a curve above one gives finer control near the middle', () {
      const linear = Shaping(inner: 0, outer: 1);
      const squared = Shaping(inner: 0, outer: 1, curve: 2);
      expect(squared.scalar(0.5), lessThan(linear.scalar(0.5)));
      // And still reaches the ends, which is what makes it a curve rather
      // than a scaling.
      expect(squared.scalar(1), near(1));
      expect(squared.scalar(0), near(0));
    });

    test('the curve is applied after the rescale, not before', () {
      // Applied before, the dead zone would be curved too and the value just
      // past it would no longer start at nought.
      const shaping = Shaping(inner: 0.5, outer: 1, curve: 2);
      expect(shaping.scalar(0.5), near(0));
      expect(shaping.scalar(1.0), near(1));
    });
  });

  group('nothing is allowed to produce a bad number', () {
    test('a stick of not-a-number reads as at rest', () {
      const shaping = Shaping();
      expect(shaping.stick(Vector2(double.nan, 0)).length, near(0));
      expect(shaping.scalar(double.nan), near(0));
      expect(shaping.scalar(double.infinity), near(0));
    });

    test('a zone with no room between its ends still answers', () {
      const pinched = Shaping(inner: 0.5, outer: 0.5);
      expect(pinched.scalar(0.9), near(1));
      expect(pinched.scalar(0.1), near(0));
    });
  });
}
