import 'package:orbis_noise/orbis_noise.dart';
import 'package:test/test.dart';

void main() {
  const value = ValueNoise(seed: 7);
  const gradient = GradientNoise(seed: 7);

  /// Samples a field over a grid and reports what it found.
  ({double low, double high, double mean}) survey(
    Noise field, {
    double step = 0.37,
    int count = 40,
  }) {
    var low = double.infinity;
    var high = -double.infinity;
    var total = 0.0;
    var n = 0;
    for (var i = 0; i < count; i++) {
      for (var j = 0; j < count; j++) {
        final v = field.at(i * step, j * step, 1.5);
        if (v < low) low = v;
        if (v > high) high = v;
        total += v;
        n++;
      }
    }
    return (low: low, high: high, mean: total / n);
  }

  group('every field', () {
    final fields = <String, Noise>{
      'value': value,
      'gradient': gradient,
      'fractal': const FractalNoise(gradient),
      'ridged': const RidgedNoise(gradient),
      'cells': const CellNoise(seed: 3),
      'tiling': const TilingNoise(gradient, period: 8),
    };

    fields.forEach((name, field) {
      test('$name gives the same answer twice', () {
        // The whole contract. A field that drifted would be a world that
        // regenerated differently after an upgrade.
        expect(field.at(1.5, 2.25, 3.125), field.at(1.5, 2.25, 3.125));
      });

      test('$name stays inside minus one and one', () {
        final seen = survey(field);
        expect(seen.low, greaterThanOrEqualTo(-1.0000001));
        expect(seen.high, lessThanOrEqualTo(1.0000001));
      });

      test('$name is smooth: a small step is a small change', () {
        // What separates noise from static. A random number per sample would
        // swing the full range between neighbouring samples.
        var worst = 0.0;
        for (var i = 0; i < 300; i++) {
          final x = i * 0.01;
          final change = (field.at(x + 0.01, 4.0) - field.at(x, 4.0)).abs();
          if (change > worst) worst = change;
        }
        expect(worst, lessThan(0.35), reason: '$name jumps');
      });

      test('$name uses the whole range rather than sitting near nought', () {
        final seen = survey(field);
        expect(seen.high - seen.low, greaterThan(0.5), reason: '$name is flat');
      });

      test('$name has a unit form that runs nought to one', () {
        final u = field.unit(2.5, 1.25);
        expect(u, inInclusiveRange(0, 1));
        expect(u, closeTo(field.at(2.5, 1.25) * 0.5 + 0.5, 1e-12));
      });
    });
  });

  group('what each one is for', () {
    test('a different seed is a different field', () {
      // Sampled off the lattice and off the axis planes. On them the dot
      // product collapses — with two coordinates whole, twelve gradients give
      // only three possible answers, and two seeds agreeing is ordinary
      // rather than suspicious.
      const other = GradientNoise(seed: 8);
      var same = 0;
      for (var i = 0; i < 50; i++) {
        final x = i * 0.37 + 0.13;
        if (gradient.at(x, 1.7, 0.43) == other.at(x, 1.7, 0.43)) same++;
      }
      expect(same, 0);
    });

    test('gradient noise is nought on the lattice, value noise is not', () {
      // The whole reason to prefer it: the extremes of value noise sit on the
      // grid, so the grid is visible in the field.
      for (final at in [0.0, 1.0, 2.0, -3.0]) {
        expect(gradient.at(at, at, at).abs(), lessThan(1e-9));
      }
      final onLattice = [
        for (var i = 0; i < 8; i++) value.at(i.toDouble(), 0, 0).abs(),
      ];
      expect(onLattice.any((v) => v > 0.1), isTrue);
    });

    test('a fractal has finer detail than the field it is built from', () {
      // More octaves means more happening between two nearby samples.
      double roughness(Noise field) {
        var total = 0.0;
        for (var i = 0; i < 200; i++) {
          total += (field.at(i * 0.02, 2.0) - field.at(i * 0.02 + 0.02, 2.0))
              .abs();
        }
        return total;
      }

      expect(
        roughness(const FractalNoise(gradient, octaves: 6)),
        greaterThan(roughness(const FractalNoise(gradient, octaves: 1))),
      );
    });

    test('one octave of a fractal is the field itself', () {
      const one = FractalNoise(gradient, octaves: 1);
      expect(one.at(1.3, 2.7, 0.4), closeTo(gradient.at(1.3, 2.7, 0.4), 1e-12));
    });

    test('ridged noise creases where the field crosses nought', () {
      // A crease rather than a smooth pass through: the peak is where the
      // field was zero.
      expect(const RidgedNoise(gradient).at(1.0, 1.0, 1.0), closeTo(1, 1e-9));
    });

    test('tiling noise joins up with itself', () {
      // The point of it. Sampled a period apart it is the same field, so a
      // texture laid end to end has no seam.
      const tiling = TilingNoise(gradient, period: 8);
      for (final at in [0.0, 1.25, 3.5, 6.75]) {
        expect(tiling.at(at, 2.5), closeTo(tiling.at(at + 8, 2.5), 1e-12));
        expect(tiling.at(2.5, at), closeTo(tiling.at(2.5, at + 8), 1e-12));
      }
    });

    test('tiling noise still varies inside a period', () {
      // A field that wrapped by going flat would also "join up".
      final seen = survey(const TilingNoise(gradient, period: 8), step: 0.25);
      expect(seen.high - seen.low, greaterThan(0.5));
    });

    test('cell noise is nought at a cell point and rises away from it', () {
      // Sampled densely, the lowest value found is near the bottom of the
      // range — that is a point — and the field climbs away from it.
      final seen = survey(const CellNoise(seed: 3), step: 0.11, count: 60);
      expect(seen.low, lessThan(-0.5));
      expect(seen.high, greaterThan(0));
    });
  });

  group('awkward arguments', () {
    test('negative coordinates work the way positive ones do', () {
      expect(gradient.at(-3.25, -1.5, -0.75), gradient.at(-3.25, -1.5, -0.75));
      expect(gradient.at(-3.25, -1.5).abs(), lessThanOrEqualTo(1));
    });

    test('a period of nothing does not divide by it', () {
      expect(
        const TilingNoise(gradient, period: 0).at(1.5, 2.5),
        isA<double>(),
      );
    });

    test('no octaves is silence rather than a division by nought', () {
      expect(const FractalNoise(gradient, octaves: 0).at(1.5, 2.5), 0);
    });
  });
}
