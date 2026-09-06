import 'dart:convert';

import 'node.dart';

/// How a canvas laid out at one size is shown at another.
///
/// A phone, a laptop and a television are three aspect ratios and four times
/// the pixels, and an interface authored once has to arrive on all of them.
/// The choice is which dimension is allowed to be the one that fits.
enum CanvasFit {
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

  double get aspect => height == 0 ? 1 : width / height;

  /// How much to scale by to put this canvas on a screen of [intoWidth] by
  /// [intoHeight].
  double scaleFor(double intoWidth, double intoHeight) {
    if (width <= 0 || height <= 0) return 1;
    return switch (fit) {
      CanvasFit.width => intoWidth / width,
      CanvasFit.height => intoHeight / height,
      CanvasFit.contain => intoWidth / width < intoHeight / height
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
  }) =>
      UiCanvas(
        width: width ?? this.width,
        height: height ?? this.height,
        fit: fit ?? this.fit,
        safeArea: safeArea ?? this.safeArea,
      );

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'fit': fit.name,
        'safeArea': safeArea,
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

  String toText() => '${const JsonEncoder.withIndent('  ').convert({
        'kind': marker,
        'formatVersion': formatVersion,
        'name': name,
        'canvas': canvas.toJson(),
        'root': root.toJson(),
      })}\n';

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
    if (parsed is! Map<String, Object?> || parsed['kind'] != marker) return null;

    return UiDocument(
      name: parsed['name'] is String ? parsed['name']! as String : 'Interface',
      canvas: UiCanvas.fromJson(parsed['canvas']),
      root: UiNode.fromJson(parsed['root']),
    );
  }
}
