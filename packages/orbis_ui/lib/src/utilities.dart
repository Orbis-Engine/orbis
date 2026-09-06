import 'dart:ui' show Color;

import 'style.dart';
import 'theme.dart';

/// Turns a list of class names into a style.
///
/// The vocabulary is the one every utility system has settled on — `p-4`,
/// `flex-1`, `items-center`, `bg-slate-800`, `rounded-lg` — because the point
/// of a vocabulary is that somebody already knows it. What it resolves to is
/// Flutter's own layout, not a second box model pretending to be the web's.
///
/// Unknown classes are ignored rather than refused. A class list is written by
/// hand under time pressure, often with a typo in it, and an interface that
/// refuses to draw because one word was wrong is worse than one that draws
/// without the rounded corner. [unknownIn] is there for anybody who does want
/// to be told.
class UiUtilities {
  const UiUtilities({this.theme = const UiTheme()});

  final UiTheme theme;

  /// The style a space-separated class list adds up to.
  UiStyle parse(String classes) {
    var style = UiStyle.none;
    for (final name in classes.split(RegExp(r'\s+'))) {
      if (name.isEmpty) continue;
      final rule = _rule(name);
      if (rule != null) style = style.merge(rule);
    }
    return style;
  }

  /// The classes in [classes] that mean nothing here.
  ///
  /// For a linter, an editor's squiggle, or a test that wants to know a name
  /// it relies on still exists.
  List<String> unknownIn(String classes) => [
    for (final name in classes.split(RegExp(r'\s+')))
      if (name.isNotEmpty && _rule(name) == null) name,
  ];

  UiStyle? _rule(String name) {
    // Layout ------------------------------------------------------------
    switch (name) {
      case 'row':
        return const UiStyle(direction: 'row');
      case 'col':
      case 'column':
        return const UiStyle(direction: 'column');
      case 'stack':
        return const UiStyle(direction: 'stack');
      case 'grow':
        return const UiStyle(grow: 1);
      case 'clip':
        return const UiStyle(clip: true);
      case 'scroll-y':
        return const UiStyle(scroll: 'y');
      case 'scroll-x':
        return const UiStyle(scroll: 'x');
      case 'italic':
        return const UiStyle(italic: true);
      case 'uppercase':
        return const UiStyle(uppercase: true);
      case 'border':
        return const UiStyle(borderWidth: 1);
      case 'rounded':
        return UiStyle(radius: theme.radius['md']);
      case 'shadow':
        return const UiStyle(shadow: 8);
      case 'shadow-lg':
        return const UiStyle(shadow: 20);
      case 'w-full':
        return const UiStyle(width: double.infinity);
      case 'h-full':
        return const UiStyle(height: double.infinity);
      case 'full':
        return const UiStyle(width: double.infinity, height: double.infinity);
    }

    // Alignment ---------------------------------------------------------
    if (name.startsWith('items-')) {
      final how = name.substring(6);
      return const {'start', 'center', 'end', 'stretch', 'baseline'}
              .contains(how)
          ? UiStyle(crossAxis: how)
          : null;
    }
    if (name.startsWith('justify-')) {
      final how = name.substring(8);
      return const {'start', 'center', 'end', 'between', 'around', 'evenly'}
              .contains(how)
          ? UiStyle(mainAxis: how)
          : null;
    }
    if (name.startsWith('text-')) {
      final rest = name.substring(5);
      if (theme.text.containsKey(rest)) {
        return UiStyle(fontSize: theme.text[rest]);
      }
      if (const {'left', 'center', 'right', 'justify'}.contains(rest)) {
        return UiStyle(textAlign: rest);
      }
      final colour = theme.colour(rest);
      return colour == null ? null : UiStyle(colour: colour);
    }
    if (name.startsWith('font-')) {
      return switch (name.substring(5)) {
        'thin' => const UiStyle(fontWeight: 100),
        'light' => const UiStyle(fontWeight: 300),
        'normal' => const UiStyle(fontWeight: 400),
        'medium' => const UiStyle(fontWeight: 500),
        'semibold' => const UiStyle(fontWeight: 600),
        'bold' => const UiStyle(fontWeight: 700),
        'black' => const UiStyle(fontWeight: 900),
        _ => null,
      };
    }

    // Colour ------------------------------------------------------------
    if (name.startsWith('bg-')) {
      final colour = _colour(name.substring(3));
      return colour == null ? null : UiStyle(background: colour);
    }
    if (name.startsWith('border-')) {
      final rest = name.substring(7);
      final width = double.tryParse(rest);
      if (width != null) return UiStyle(borderWidth: width);
      final colour = _colour(rest);
      return colour == null ? null : UiStyle(borderColour: colour);
    }

    // Shape -------------------------------------------------------------
    if (name.startsWith('rounded-')) {
      final rest = name.substring(8);
      final named = theme.radius[rest];
      if (named != null) return UiStyle(radius: named);
      final number = double.tryParse(rest);
      return number == null ? null : UiStyle(radius: number);
    }
    if (name.startsWith('opacity-')) {
      final number = double.tryParse(name.substring(8));
      // Stated as a percentage, the way every such scale is.
      return number == null ? null : UiStyle(opacity: (number / 100).clamp(0, 1));
    }

    // Spacing and size --------------------------------------------------
    final spacing = _spacing(name);
    if (spacing != null) return spacing;

    // Position ----------------------------------------------------------
    final placed = _placement(name);
    if (placed != null) return placed;

    if (name.startsWith('flex-')) {
      final number = double.tryParse(name.substring(5));
      return number == null ? null : UiStyle(grow: number);
    }
    if (name.startsWith('gap-')) {
      final value = _measure(name.substring(4));
      return value == null ? null : UiStyle(gap: value);
    }
    if (name.startsWith('leading-')) {
      final number = double.tryParse(name.substring(8));
      return number == null ? null : UiStyle(lineHeight: number);
    }
    if (name.startsWith('tracking-')) {
      final number = double.tryParse(name.substring(9));
      return number == null ? null : UiStyle(letterSpacing: number);
    }

    return null;
  }

  /// `p-4`, `px-2`, `mt-1`, `w-32`, `max-w-64` and the rest of that family.
  UiStyle? _spacing(String name) {
    for (final prefix in const [
      'p',
      'px',
      'py',
      'pt',
      'pr',
      'pb',
      'pl',
      'm',
      'mx',
      'my',
      'mt',
      'mr',
      'mb',
      'ml',
      'w',
      'h',
      'min-w',
      'min-h',
      'max-w',
      'max-h',
    ]) {
      if (!name.startsWith('$prefix-')) continue;
      final value = _measure(name.substring(prefix.length + 1));
      if (value == null) return null;

      return switch (prefix) {
        'p' => UiStyle(
          paddingTop: value,
          paddingRight: value,
          paddingBottom: value,
          paddingLeft: value,
        ),
        'px' => UiStyle(paddingLeft: value, paddingRight: value),
        'py' => UiStyle(paddingTop: value, paddingBottom: value),
        'pt' => UiStyle(paddingTop: value),
        'pr' => UiStyle(paddingRight: value),
        'pb' => UiStyle(paddingBottom: value),
        'pl' => UiStyle(paddingLeft: value),
        'm' => UiStyle(
          marginTop: value,
          marginRight: value,
          marginBottom: value,
          marginLeft: value,
        ),
        'mx' => UiStyle(marginLeft: value, marginRight: value),
        'my' => UiStyle(marginTop: value, marginBottom: value),
        'mt' => UiStyle(marginTop: value),
        'mr' => UiStyle(marginRight: value),
        'mb' => UiStyle(marginBottom: value),
        'ml' => UiStyle(marginLeft: value),
        'w' => UiStyle(width: value),
        'h' => UiStyle(height: value),
        'min-w' => UiStyle(minWidth: value),
        'min-h' => UiStyle(minHeight: value),
        'max-w' => UiStyle(maxWidth: value),
        'max-h' => UiStyle(maxHeight: value),
        _ => null,
      };
    }
    return null;
  }

  UiStyle? _placement(String name) {
    if (name.startsWith('inset-')) {
      final value = _measure(name.substring(6));
      return value == null
          ? null
          : UiStyle(top: value, right: value, bottom: value, left: value);
    }
    for (final edge in const ['top', 'right', 'bottom', 'left']) {
      if (!name.startsWith('$edge-')) continue;
      final value = _measure(name.substring(edge.length + 1));
      if (value == null) return null;
      return switch (edge) {
        'top' => UiStyle(top: value),
        'right' => UiStyle(right: value),
        'bottom' => UiStyle(bottom: value),
        _ => UiStyle(left: value),
      };
    }
    return null;
  }

  /// A number on the spacing scale, or one in brackets in real pixels.
  ///
  /// `p-4` is four steps. `p-[13]` is thirteen pixels — an escape hatch for
  /// the one measurement in a design that does not sit on the grid, which
  /// every real design has.
  double? _measure(String value) {
    if (value.startsWith('[') && value.endsWith(']')) {
      return double.tryParse(value.substring(1, value.length - 1));
    }
    if (value == 'full') return double.infinity;
    if (value == 'px') return 1;
    final number = double.tryParse(value);
    return number == null ? null : number * theme.step;
  }

  /// A palette name, or a colour written out in full.
  Color? _colour(String value) {
    if (value.startsWith('[') && value.endsWith(']')) {
      return parseColour(value.substring(1, value.length - 1));
    }
    return theme.colour(value);
  }
}

/// A colour written the way CSS writes one.
///
/// `#rgb`, `#rrggbb`, `#rrggbbaa`, or `rgb()`/`rgba()`. Returns null for
/// anything else, so a caller can fall back rather than guess.
Color? parseColour(String value) {
  final text = value.trim();

  if (text.startsWith('#')) {
    final digits = text.substring(1);
    final expanded = switch (digits.length) {
      3 => 'FF${digits[0]}${digits[0]}${digits[1]}${digits[1]}'
          '${digits[2]}${digits[2]}',
      6 => 'FF$digits',
      // CSS puts the alpha last and Dart puts it first.
      8 => '${digits.substring(6)}${digits.substring(0, 6)}',
      _ => null,
    };
    if (expanded == null) return null;
    final number = int.tryParse(expanded, radix: 16);
    return number == null ? null : Color(number);
  }

  final call = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(text);
  if (call != null) {
    final parts = call
        .group(1)!
        .split(RegExp(r'[,\s/]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 3) return null;

    int channel(String part) {
      if (part.endsWith('%')) {
        final percent = double.tryParse(part.substring(0, part.length - 1));
        return percent == null ? 0 : (percent * 2.55).round().clamp(0, 255);
      }
      return (double.tryParse(part) ?? 0).round().clamp(0, 255);
    }

    final alpha = parts.length > 3
        ? ((double.tryParse(parts[3]) ?? 1) * 255).round().clamp(0, 255)
        : 255;

    return Color.fromARGB(
      alpha,
      channel(parts[0]),
      channel(parts[1]),
      channel(parts[2]),
    );
  }

  return null;
}
