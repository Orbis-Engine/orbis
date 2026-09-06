import 'package:flutter/material.dart';

import 'builder.dart';
import 'node.dart';
import 'theme.dart';

/// An interface described somewhere else, drawn here.
///
/// Given a description it builds widgets; given [onEvent] it says when
/// somebody pressed something. What is on the other end — a canvas file, a
/// script, a test — is not this widget's business, which is what lets the same
/// layer serve a game's heads-up display, an editor panel and a unit test
/// without any of them knowing about the others.
class UiSurface extends StatelessWidget {
  const UiSurface({
    super.key,
    required this.description,
    this.theme = const UiTheme(),
    this.onEvent,
    this.fontFamily,
    this.decorate,
  });

  /// What to draw.
  final UiNode description;

  final UiTheme theme;

  /// Called when something with a handler is used.
  final UiEvent? onEvent;

  final String? fontFamily;

  /// A hook the editor uses to draw over what it built. Null in a game, where
  /// the design chrome is not stripped out — it was never built.
  final UiDecorator? decorate;

  @override
  Widget build(BuildContext context) {
    final builder = UiBuilder(
      theme: theme,
      onEvent: onEvent,
      fontFamily: fontFamily,
      decorate: decorate,
    );

    // Defaults for anything the description does not set, so text is legible
    // before anybody has styled it. A description that says nothing about
    // colour should still be readable rather than black on black.
    return DefaultTextStyle(
      style: TextStyle(
        fontSize: theme.text['base'],
        color: theme.colour('slate-100'),
        fontFamily: fontFamily,
      ),
      child: builder.build(description),
    );
  }
}
