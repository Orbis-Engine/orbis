import 'dart:ui' show Color;

import 'style.dart';
import 'theme.dart';
import 'utilities.dart' show parseColour;

/// CSS declarations, over the same style a class list produces.
///
/// A subset, and an honest one: this is Flutter's layout wearing CSS's names,
/// not a browser. What is here is what maps onto a widget tree without lying —
/// the box, the text, the flex properties and where a thing sits in a stack.
/// What is not here is everything that needs a document: floats, grid areas,
/// selectors, inheritance, the cascade.
///
/// The reason to have it at all is that half of what a designer writes is
/// already in this form, and retyping `padding: 8px 12px` as `px-3 py-2` is
/// work that buys nothing.
class UiCss {
  const UiCss({this.theme = const UiTheme()});

  final UiTheme theme;

  /// Parses a declaration block: `padding: 8px; color: #fff`.
  ///
  /// Braces and a selector around it are accepted and ignored, so a snippet
  /// pasted from a stylesheet works as well as one written inline.
  UiStyle parse(String source) {
    var text = source.trim();
    final open = text.indexOf('{');
    if (open >= 0 && text.endsWith('}')) {
      text = text.substring(open + 1, text.length - 1);
    }

    var style = UiStyle.none;
    for (final declaration in text.split(';')) {
      final colon = declaration.indexOf(':');
      if (colon < 0) continue;

      final property = declaration.substring(0, colon).trim().toLowerCase();
      final value = declaration.substring(colon + 1).trim();
      if (property.isEmpty || value.isEmpty) continue;

      final rule = _declaration(property, value);
      if (rule != null) style = style.merge(rule);
    }
    return style;
  }

  /// The declarations in [source] this does not understand.
  List<String> unknownIn(String source) {
    final unknown = <String>[];
    for (final declaration in source.split(';')) {
      final colon = declaration.indexOf(':');
      if (colon < 0) continue;
      final property = declaration.substring(0, colon).trim().toLowerCase();
      final value = declaration.substring(colon + 1).trim();
      if (property.isEmpty || value.isEmpty) continue;
      if (_declaration(property, value) == null) unknown.add(property);
    }
    return unknown;
  }

  UiStyle? _declaration(String property, String value) {
    switch (property) {
      case 'display':
        return switch (value) {
          'flex' => const UiStyle(direction: 'row'),
          'block' => const UiStyle(direction: 'column'),
          _ => null,
        };
      case 'flex-direction':
        return switch (value) {
          'row' => const UiStyle(direction: 'row'),
          'column' => const UiStyle(direction: 'column'),
          _ => null,
        };
      case 'position':
        // Everything here is laid out by its parent; absolute only means
        // something inside a stack, and that is what the edges are for.
        return value == 'absolute' ? const UiStyle() : null;
      case 'flex':
      case 'flex-grow':
        final number = double.tryParse(value.split(RegExp(r'\s+')).first);
        return number == null ? null : UiStyle(grow: number);
      case 'gap':
        final gap = _length(value);
        return gap == null ? null : UiStyle(gap: gap);
      case 'align-items':
        return UiStyle(crossAxis: _across(value));
      case 'justify-content':
        return UiStyle(mainAxis: _along(value));
      case 'text-align':
        return const {'left', 'center', 'right', 'justify'}.contains(value)
            ? UiStyle(textAlign: value)
            : null;

      case 'padding':
        final sides = _sides(value);
        return sides == null
            ? null
            : UiStyle(
                paddingTop: sides.top,
                paddingRight: sides.right,
                paddingBottom: sides.bottom,
                paddingLeft: sides.left,
              );
      case 'padding-top':
        return _one(value, (v) => UiStyle(paddingTop: v));
      case 'padding-right':
        return _one(value, (v) => UiStyle(paddingRight: v));
      case 'padding-bottom':
        return _one(value, (v) => UiStyle(paddingBottom: v));
      case 'padding-left':
        return _one(value, (v) => UiStyle(paddingLeft: v));

      case 'margin':
        final sides = _sides(value);
        return sides == null
            ? null
            : UiStyle(
                marginTop: sides.top,
                marginRight: sides.right,
                marginBottom: sides.bottom,
                marginLeft: sides.left,
              );
      case 'margin-top':
        return _one(value, (v) => UiStyle(marginTop: v));
      case 'margin-right':
        return _one(value, (v) => UiStyle(marginRight: v));
      case 'margin-bottom':
        return _one(value, (v) => UiStyle(marginBottom: v));
      case 'margin-left':
        return _one(value, (v) => UiStyle(marginLeft: v));

      case 'width':
        return _one(value, (v) => UiStyle(width: v));
      case 'height':
        return _one(value, (v) => UiStyle(height: v));
      case 'min-width':
        return _one(value, (v) => UiStyle(minWidth: v));
      case 'min-height':
        return _one(value, (v) => UiStyle(minHeight: v));
      case 'max-width':
        return _one(value, (v) => UiStyle(maxWidth: v));
      case 'max-height':
        return _one(value, (v) => UiStyle(maxHeight: v));

      case 'top':
        return _one(value, (v) => UiStyle(top: v));
      case 'right':
        return _one(value, (v) => UiStyle(right: v));
      case 'bottom':
        return _one(value, (v) => UiStyle(bottom: v));
      case 'left':
        return _one(value, (v) => UiStyle(left: v));

      case 'background':
      case 'background-color':
        final colour = _colour(value);
        return colour == null ? null : UiStyle(background: colour);
      case 'color':
        final colour = _colour(value);
        return colour == null ? null : UiStyle(colour: colour);
      case 'border-color':
        final colour = _colour(value);
        return colour == null ? null : UiStyle(borderColour: colour);
      case 'border-width':
        return _one(value, (v) => UiStyle(borderWidth: v));
      case 'border':
        return _border(value);
      case 'border-radius':
        return _one(value, (v) => UiStyle(radius: v));
      case 'opacity':
        final number = double.tryParse(value);
        return number == null ? null : UiStyle(opacity: number.clamp(0, 1));

      case 'font-size':
        return _one(value, (v) => UiStyle(fontSize: v));
      case 'font-weight':
        final named = switch (value) {
          'normal' => 400,
          'bold' => 700,
          _ => int.tryParse(value),
        };
        return named == null ? null : UiStyle(fontWeight: named);
      case 'font-style':
        return value == 'italic'
            ? const UiStyle(italic: true)
            : value == 'normal'
                ? const UiStyle(italic: false)
                : null;
      case 'letter-spacing':
        return _one(value, (v) => UiStyle(letterSpacing: v));
      case 'line-height':
        final number = double.tryParse(value);
        return number == null ? null : UiStyle(lineHeight: number);
      case 'text-transform':
        return value == 'uppercase' ? const UiStyle(uppercase: true) : null;

      case 'overflow':
      case 'overflow-y':
        return switch (value) {
          'hidden' => const UiStyle(clip: true),
          'auto' || 'scroll' => UiStyle(
            clip: true,
            scroll: property == 'overflow-y' ? 'y' : 'y',
          ),
          _ => null,
        };
      case 'overflow-x':
        return switch (value) {
          'hidden' => const UiStyle(clip: true),
          'auto' || 'scroll' => const UiStyle(clip: true, scroll: 'x'),
          _ => null,
        };
      case 'box-shadow':
        // Only how far it is thrown; the rest of the syntax describes a
        // shadow model this does not have.
        final lengths = _lengths(value);
        return lengths.isEmpty ? const UiStyle(shadow: 8) : UiStyle(shadow: lengths.last);
    }
    return null;
  }

  UiStyle? _one(String value, UiStyle Function(double) build) {
    final length = _length(value);
    return length == null ? null : build(length);
  }

  /// `border: 1px solid #333` — the width and the colour, if they are there.
  UiStyle? _border(String value) {
    final parts = value.split(RegExp(r'\s+'));
    var style = const UiStyle(borderWidth: 1);
    for (final part in parts) {
      final length = _length(part);
      if (length != null) {
        style = style.copyWith(borderWidth: length);
        continue;
      }
      final colour = _colour(part);
      if (colour != null) style = style.copyWith(borderColour: colour);
    }
    return style;
  }

  /// One to four lengths, the way CSS reads them: all, then vertical and
  /// horizontal, then top, sides and bottom, then each in turn.
  ({double top, double right, double bottom, double left})? _sides(
    String value,
  ) {
    final lengths = _lengths(value);
    return switch (lengths.length) {
      1 => (
        top: lengths[0],
        right: lengths[0],
        bottom: lengths[0],
        left: lengths[0],
      ),
      2 => (
        top: lengths[0],
        right: lengths[1],
        bottom: lengths[0],
        left: lengths[1],
      ),
      3 => (
        top: lengths[0],
        right: lengths[1],
        bottom: lengths[2],
        left: lengths[1],
      ),
      4 => (
        top: lengths[0],
        right: lengths[1],
        bottom: lengths[2],
        left: lengths[3],
      ),
      _ => null,
    };
  }

  List<double> _lengths(String value) => [
    for (final part in value.split(RegExp(r'\s+')))
      if (_length(part) case final length?) length,
  ];

  /// A length in pixels. `rem` is read against the theme's own step, so a
  /// stylesheet written in rems lands on the same grid the classes do.
  double? _length(String value) {
    final text = value.trim().toLowerCase();
    if (text == '0') return 0;
    if (text == 'auto' || text == 'none') return null;
    if (text == '100%') return double.infinity;

    for (final unit in const ['px', 'rem', 'em', 'pt']) {
      if (!text.endsWith(unit)) continue;
      final number = double.tryParse(text.substring(0, text.length - unit.length));
      if (number == null) return null;
      return switch (unit) {
        'rem' || 'em' => number * theme.step * 4,
        'pt' => number * 4 / 3,
        _ => number,
      };
    }
    return double.tryParse(text);
  }

  Color? _colour(String value) =>
      parseColour(value) ?? theme.colour(value.trim());

  String? _across(String value) => switch (value) {
    'flex-start' || 'start' => 'start',
    'center' => 'center',
    'flex-end' || 'end' => 'end',
    'stretch' => 'stretch',
    'baseline' => 'baseline',
    _ => null,
  };

  String? _along(String value) => switch (value) {
    'flex-start' || 'start' => 'start',
    'center' => 'center',
    'flex-end' || 'end' => 'end',
    'space-between' => 'between',
    'space-around' => 'around',
    'space-evenly' => 'evenly',
    _ => null,
  };
}
