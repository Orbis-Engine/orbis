/// The widths an interface is allowed to change its mind at.
///
/// A class list says what something looks like; a prefix on one of those
/// classes says at what width it starts saying it. `text-base md:text-xl` is
/// one element that is readable on a phone and comfortable on a laptop, and it
/// is one line rather than two layouts kept in step by hand.
///
/// The names are the ones every utility vocabulary uses, for the same reason
/// the rest of the vocabulary is borrowed: somebody already knows them. What
/// they resolve to is Flutter's own layout at the width the interface is
/// actually being drawn at.
///
/// Widths are measured against the whole interface, not the box an element
/// sits in. A layout that changed per container would mean the same element
/// reading differently in two places on one screen, which is not what anybody
/// means by "on a phone".
class UiBreakpoints {
  const UiBreakpoints({
    this.sm = 640,
    this.md = 900,
    this.lg = 1280,
    this.xl = 1680,
  });

  /// A big phone held upright, and the point a two-column layout starts to
  /// fit.
  final double sm;

  /// A tablet, a small window, a handheld held sideways.
  final double md;

  /// A laptop.
  final double lg;

  /// A desktop monitor and everything above it.
  final double xl;

  /// The prefixes, narrowest first.
  ///
  /// `base` is not one of them: it is what a class with no prefix is, and it
  /// applies at every width.
  static const List<String> names = ['sm', 'md', 'lg', 'xl'];

  /// The width [name] starts at, or null if it is not a breakpoint.
  double? startOf(String name) => switch (name) {
    'sm' => sm,
    'md' => md,
    'lg' => lg,
    'xl' => xl,
    _ => null,
  };

  bool knows(String name) => startOf(name) != null;

  /// The prefixes in play at [width], narrowest first.
  ///
  /// Sorted by where they start rather than by the order they are declared in,
  /// because that order is what decides which of two prefixed classes wins:
  /// `md:text-xl lg:text-3xl` has to mean the larger size on a laptop whatever
  /// order somebody typed them in, and whatever numbers a theme gave them.
  List<String> activeAt(double width) {
    final active = [
      for (final name in names)
        if (width >= (startOf(name) ?? double.infinity)) name,
    ];
    active.sort((a, b) => startOf(a)!.compareTo(startOf(b)!));
    return active;
  }

  /// What to call [width]: the widest breakpoint it has reached, or `base`.
  ///
  /// For an editor to say which of an element's class lists is the one being
  /// looked at, which is the question somebody asks the moment a prefixed
  /// class appears to do nothing.
  String labelAt(double width) {
    final active = activeAt(width);
    return active.isEmpty ? 'base' : active.last;
  }

  UiBreakpoints copyWith({double? sm, double? md, double? lg, double? xl}) =>
      UiBreakpoints(
        sm: sm ?? this.sm,
        md: md ?? this.md,
        lg: lg ?? this.lg,
        xl: xl ?? this.xl,
      );
}
