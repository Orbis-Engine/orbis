/// Fields of numbers that vary smoothly and never change.
///
/// Two properties, both easy to lose. Smooth: two points close together give
/// close answers, which is what separates noise from a random number per
/// sample. And fixed: the value at a point depends only on the point and the
/// seed, so a world generated on one machine is the world generated on every
/// other, and a test can assert an exact number.
///
/// The hash is written out here rather than taken from a library for the same
/// reason — a field that changed with the language version would be a world
/// that regenerated differently after an upgrade.
library;

export 'src/noise.dart'
    show
        CellNoise,
        FractalNoise,
        GradientNoise,
        Noise,
        RidgedNoise,
        TilingNoise,
        ValueNoise;
