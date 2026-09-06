import 'dart:convert';

/// One element of an interface, as script describes it.
///
/// A description rather than a widget: script says what it wants and Dart
/// builds it. That is one crossing per change instead of a stream of
/// per-property operations, and it means the widget tree is real Flutter —
/// laid out by Flutter, hit-tested by Flutter, and drawn by Impeller — rather
/// than a second tree pretending to be one.
class UiNode {
  const UiNode({
    required this.type,
    this.classes = '',
    this.css = '',
    this.text,
    this.props = const {},
    this.children = const [],
    this.key,
  });

  /// What to build: `column`, `row`, `stack`, `box`, `text`, `button`,
  /// `image`, `spacer`, `field`, or anything a host has registered.
  final String type;

  /// A utility class list, applied first.
  final String classes;

  /// CSS declarations, applied over the classes.
  final String css;

  /// The words, for the elements that have any.
  final String? text;

  /// Everything else the element needs: an image's source, a field's
  /// placeholder, the name of a callback.
  final Map<String, Object?> props;

  final List<UiNode> children;

  /// What this element is, across rebuilds. Flutter uses it to keep state on
  /// the right widget when a list is reordered.
  final String? key;

  /// Reads a description sent as JSON.
  ///
  /// Forgiving on purpose. Script is written by hand and reloaded on save, so
  /// a half-finished tree arriving mid-edit is the normal case rather than the
  /// exception — an element with no type becomes an empty box rather than an
  /// exception thrown into a frame.
  factory UiNode.fromJson(Object? value) {
    if (value is String) return UiNode(type: 'text', text: value);
    if (value is! Map) return const UiNode(type: 'box');

    final map = value.cast<String, Object?>();
    final children = map['children'];

    return UiNode(
      type: map['type'] is String ? map['type']! as String : 'box',
      classes: map['class'] is String
          ? map['class']! as String
          : (map['className'] is String ? map['className']! as String : ''),
      css: map['style'] is String ? map['style']! as String : '',
      text: map['text'] is String ? map['text']! as String : null,
      props: map['props'] is Map
          ? (map['props']! as Map).cast<String, Object?>()
          : const {},
      key: map['key'] is String ? map['key']! as String : null,
      children: children is List
          ? [for (final child in children) UiNode.fromJson(child)]
          : const [],
    );
  }

  /// Reads a whole description from the text script returned.
  static UiNode decode(String source) {
    final Object? parsed;
    try {
      parsed = jsonDecode(source);
    } on FormatException catch (error) {
      return UiNode(
        type: 'text',
        text: 'The interface could not be read: ${error.message}',
      );
    }
    return UiNode.fromJson(parsed);
  }

  Map<String, Object?> toJson() => {
    'type': type,
    if (classes.isNotEmpty) 'class': classes,
    if (css.isNotEmpty) 'style': css,
    if (text != null) 'text': text,
    if (props.isNotEmpty) 'props': props,
    if (key != null) 'key': key,
    if (children.isNotEmpty)
      'children': [for (final child in children) child.toJson()],
  };

  UiNode copyWith({
    String? type,
    String? classes,
    String? css,
    String? text,
    Map<String, Object?>? props,
    List<UiNode>? children,
    String? key,
  }) =>
      UiNode(
        type: type ?? this.type,
        classes: classes ?? this.classes,
        css: css ?? this.css,
        text: text ?? this.text,
        props: props ?? this.props,
        children: children ?? this.children,
        key: key ?? this.key,
      );

  // ---- editing ----
  //
  // A tree is immutable and an edit makes a new one. That is what lets the
  // editor's undo hold a whole document per step without copying anything by
  // hand, and it is why a path is a list of child indices rather than a
  // pointer at a node: after an edit the old nodes are still there, and a
  // pointer would name one of them.

  /// The node at [path], or null if the path does not lead anywhere.
  ///
  /// An empty path is this node.
  UiNode? at(List<int> path) {
    var here = this;
    for (final index in path) {
      if (index < 0 || index >= here.children.length) return null;
      here = here.children[index];
    }
    return here;
  }

  /// This tree with the node at [path] replaced.
  ///
  /// Every ancestor is rebuilt and every sibling is shared, so an edit deep in
  /// a large interface copies the spine and nothing else.
  UiNode replaceAt(List<int> path, UiNode replacement) {
    if (path.isEmpty) return replacement;

    final index = path.first;
    if (index < 0 || index >= children.length) return this;

    final next = [...children];
    next[index] = children[index].replaceAt(path.sublist(1), replacement);
    return copyWith(children: next);
  }

  /// This tree with a child inserted under [parent] at [index].
  ///
  /// An index past the end appends, which is what "add to this" means when
  /// nothing was selected inside it.
  UiNode insertAt(List<int> parent, int index, UiNode child) {
    final into = at(parent);
    if (into == null) return this;

    final next = [...into.children];
    next.insert(index.clamp(0, next.length), child);
    return replaceAt(parent, into.copyWith(children: next));
  }

  /// This tree with the node at [path] taken out. The root cannot be removed.
  UiNode removeAt(List<int> path) {
    if (path.isEmpty) return this;

    final parentPath = path.sublist(0, path.length - 1);
    final parent = at(parentPath);
    if (parent == null) return this;

    final index = path.last;
    if (index < 0 || index >= parent.children.length) return this;

    final next = [...parent.children]..removeAt(index);
    return replaceAt(parentPath, parent.copyWith(children: next));
  }

  /// This tree with the node at [path] moved among its siblings.
  UiNode moveAt(List<int> path, int to) {
    if (path.isEmpty) return this;

    final parentPath = path.sublist(0, path.length - 1);
    final parent = at(parentPath);
    if (parent == null) return this;

    final from = path.last;
    if (from < 0 || from >= parent.children.length) return this;

    final next = [...parent.children];
    final moving = next.removeAt(from);
    next.insert(to.clamp(0, next.length), moving);
    return replaceAt(parentPath, parent.copyWith(children: next));
  }

  /// Everything under this node, deepest last, with the path to each.
  ///
  /// For a tree view, and for finding what a click landed on: the last match
  /// in this order is the one drawn on top.
  Iterable<({UiNode node, List<int> path})> walk([
    List<int> path = const [],
  ]) sync* {
    yield (node: this, path: path);
    for (var i = 0; i < children.length; i++) {
      yield* children[i].walk([...path, i]);
    }
  }

  // ---- placing ----

  /// Where this element was put, when it was put anywhere.
  ///
  /// Read out of the CSS rather than kept beside it, because the CSS is what
  /// actually positions it — a second copy of the number would be a second
  /// thing to keep in step, and the one that got out of step would be the one
  /// the editor was showing.
  ({double left, double top})? get placed {
    final left = _length('left');
    final top = _length('top');
    if (left == null && top == null) return null;
    return (left: left ?? 0, top: top ?? 0);
  }

  /// This element moved to a place, keeping everything else about its style.
  ///
  /// Rounded to whole pixels by default: an interface authored at fractions of
  /// a pixel is an interface whose file changes every time somebody nudges it,
  /// and the difference is not visible.
  ///
  /// Pass [round] false while something is being dragged. Rounding every frame
  /// of a drag throws away a fraction of a pixel each time, and a slow drag
  /// loses ground — the thing ends up behind the pointer by however long
  /// somebody took over it. Round once, when they let go.
  UiNode placeAt(double left, double top, {bool round = true}) {
    final rest = [
      for (final declaration in css.split(';'))
        if (declaration.trim().isNotEmpty)
          if (!_names(declaration, const {'left', 'top'})) declaration.trim(),
    ];

    return copyWith(
      css: [
        ...rest,
        'left: ${_pixels(left, round)}px',
        'top: ${_pixels(top, round)}px',
      ].join('; '),
    );
  }

  /// A length as the file writes it: whole when it can be, and at most two
  /// decimals when it cannot, so a position is readable rather than exact to
  /// seventeen digits.
  static String _pixels(double value, bool round) {
    if (round || value == value.roundToDouble()) return '${value.round()}';
    return value
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  static bool _names(String declaration, Set<String> wanted) =>
      wanted.contains(declaration.split(':').first.trim().toLowerCase());

  double? _length(String property) {
    for (final declaration in css.split(';')) {
      final parts = declaration.split(':');
      if (parts.length < 2) continue;
      if (parts.first.trim().toLowerCase() != property) continue;
      final value = parts[1].trim().replaceAll(RegExp(r'px$'), '');
      return double.tryParse(value);
    }
    return null;
  }

  /// The name of the callback for an event, if script gave one.
  ///
  /// Callbacks cross as names rather than as functions: a function cannot be
  /// serialised, and a name is what the host calls back with when the button
  /// is pressed.
  String? handlerFor(String event) {
    final value = props[event];
    return value is String && value.isNotEmpty ? value : null;
  }
}
