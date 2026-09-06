import 'dart:ui' show Color;

/// How something looks and where it sits.
///
/// Deliberately flat and deliberately nullable: null means "nobody said", not
/// "zero", which is what lets a class list and a block of CSS be layered over
/// one another without the later one having to restate everything.
class UiStyle {
  const UiStyle({
    this.direction,
    this.mainAxis,
    this.crossAxis,
    this.gap,
    this.grow,
    this.paddingTop,
    this.paddingRight,
    this.paddingBottom,
    this.paddingLeft,
    this.marginTop,
    this.marginRight,
    this.marginBottom,
    this.marginLeft,
    this.width,
    this.height,
    this.minWidth,
    this.minHeight,
    this.maxWidth,
    this.maxHeight,
    this.background,
    this.colour,
    this.borderColour,
    this.borderWidth,
    this.radius,
    this.opacity,
    this.fontSize,
    this.fontWeight,
    this.italic,
    this.letterSpacing,
    this.lineHeight,
    this.textAlign,
    this.uppercase,
    this.shadow,
    this.clip,
    this.scroll,
    this.top,
    this.right,
    this.bottom,
    this.left,
  });

  /// How children are laid out, when this has any: `row`, `column` or `stack`.
  final String? direction;

  /// Along the direction, and across it.
  final String? mainAxis;
  final String? crossAxis;

  /// Between children.
  final double? gap;

  /// How much of the space left over this takes.
  final double? grow;

  final double? paddingTop;
  final double? paddingRight;
  final double? paddingBottom;
  final double? paddingLeft;

  final double? marginTop;
  final double? marginRight;
  final double? marginBottom;
  final double? marginLeft;

  final double? width;
  final double? height;
  final double? minWidth;
  final double? minHeight;
  final double? maxWidth;
  final double? maxHeight;

  final Color? background;
  final Color? colour;
  final Color? borderColour;
  final double? borderWidth;
  final double? radius;
  final double? opacity;

  final double? fontSize;
  final int? fontWeight;
  final bool? italic;
  final double? letterSpacing;
  final double? lineHeight;
  final String? textAlign;
  final bool? uppercase;

  /// How far the shadow is thrown, in logical pixels. Zero is none.
  final double? shadow;

  /// Whether children are cut off at the edges, and whether they scroll.
  final bool? clip;
  final String? scroll;

  /// Where it sits, when its parent is a stack.
  final double? top;
  final double? right;
  final double? bottom;
  final double? left;

  bool get isPositioned =>
      top != null || right != null || bottom != null || left != null;

  bool get hasPadding =>
      paddingTop != null ||
      paddingRight != null ||
      paddingBottom != null ||
      paddingLeft != null;

  bool get hasMargin =>
      marginTop != null ||
      marginRight != null ||
      marginBottom != null ||
      marginLeft != null;

  bool get hasBox =>
      background != null ||
      borderWidth != null ||
      radius != null ||
      (shadow ?? 0) > 0;

  bool get hasSize =>
      width != null ||
      height != null ||
      minWidth != null ||
      minHeight != null ||
      maxWidth != null ||
      maxHeight != null;

  /// This style with [other] laid over it.
  ///
  /// Anything the later one says wins; anything it is silent about keeps what
  /// was already there. That rule is the whole of the cascade here — no
  /// specificity, no ordering surprises, no `!important`, because a style
  /// system somebody has to reason about in layers is one they end up
  /// fighting.
  UiStyle merge(UiStyle other) => UiStyle(
    direction: other.direction ?? direction,
    mainAxis: other.mainAxis ?? mainAxis,
    crossAxis: other.crossAxis ?? crossAxis,
    gap: other.gap ?? gap,
    grow: other.grow ?? grow,
    paddingTop: other.paddingTop ?? paddingTop,
    paddingRight: other.paddingRight ?? paddingRight,
    paddingBottom: other.paddingBottom ?? paddingBottom,
    paddingLeft: other.paddingLeft ?? paddingLeft,
    marginTop: other.marginTop ?? marginTop,
    marginRight: other.marginRight ?? marginRight,
    marginBottom: other.marginBottom ?? marginBottom,
    marginLeft: other.marginLeft ?? marginLeft,
    width: other.width ?? width,
    height: other.height ?? height,
    minWidth: other.minWidth ?? minWidth,
    minHeight: other.minHeight ?? minHeight,
    maxWidth: other.maxWidth ?? maxWidth,
    maxHeight: other.maxHeight ?? maxHeight,
    background: other.background ?? background,
    colour: other.colour ?? colour,
    borderColour: other.borderColour ?? borderColour,
    borderWidth: other.borderWidth ?? borderWidth,
    radius: other.radius ?? radius,
    opacity: other.opacity ?? opacity,
    fontSize: other.fontSize ?? fontSize,
    fontWeight: other.fontWeight ?? fontWeight,
    italic: other.italic ?? italic,
    letterSpacing: other.letterSpacing ?? letterSpacing,
    lineHeight: other.lineHeight ?? lineHeight,
    textAlign: other.textAlign ?? textAlign,
    uppercase: other.uppercase ?? uppercase,
    shadow: other.shadow ?? shadow,
    clip: other.clip ?? clip,
    scroll: other.scroll ?? scroll,
    top: other.top ?? top,
    right: other.right ?? right,
    bottom: other.bottom ?? bottom,
    left: other.left ?? left,
  );

  /// The same style with one thing changed. Only the fields a rule actually
  /// sets are listed at each call site, which is what keeps the vocabulary
  /// readable.
  UiStyle copyWith({
    String? direction,
    String? mainAxis,
    String? crossAxis,
    double? gap,
    double? grow,
    double? paddingTop,
    double? paddingRight,
    double? paddingBottom,
    double? paddingLeft,
    double? marginTop,
    double? marginRight,
    double? marginBottom,
    double? marginLeft,
    double? width,
    double? height,
    double? minWidth,
    double? minHeight,
    double? maxWidth,
    double? maxHeight,
    Color? background,
    Color? colour,
    Color? borderColour,
    double? borderWidth,
    double? radius,
    double? opacity,
    double? fontSize,
    int? fontWeight,
    bool? italic,
    double? letterSpacing,
    double? lineHeight,
    String? textAlign,
    bool? uppercase,
    double? shadow,
    bool? clip,
    String? scroll,
    double? top,
    double? right,
    double? bottom,
    double? left,
  }) => merge(UiStyle(
    direction: direction,
    mainAxis: mainAxis,
    crossAxis: crossAxis,
    gap: gap,
    grow: grow,
    paddingTop: paddingTop,
    paddingRight: paddingRight,
    paddingBottom: paddingBottom,
    paddingLeft: paddingLeft,
    marginTop: marginTop,
    marginRight: marginRight,
    marginBottom: marginBottom,
    marginLeft: marginLeft,
    width: width,
    height: height,
    minWidth: minWidth,
    minHeight: minHeight,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    background: background,
    colour: colour,
    borderColour: borderColour,
    borderWidth: borderWidth,
    radius: radius,
    opacity: opacity,
    fontSize: fontSize,
    fontWeight: fontWeight,
    italic: italic,
    letterSpacing: letterSpacing,
    lineHeight: lineHeight,
    textAlign: textAlign,
    uppercase: uppercase,
    shadow: shadow,
    clip: clip,
    scroll: scroll,
    top: top,
    right: right,
    bottom: bottom,
    left: left,
  ));

  static const UiStyle none = UiStyle();
}
