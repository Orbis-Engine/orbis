import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// A colour as somebody writes one down, and as a renderer needs it.
///
/// Two different things wearing one name. `0xFF8A3D` is sRGB: the numbers a
/// picker shows and a designer hands over, spaced so that equal steps look
/// equally different to an eye. A renderer adds and multiplies light, and that
/// only works in linear, where equal steps *are* equal amounts.
///
/// So the conversion has to happen somewhere, and having it in one place is
/// the difference between a scene that is consistently lit and one where half
/// the colours went through it twice — which does not look like a bug, it
/// looks like the artist chose badly.
///
/// Held here rather than as a widget toolkit's colour so that everything below
/// the editor stays free of one. A console front end has no Flutter in it and
/// still has weather.
class Tint {
  const Tint(this.red, this.green, this.blue);

  /// The way a colour is actually written: `0xFF8A3D`, no alpha.
  ///
  /// Alpha is left out because none of what this describes has any. A sky is
  /// not partly transparent; the cloud in front of it is a separate thing with
  /// its own density.
  const Tint.hex(int value)
    : red = ((value >> 16) & 0xFF) / 255.0,
      green = ((value >> 8) & 0xFF) / 255.0,
      blue = (value & 0xFF) / 255.0;

  static const Tint white = Tint(1, 1, 1);
  static const Tint black = Tint(0, 0, 0);

  /// sRGB, from nothing to full.
  final double red;
  final double green;
  final double blue;

  /// The same colour in the space light actually behaves in.
  Vector3 get linear =>
      Vector3(_linear(red), _linear(green), _linear(blue));

  /// Part of the way from one to another.
  ///
  /// Mixed in sRGB rather than in linear, deliberately. Interpolating linear
  /// values is more defensible physically and looks wrong: a dusk-to-night
  /// ramp done that way spends most of its length nearly black, because
  /// linear space gives almost all of its room to the bright end. What a
  /// designer means by halfway is halfway as an eye reads it.
  static Tint lerp(Tint from, Tint to, double t) {
    final at = t.clamp(0.0, 1.0);
    return Tint(
      from.red + (to.red - from.red) * at,
      from.green + (to.green - from.green) * at,
      from.blue + (to.blue - from.blue) * at,
    );
  }

  Tint scaled(double by) => Tint(red * by, green * by, blue * by);

  /// The transfer function sRGB is defined by. Not a gamma of 2.2 — that is
  /// the approximation, and it is wrong by enough to see in the dark end.
  static double _linear(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

  @override
  bool operator ==(Object other) =>
      other is Tint &&
      other.red == red &&
      other.green == green &&
      other.blue == blue;

  @override
  int get hashCode => Object.hash(red, green, blue);

  @override
  String toString() =>
      'Tint(${red.toStringAsFixed(3)}, ${green.toStringAsFixed(3)}, '
      '${blue.toStringAsFixed(3)})';
}
