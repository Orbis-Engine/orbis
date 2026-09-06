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
