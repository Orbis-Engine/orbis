import 'package:flutter/material.dart';

import 'css.dart';
import 'node.dart';
import 'style.dart';
import 'theme.dart';
import 'utilities.dart';

/// What happens when somebody presses something.
///
/// The name is whatever script called the callback; the payload is whatever
/// the element has to say about the event — the text in a field, the value of
/// a slider. What the host does with it is its own business: in the editor it
/// goes back into the script that drew the interface, and in a test it goes
/// into a list.
typedef UiEvent = void Function(String handler, Object? payload);

/// A chance to wrap every element as it is built.
///
/// What the editor uses to draw over an interface without the interface
/// knowing: an outline, a selection highlight, a hit target that reports which
/// element a click landed on. The path is where the node sits in the tree,
/// which is what an edit needs and what a widget cannot be asked for.
///
/// Null in a game, where it costs exactly nothing — the design chrome is not
/// stripped out at build time, it was never built. That is the difference
/// between a canvas you can see while you work and one that shows up in a
/// screenshot.
typedef UiDecorator = Widget Function(
  UiNode node,
  List<int> path,
  Widget built,
);

/// Builds real Flutter widgets from a description.
///
/// The whole layer, in one class: no reconciler, no retained tree, no second
/// layout engine. A description arrives, a widget tree comes out, and Flutter
/// does what Flutter does. Rebuilding from scratch is cheap because that is
/// what Flutter is built to do — it is the same thing `build` does on every
/// setState.
class UiBuilder {
  UiBuilder({
    UiTheme? theme,
    this.onEvent,
    this.fontFamily,
    this.decorate,
  })  : theme = theme ?? const UiTheme(),
        _utilities = UiUtilities(theme: theme ?? const UiTheme()),
        _css = UiCss(theme: theme ?? const UiTheme());

  final UiTheme theme;

  /// Called when an element with a handler is used.
  final UiEvent? onEvent;

  /// The font everything is set in, when the host has one it wants used.
  final String? fontFamily;

  /// Called for every element, when a host wants to wrap them. Null in a game.
  final UiDecorator? decorate;

  final UiUtilities _utilities;
  final UiCss _css;

  /// The style a node adds up to: its classes, then its CSS over the top.
  UiStyle styleOf(UiNode node) {
    var style = UiStyle.none;
    if (node.classes.isNotEmpty) style = style.merge(_utilities.parse(node.classes));
    if (node.css.isNotEmpty) style = style.merge(_css.parse(node.css));
    return style;
  }

  /// Everything in a description that means nothing here.
  ///
  /// For the editor to show while somebody is typing, rather than leaving
  /// them to wonder why one word in a class list did nothing.
  List<String> unknownIn(UiNode node) => [
    ..._utilities.unknownIn(node.classes),
    ..._css.unknownIn(node.css),
    for (final child in node.children) ...unknownIn(child),
  ];

  /// Builds one node and everything under it.
  Widget build(UiNode node, [List<int> path = const []]) {
    final style = styleOf(node);
    final inherited = TextStyle(
      color: style.colour,
      fontSize: style.fontSize,
      fontWeight: _weight(style.fontWeight),
      fontStyle: (style.italic ?? false) ? FontStyle.italic : null,
      letterSpacing: style.letterSpacing,
      height: style.lineHeight,
      fontFamily: fontFamily,
    );

    Widget widget = switch (node.type) {
      'text' => _text(node, style, inherited),
      'button' => _button(node, style, inherited, path),
      'field' => _field(node, style, inherited),
      'image' => _image(node, style),
      'spacer' => const Spacer(),
      'row' || 'column' || 'stack' || 'box' || _ =>
        _container(node, style, path),
    };

    widget = _decorate(widget, style, node);

    // Wrapped here, before anything that carries parent data. Expanded and
    // Positioned have to be the direct child of the Flex or Stack that reads
    // them, and a host's wrapper between the two is not a cosmetic problem —
    // Flutter throws, and the element loses its size or its place entirely.
    if (decorate != null) widget = decorate!(node, path, widget);

    // Growing is a thing the *parent* does with a child, so it is applied
    // here rather than inside the child's own layout.
    final grow = style.grow;
    if (grow != null && grow > 0) {
      widget = Expanded(flex: grow.round().clamp(1, 1000), child: widget);
    }

    if (style.isPositioned) {
      widget = Positioned(
        top: _finite(style.top),
        right: _finite(style.right),
        bottom: _finite(style.bottom),
        left: _finite(style.left),
        child: widget,
      );
    }

    return node.key == null
        ? widget
        : KeyedSubtree(key: ValueKey(node.key), child: widget);
  }

  /// The box every element sits in: margin, size, background, border, corners,
  /// padding, and then whatever it holds.
  Widget _decorate(Widget child, UiStyle style, UiNode node) {
    var widget = child;

    if (style.hasPadding) {
      widget = Padding(
        padding: EdgeInsets.only(
          top: _finite(style.paddingTop) ?? 0,
          right: _finite(style.paddingRight) ?? 0,
          bottom: _finite(style.paddingBottom) ?? 0,
          left: _finite(style.paddingLeft) ?? 0,
        ),
        child: widget,
      );
    }

    if (style.hasBox) {
      final radius = style.radius == null
          ? null
          : BorderRadius.circular(style.radius!.clamp(0, 999));
      widget = DecoratedBox(
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: radius,
          border: style.borderWidth == null
              ? null
              : Border.all(
                  color: style.borderColour ?? const Color(0x33FFFFFF),
                  width: style.borderWidth!,
                ),
          boxShadow: (style.shadow ?? 0) > 0
              ? [
                  BoxShadow(
                    color: const Color(0x40000000),
                    blurRadius: style.shadow!,
                    offset: Offset(0, style.shadow! * 0.35),
                  ),
                ]
              : null,
        ),
        // Clipped after the decoration, so a rounded box actually cuts what is
        // inside it rather than drawing a rounded outline over square content.
        child: (style.clip ?? false) && radius != null
            ? ClipRRect(borderRadius: radius, child: widget)
            : widget,
      );
    } else if (style.clip ?? false) {
      widget = ClipRect(child: widget);
    }

    if (style.hasSize) {
      widget = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: _finite(style.minWidth) ?? 0,
          minHeight: _finite(style.minHeight) ?? 0,
          maxWidth: style.maxWidth ?? double.infinity,
          maxHeight: style.maxHeight ?? double.infinity,
        ),
        child: SizedBox(
          width: style.width,
          height: style.height,
          child: widget,
        ),
      );
    }

    final opacity = style.opacity;
    if (opacity != null && opacity < 1) {
      widget = Opacity(opacity: opacity, child: widget);
    }

    if (style.hasMargin) {
      widget = Padding(
        padding: EdgeInsets.only(
          top: _finite(style.marginTop) ?? 0,
          right: _finite(style.marginRight) ?? 0,
          bottom: _finite(style.marginBottom) ?? 0,
          left: _finite(style.marginLeft) ?? 0,
        ),
        child: widget,
      );
    }

    final handler = node.handlerFor('onTap');
    if (handler != null && node.type != 'button') {
      widget = GestureDetector(
        onTap: () => onEvent?.call(handler, null),
        behavior: HitTestBehavior.opaque,
        child: widget,
      );
    }

    return widget;
  }

  Widget _container(UiNode node, UiStyle style, [List<int> path = const []]) {
    final direction = style.direction ??
        switch (node.type) {
          'row' => 'row',
          'stack' => 'stack',
          'column' => 'column',
          _ => node.children.length > 1 ? 'column' : 'none',
        };

    final children = [
      for (var i = 0; i < node.children.length; i++)
        build(node.children[i], [...path, i]),
    ];

    if (children.isEmpty) return const SizedBox.shrink();

    if (direction == 'stack') {
      return Stack(
        clipBehavior: (style.clip ?? false) ? Clip.hardEdge : Clip.none,
        children: children,
      );
    }

    if (direction == 'none' && children.length == 1) return children.single;

    final spaced = _spaced(children, style.gap ?? 0, direction == 'row');
    final scroll = style.scroll;

    // Lining up on the baseline needs to be told which baseline, and Flutter
    // asserts rather than guessing. A script asking for it should not be the
    // thing that takes the frame down, so the answer is supplied here.
    final baseline =
        style.crossAxis == 'baseline' ? TextBaseline.alphabetic : null;

    final flex = direction == 'row'
        ? Row(
            mainAxisAlignment: _main(style.mainAxis),
            crossAxisAlignment: _cross(style.crossAxis),
            textBaseline: baseline,
            mainAxisSize: scroll == null ? MainAxisSize.max : MainAxisSize.min,
            children: spaced,
          )
        : Column(
            mainAxisAlignment: _main(style.mainAxis),
            crossAxisAlignment: _cross(style.crossAxis),
            textBaseline: baseline,
            mainAxisSize: scroll == null ? MainAxisSize.max : MainAxisSize.min,
            children: spaced,
          );

    if (scroll == null) return flex;
    return SingleChildScrollView(
      scrollDirection: scroll == 'x' ? Axis.horizontal : Axis.vertical,
      child: flex,
    );
  }

  /// Children with the gap between them.
  ///
  /// A widget between each pair rather than padding on every child, so the
  /// first and last are flush with the edges — which is what `gap` means and
  /// what `margin` on every child would get wrong.
  List<Widget> _spaced(List<Widget> children, double gap, bool horizontal) {
    if (gap <= 0 || children.length < 2) return children;
    final spaced = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        spaced.add(SizedBox(
          width: horizontal ? gap : null,
          height: horizontal ? null : gap,
        ));
      }
      spaced.add(children[i]);
    }
    return spaced;
  }

  Widget _text(UiNode node, UiStyle style, TextStyle inherited) {
    final words = node.text ?? '';
    return Text(
      (style.uppercase ?? false) ? words.toUpperCase() : words,
      style: inherited,
      textAlign: switch (style.textAlign) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'justify' => TextAlign.justify,
        'left' => TextAlign.left,
        _ => null,
      },
    );
  }

  Widget _button(UiNode node, UiStyle style, TextStyle inherited,
      List<int> path) {
    final handler = node.handlerFor('onPressed') ?? node.handlerFor('onTap');
    final label = node.text ?? '';

    // Built out of the same pieces as everything else rather than out of a
    // Material button, so a class list styles a button exactly the way it
    // styles a box. What a button adds is the press, the cursor and the
    // ripple — not a second styling system to fight with.
    return MouseRegion(
      cursor: handler == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: handler == null ? null : () => onEvent?.call(handler, null),
        child: node.children.isEmpty
            ? Text(
                (style.uppercase ?? false) ? label.toUpperCase() : label,
                style: inherited,
              )
            : _container(node, style, path),
      ),
    );
  }

  Widget _field(UiNode node, UiStyle style, TextStyle inherited) {
    final handler = node.handlerFor('onChanged');
    return TextField(
      controller: TextEditingController(text: node.text ?? ''),
      style: inherited,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: node.props['placeholder'] is String
            ? node.props['placeholder']! as String
            : null,
      ),
      onChanged: handler == null
          ? null
          : (value) => onEvent?.call(handler, value),
    );
  }

  Widget _image(UiNode node, UiStyle style) {
    final source = node.props['src'];
    if (source is! String || source.isEmpty) return const SizedBox.shrink();
    return Image.network(
      source,
      width: style.width,
      height: style.height,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );
  }

  MainAxisAlignment _main(String? how) => switch (how) {
    'center' => MainAxisAlignment.center,
    'end' => MainAxisAlignment.end,
    'between' => MainAxisAlignment.spaceBetween,
    'around' => MainAxisAlignment.spaceAround,
    'evenly' => MainAxisAlignment.spaceEvenly,
    _ => MainAxisAlignment.start,
  };

  CrossAxisAlignment _cross(String? how) => switch (how) {
    'center' => CrossAxisAlignment.center,
    'end' => CrossAxisAlignment.end,
    'stretch' => CrossAxisAlignment.stretch,
    'baseline' => CrossAxisAlignment.baseline,
    _ => CrossAxisAlignment.start,
  };

  FontWeight? _weight(int? value) => switch (value) {
    100 => FontWeight.w100,
    200 => FontWeight.w200,
    300 => FontWeight.w300,
    400 => FontWeight.w400,
    500 => FontWeight.w500,
    600 => FontWeight.w600,
    700 => FontWeight.w700,
    800 => FontWeight.w800,
    900 => FontWeight.w900,
    _ => null,
  };

  /// Infinity means "as much as there is" in a class list and is not a number
  /// a constraint or an inset can take.
  double? _finite(double? value) =>
      value == null || !value.isFinite ? null : value;
}
