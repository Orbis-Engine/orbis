import 'dart:convert';

import 'node.dart';

/// How a canvas laid out at one size is shown at another.
///
/// A phone, a laptop and a television are three aspect ratios and four times
/// the pixels, and an interface authored once has to arrive on all of them.
/// The choice is which dimension is allowed to be the one that fits.
enum CanvasFit {
  /// Not scaled — laid out at whatever size the screen is.
  ///
  /// The reference size stops being what ships and becomes what somebody
  /// designed against: a phone lays the same interface out in its own width,
  /// the prefixed classes decide what changes on the way, and text and spacing
  /// grow with the screen rather than the whole picture being magnified. For
  /// anything that has to look right on a handheld and a television, which is
  /// most of an interface.
  responsive('Responsive'),

  /// Scaled so the reference width fills the screen. Height overflows or falls
  /// short. For an interface anchored to the sides — a toolbar, a HUD strip.
  width('Match width'),

  /// Scaled so the reference height fits. For an interface anchored to the top
  /// and bottom.
  height('Match height'),

  /// Scaled so all of it fits, with bars where the aspect does not match. The
  /// safe default: nothing is ever cut off, and what somebody laid out is what
  /// they get.
  contain('Fit inside'),

  /// Not scaled at all. Pixels are pixels, and the canvas is as big as the
  /// screen gives it. For an interface built out of fixed-size things.
  none('Actual size');

  const CanvasFit(this.label);

  final String label;

  static CanvasFit named(Object? name) {
    for (final fit in values) {
      if (fit.name == name) return fit;
    }
    return CanvasFit.contain;
  }
}

/// The surface an interface is laid out on.
///
/// A canvas is a design-time idea: it says what size the interface was
/// authored at and how to get from that to whatever the screen actually is.
/// It draws nothing itself. The editor shows its bounds and its safe area so
/// somebody can see where they are putting things; the game shows the
/// interface and no canvas at all.
class UiCanvas {
  const UiCanvas({
    this.width = 1920,
    this.height = 1080,
    this.fit = CanvasFit.contain,
    this.safeArea = 0.05,
    this.columns = 12,
    this.gutter = 24,
    this.minScale = 0.8,
    this.maxScale = 1.5,
  });

  /// What it was laid out at.
  final double width;
  final double height;

  final CanvasFit fit;

  /// How much of each edge is not to be trusted, as a fraction.
  ///
  /// A television overscans, a phone has a notch and a home indicator, and a
  /// handheld has bezels. Anything important belongs inside this. Shown in the
  /// editor as a second rectangle and nowhere else — it is a guide, not a
  /// clip: an interface that deliberately bleeds to the edge should be able
  /// to.
  final double safeArea;

  /// How many columns the layout grid is divided into.
  ///
  /// A grid is a decision made once and then obeyed: twelve columns is the one
  /// every layout tool settled on because it divides by two, three, four and
  /// six, which is every split anybody actually asks for. Drawn in the editor
  /// and nowhere else — it positions nothing by itself, it is what somebody
  /// positions things against.
  final int columns;

  /// The space between two columns, in canvas pixels.
  final double gutter;

  /// How far the fluid scale is allowed to go, on a narrow screen and a wide
  /// one.
  ///
  /// Unclamped, a phone showing an interface designed at 1920 would set it in
  /// four-point type and a television would set it in headlines. The clamp is
  /// what turns "scale with the screen" into something shippable: below the
  /// floor a phone stops shrinking and starts scrolling, above the ceiling a
  /// big screen stops magnifying and starts showing more.
  final double minScale;
  final double maxScale;

  double get aspect => height == 0 ? 1 : width / height;

  /// How much bigger everything measured in the vocabulary gets, on a screen
  /// [atWidth] wide.
  ///
  /// One for every fit but [CanvasFit.responsive], where the whole canvas is
  /// already being scaled and scaling the text inside it again would compound.
  double fluidScale(double atWidth) {
    if (fit != CanvasFit.responsive) return 1;
    if (width <= 0 || atWidth <= 0 || !atWidth.isFinite) return 1;
    return (atWidth / width).clamp(minScale, maxScale);
  }

  /// Where the grid starts and stops across a canvas [ofWidth] wide.
  ///
  /// Inside the safe area rather than edge to edge, because the outer margin a
  /// grid needs and the edge a television eats are the same measurement, and
  /// two numbers for one distance is one of them being wrong.
  ({double left, double right}) gridSpanAcross(double ofWidth) =>
      (left: ofWidth * safeArea, right: ofWidth * (1 - safeArea));

  /// The narrowest a column may be drawn before the grid gives up a division.
  ///
  /// Twelve columns across a phone is twelve seven-pixel slivers: not a grid
  /// anybody can lay out against, and — worse — indistinguishable from the
  /// layout it is meant to be measuring.
  static const double minColumnWidth = 40;

  /// How many columns the grid actually draws across a canvas [ofWidth] wide.
  ///
  /// The authored count where it fits, and otherwise the largest **divisor**
  /// of it that does. A divisor rather than any smaller number so that every
  /// narrower grid is a subset of the wider one's lines: twelve columns become
  /// six, then four, then three, and a thing lined up on a desktop column is
  /// still lined up on a phone one. Zero when even a single column will not
  /// fit, which draws nothing rather than nonsense.
  int columnsAt(double ofWidth) {
    if (columns <= 0 || ofWidth <= 0) return 0;

    final span = gridSpanAcross(ofWidth);
    final usable = span.right - span.left;

    for (var count = columns; count >= 1; count--) {
      if (columns % count != 0) {
        continue;
      }
      final each = (usable - gutter * (count - 1)) / count;
      if (each >= minColumnWidth) return count;
    }
    return 0;
  }

  /// Every column, left and right, across a canvas [ofWidth] wide.
  ///
  /// As many as [columnsAt] says fit. Empty when none do, which draws nothing
  /// and snaps to nothing rather than drawing columns of negative width.
  List<({double left, double right})> columnsAcross(double ofWidth) {
    final columns = columnsAt(ofWidth);
    if (columns == 0) return const [];

    final span = gridSpanAcross(ofWidth);
    final each = (span.right - span.left - gutter * (columns - 1)) / columns;
    if (each <= 0) return const [];

    return [
      for (var i = 0; i < columns; i++)
        (
          left: span.left + i * (each + gutter),
          right: span.left + i * (each + gutter) + each,
        ),
    ];
  }

  /// The column edge nearest [x], or null if none is close enough.
  ///
  /// What makes the grid a thing somebody lays out against rather than a
  /// picture of one. [within] is in canvas pixels: far enough that a hand
  /// aiming at a column lands on it, near enough that something deliberately
  /// placed between two columns stays there.
  double? snapAcross(double x, double ofWidth, {double within = 8}) {
    double? nearest;
    var closest = within;

    for (final column in columnsAcross(ofWidth)) {
      for (final edge in [column.left, column.right]) {
        final distance = (x - edge).abs();
        if (distance <= closest) {
          closest = distance;
          nearest = edge;
        }
      }
    }
    return nearest;
  }

  /// How much to scale by to put this canvas on a screen of [intoWidth] by
  /// [intoHeight].
  double scaleFor(double intoWidth, double intoHeight) {
    if (width <= 0 || height <= 0) return 1;
    return switch (fit) {
      // Nothing is scaled: the interface is laid out at the size it is being
      // shown at, which is the whole of what responsive means here.
      CanvasFit.responsive => 1,
      CanvasFit.width => intoWidth / width,
      CanvasFit.height => intoHeight / height,
      CanvasFit.contain =>
        intoWidth / width < intoHeight / height
            ? intoWidth / width
            : intoHeight / height,
      CanvasFit.none => 1,
    };
  }

  UiCanvas copyWith({
    double? width,
    double? height,
    CanvasFit? fit,
    double? safeArea,
    int? columns,
    double? gutter,
    double? minScale,
    double? maxScale,
  }) => UiCanvas(
    width: width ?? this.width,
    height: height ?? this.height,
    fit: fit ?? this.fit,
    safeArea: safeArea ?? this.safeArea,
    columns: columns ?? this.columns,
    gutter: gutter ?? this.gutter,
    minScale: minScale ?? this.minScale,
    maxScale: maxScale ?? this.maxScale,
  );

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'fit': fit.name,
    'safeArea': safeArea,
    'columns': columns,
    'gutter': gutter,
    'minScale': minScale,
    'maxScale': maxScale,
  };

  static UiCanvas fromJson(Object? value) {
    if (value is! Map) return const UiCanvas();
    final map = value.cast<String, Object?>();
    double number(String key, double fallback) =>
        map[key] is num ? (map[key]! as num).toDouble() : fallback;

    return UiCanvas(
      width: number('width', 1920),
      height: number('height', 1080),
      fit: CanvasFit.named(map['fit']),
      safeArea: number('safeArea', 0.05).clamp(0, 0.45),
      columns: map['columns'] is num
          ? (map['columns']! as num).round().clamp(1, 24)
          : 12,
      gutter: number('gutter', 24).clamp(0, 400),
      minScale: number('minScale', 0.8).clamp(0.1, 1),
      maxScale: number('maxScale', 1.5).clamp(1, 8),
    );
  }
}

/// An interface saved as a file.
///
/// The canvas plus the tree on it, which is everything needed to draw it and
/// everything needed to edit it. Written as the same JSON a script sends, so
/// a tree that came from a script can be saved as a document and a document
/// can be handed to a script — the two authoring paths meet here rather than
/// each keeping their own idea of what an interface is.
class UiDocument {
  const UiDocument({
    this.canvas = const UiCanvas(),
    this.root = const UiNode(type: 'box'),
    this.name = 'Interface',
  });

  final UiCanvas canvas;
  final UiNode root;

  /// What it is called, which need not match the file name.
  final String name;

  static const String marker = 'orbis.ui';
  static const int formatVersion = 1;
  static const String extension = '.oui';

  /// A new one: a full-bleed root with something visible on it.
  ///
  /// Not empty, for the same reason a new script is not empty — an empty
  /// canvas gives nothing to drag, nothing to select and nothing to learn the
  /// shape of the thing from.
  /// A new one: a free-positioned root with something visible on it.
  ///
  /// The root is a stack, so what goes on it is placed where it was put rather
  /// than flowed one after another. That is what a canvas is for — an
  /// interface is anchored to corners and edges, not stacked down the page —
  /// and it is what makes dragging something mean anything. A column inside it
  /// is still a column; the choice is per container rather than for the whole
  /// document.
  factory UiDocument.blank(String name) => UiDocument(
    name: name,
    // Responsive from the first frame. A canvas that starts fixed and has
    // to be made responsive later is one where every position already
    // assumes a width, and the conversion is the whole layout again.
    canvas: const UiCanvas(fit: CanvasFit.responsive),
    root: const UiNode(
      type: 'stack',
      classes: 'w-full h-full',
      children: [
        UiNode(
          type: 'text',
          classes: 'text-3xl font-bold text-white',
          css: 'left: 96px; top: 84px',
          text: 'Title',
        ),
        UiNode(
          type: 'text',
          classes: 'text-base text-slate-300',
          css: 'left: 96px; top: 136px',
          text: 'Say what this screen is for.',
        ),
      ],
    ),
  );

  UiDocument copyWith({UiCanvas? canvas, UiNode? root, String? name}) =>
      UiDocument(
        canvas: canvas ?? this.canvas,
        root: root ?? this.root,
        name: name ?? this.name,
      );

  String toText() =>
      '${const JsonEncoder.withIndent('  ').convert({'kind': marker, 'formatVersion': formatVersion, 'name': name, 'canvas': canvas.toJson(), 'root': root.toJson()})}\n';

  /// Reads one, or null if it is not an interface.
  ///
  /// Null rather than an exception: a `.oui` may have been written by a newer
  /// build or edited by hand, and a browser that throws on one bad file shows
  /// nothing at all.
  static UiDocument? read(String text) {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (parsed is! Map<String, Object?> || parsed['kind'] != marker) {
      return null;
    }

    return UiDocument(
      name: parsed['name'] is String ? parsed['name']! as String : 'Interface',
      canvas: UiCanvas.fromJson(parsed['canvas']),
      root: UiNode.fromJson(parsed['root']),
    );
  }
}
