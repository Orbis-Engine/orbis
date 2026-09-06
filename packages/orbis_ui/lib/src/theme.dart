import 'dart:ui' show Color;

/// The scales a class name is measured in.
///
/// One place for the numbers, because the whole point of a utility vocabulary
/// is that `p-4` means the same as `gap-4` and both mean the same as the
/// designer meant. A theme somebody swaps has to swap all of it at once.
class UiTheme {
  const UiTheme({
    this.step = 4,
    this.text = const {
      'xs': 11,
      'sm': 12.5,
      'base': 14,
      'lg': 16,
      'xl': 19,
      '2xl': 23,
      '3xl': 30,
      '4xl': 38,
    },
    this.radius = const {
      'none': 0,
      'sm': 3,
      'md': 6,
      'lg': 10,
      'xl': 16,
      '2xl': 24,
      'full': 9999,
    },
    this.palette = defaultPalette,
  });

  /// What one unit of spacing is worth, in logical pixels.
  ///
  /// Four, so `p-4` is sixteen — the same arithmetic every utility vocabulary
  /// has used since the first one, and the reason `p-4` looks right to
  /// somebody who has never seen this engine.
  final double step;

  /// Named text sizes.
  final Map<String, double> text;

  /// Named corner radii.
  final Map<String, double> radius;

  /// Named colours, as family and shade.
  final Map<String, Color> palette;

  double spacing(String value) {
    final number = double.tryParse(value);
    if (number != null) return number * step;
    return switch (value) {
      'px' => 1,
      'auto' => 0,
      _ => 0,
    };
  }

  Color? colour(String name) => palette[name];

  /// Every colour, as `family-shade`, plus a handful with no family.
  ///
  /// Ten shades of six families and four plain names. Not a copy of anybody
  /// else's ramp — the families are the ones an engine's own tools need, and
  /// the numbers run the way every ramp runs so that 500 is the colour and
  /// 50 and 900 are the ends of it.
  static const Map<String, Color> defaultPalette = {
    'transparent': Color(0x00000000),
    'black': Color(0xFF000000),
    'white': Color(0xFFFFFFFF),
    'current': Color(0xFFFFFFFF),

    'slate-50': Color(0xFFF6F8FA),
    'slate-100': Color(0xFFE9EEF4),
    'slate-200': Color(0xFFD3DBE5),
    'slate-300': Color(0xFFB2BECD),
    'slate-400': Color(0xFF8593A6),
    'slate-500': Color(0xFF64748B),
    'slate-600': Color(0xFF4A5768),
    'slate-700': Color(0xFF333E4C),
    'slate-800': Color(0xFF212932),
    'slate-900': Color(0xFF141920),

    'ember-50': Color(0xFFFDF1E9),
    'ember-100': Color(0xFFF9DCC7),
    'ember-200': Color(0xFFF2BA95),
    'ember-300': Color(0xFFE8975F),
    'ember-400': Color(0xFFD97B37),
    'ember-500': Color(0xFFC25E22),
    'ember-600': Color(0xFFA34C1B),
    'ember-700': Color(0xFF7E3A15),
    'ember-800': Color(0xFF5A290F),
    'ember-900': Color(0xFF3A1A09),

    'steel-50': Color(0xFFEFF7FA),
    'steel-100': Color(0xFFD9ECF3),
    'steel-200': Color(0xFFB0D8E6),
    'steel-300': Color(0xFF7FBFD4),
    'steel-400': Color(0xFF56A3BE),
    'steel-500': Color(0xFF3B7F97),
    'steel-600': Color(0xFF2F667B),
    'steel-700': Color(0xFF244F5F),
    'steel-800': Color(0xFF193843),
    'steel-900': Color(0xFF0F2229),

    'moss-50': Color(0xFFEEF7F1),
    'moss-100': Color(0xFFD6EDDE),
    'moss-200': Color(0xFFAADCBC),
    'moss-300': Color(0xFF79C595),
    'moss-400': Color(0xFF4FA871),
    'moss-500': Color(0xFF2F7A4E),
    'moss-600': Color(0xFF26643F),
    'moss-700': Color(0xFF1D4D31),
    'moss-800': Color(0xFF143522),
    'moss-900': Color(0xFF0C2015),

    'rose-50': Color(0xFFFDF0F1),
    'rose-100': Color(0xFFF9D8DB),
    'rose-200': Color(0xFFF2B0B6),
    'rose-300': Color(0xFFE8828B),
    'rose-400': Color(0xFFD95E70),
    'rose-500': Color(0xFFC2415A),
    'rose-600': Color(0xFFA33449),
    'rose-700': Color(0xFF7E2839),
    'rose-800': Color(0xFF5A1B28),
    'rose-900': Color(0xFF3A1119),

    'amber-50': Color(0xFFFDF7E9),
    'amber-100': Color(0xFFF9EBC5),
    'amber-200': Color(0xFFF2D68F),
    'amber-300': Color(0xFFE8BE55),
    'amber-400': Color(0xFFD9A62D),
    'amber-500': Color(0xFFB98A1C),
    'amber-600': Color(0xFF977016),
    'amber-700': Color(0xFF745611),
    'amber-800': Color(0xFF523D0C),
    'amber-900': Color(0xFF352706),
  };
}
