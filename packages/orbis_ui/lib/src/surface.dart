import 'package:flutter/material.dart';

import 'builder.dart';
import 'document.dart';
import 'node.dart';
import 'theme.dart';

/// An interface described somewhere else, drawn here.
///
/// Given a description it builds widgets; given [onEvent] it says when
/// somebody pressed something. What is on the other end — a canvas file, a
/// script, a test — is not this widget's business, which is what lets the same
/// layer serve a game's heads-up display, an editor panel and a unit test
/// without any of them knowing about the others.
///
/// It also measures itself, which is what makes an interface responsive
/// without anybody wiring it up: the width it is given decides which prefixed
/// classes apply and, when it is drawing a [canvas] laid out responsively, how
/// much bigger everything measured in the vocabulary gets.
class UiSurface extends StatelessWidget {
  const UiSurface({
    super.key,
    required this.description,
    this.theme = const UiTheme(),
    this.canvas,
    this.width,
    this.onEvent,
    this.fontFamily,
    this.decorate,
  });

  /// What to draw.
  final UiNode description;

  final UiTheme theme;

  /// The canvas this was laid out on, when it came from a document.
  ///
  /// Null for a description a script built out of nothing, which has no
  /// reference size and so nothing to be fluid against.
  final UiCanvas? canvas;

  /// The width to lay out at, when the caller already knows it.
  ///
  /// The editor does: it is showing a phone inside a panel, and the width that
  /// matters is the phone's rather than the panel's. Left null this measures
  /// itself, which is the right answer everywhere else.
  final double? width;

  /// Called when something with a handler is used.
  final UiEvent? onEvent;

  final String? fontFamily;

  /// A hook the editor uses to draw over what it built. Null in a game, where
  /// the design chrome is not stripped out — it was never built.
  final UiDecorator? decorate;

  @override
  Widget build(BuildContext context) {
    if (width != null) return _at(width!);

    return LayoutBuilder(
      builder: (context, constraints) {
        // An unbounded width is a real case — a surface inside a scrolling
        // row — and it is not a width to resolve breakpoints against: every
        // one of them would be in play at once. The screen is the honest
        // fallback, and zero, meaning "the narrowest layout", is the honest
        // fallback to that.
        final measured = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.maybeSizeOf(context)?.width ?? 0;
        return _at(measured);
      },
    );
  }

  Widget _at(double measured) {
    final scaled = theme.scaled(canvas?.fluidScale(measured) ?? 1);
    final builder = UiBuilder(
      theme: scaled,
      onEvent: onEvent,
      fontFamily: fontFamily,
      decorate: decorate,
      width: measured,
    );

    // Defaults for anything the description does not set, so text is legible
    // before anybody has styled it. A description that says nothing about
    // colour should still be readable rather than black on black.
    return DefaultTextStyle(
      style: TextStyle(
        fontSize: scaled.text['base'],
        color: scaled.colour('slate-100'),
        fontFamily: fontFamily,
      ),
      child: builder.build(description),
    );
  }
}
