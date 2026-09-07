import 'dart:convert';

/// A rectangle of pixels inside a larger image.
class Region {
  const Region({
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotated = false,
    this.trimmed = false,
    this.offsetX = 0,
    this.offsetY = 0,
    this.sourceWidth = 0,
    this.sourceHeight = 0,
  });

  final String name;

  /// Where it sits in the packed image, in pixels.
  final int x;
  final int y;
  final int width;
  final int height;

  /// Whether the packer turned it a quarter turn to fit.
  ///
  /// Ignoring this is the commonest way an atlas comes out wrong: a handful
  /// of frames — the ones that happened to pack better sideways — are drawn
  /// on their side, and only those.
  final bool rotated;

  /// Whether the packer cut the empty space off it.
  final bool trimmed;

  /// Where the trimmed part sits inside the original frame.
  ///
  /// A trimmed sprite drawn at its own size is a sprite that jumps about
  /// between frames: the packer cut a different amount off each one, and
  /// without the offset every frame is drawn snug against its own corner.
  final int offsetX;
  final int offsetY;

  /// How big it was before trimming. Zero when it was never trimmed.
  final int sourceWidth;
  final int sourceHeight;

  /// Its size as the game should treat it — the original, if it was trimmed.
  (int, int) get placedSize => trimmed && sourceWidth > 0
      ? (sourceWidth, sourceHeight)
      : (width, height);

  /// Texture coordinates, given the size of the image it came from.
  ///
  /// Fractions rather than pixels, because that is what a sampler takes and
  /// converting at the call site is where the half-texel mistakes happen.
  ({double u0, double v0, double u1, double v1}) uv(
    int imageWidth,
    int imageHeight,
  ) {
    if (imageWidth <= 0 || imageHeight <= 0) {
      return (u0: 0, v0: 0, u1: 1, v1: 1);
    }
    return (
      u0: x / imageWidth,
      v0: y / imageHeight,
      u1: (x + width) / imageWidth,
      v1: (y + height) / imageHeight,
    );
  }
}

/// Many images packed into one, and where each of them is.
///
/// The reason to bother is not disk space. It is that a draw call can only
/// bind one texture, so a hundred sprites in a hundred images is a hundred
/// draw calls and the same hundred in one image is one.
class Atlas {
  const Atlas({
    required this.image,
    required this.regions,
    this.width = 0,
    this.height = 0,
  });

  /// The file the regions are cut from.
  final String image;

  /// Every region, by name.
  final Map<String, Region> regions;

  /// The packed image's size in pixels, when the file said.
  final int width;
  final int height;

  Region? operator [](String name) => regions[name];

  int get length => regions.length;

  /// Every region whose name begins with [prefix], in name order.
  ///
  /// How a sprite sheet becomes an animation: packers name frames
  /// `run_00`, `run_01` and so on, and the sort is what puts them back in
  /// order. Sorted by name rather than by the file's order, because a packer
  /// is free to write them in whatever order packed best.
  List<Region> sequence(String prefix) {
    final found = [
      for (final entry in regions.entries)
        if (entry.key.startsWith(prefix)) entry.value,
    ];
    found.sort((a, b) => _naturally(a.name, b.name));
    return found;
  }

  /// A whole image cut into equal cells.
  ///
  /// The other kind of sheet, and much the commoner one in practice: no
  /// metadata file at all, just a grid. Named `<name>_0` and up, in reading
  /// order.
  factory Atlas.grid({
    required String image,
    required int imageWidth,
    required int imageHeight,
    required int cellWidth,
    required int cellHeight,
    String name = 'frame',
    int count = 0,
    int spacing = 0,
    int margin = 0,
  }) {
    final regions = <String, Region>{};
    if (cellWidth <= 0 || cellHeight <= 0) {
      return Atlas(
        image: image,
        regions: regions,
        width: imageWidth,
        height: imageHeight,
      );
    }

    final across = (imageWidth - margin * 2 + spacing) ~/ (cellWidth + spacing);
    final down = (imageHeight - margin * 2 + spacing) ~/ (cellHeight + spacing);
    var made = 0;

    for (var row = 0; row < down; row++) {
      for (var column = 0; column < across; column++) {
        if (count > 0 && made >= count) break;
        regions['${name}_$made'] = Region(
          name: '${name}_$made',
          x: margin + column * (cellWidth + spacing),
          y: margin + row * (cellHeight + spacing),
          width: cellWidth,
          height: cellHeight,
        );
        made++;
      }
    }
    return Atlas(
      image: image,
      regions: regions,
      width: imageWidth,
      height: imageHeight,
    );
  }

  /// Reads what TexturePacker, Aseprite and the rest write.
  ///
  /// Both shapes of the same format are accepted: `frames` as an object keyed
  /// by name, and as an array with the name inside each entry. They are the
  /// same information and which one a file has depends on a checkbox in the
  /// tool, which is not a thing a game should have to care about.
  ///
  /// Null rather than an exception for a file that is not one of these: an
  /// atlas is an asset somebody typed a path to, and refusing to load the
  /// whole level because one is malformed is worse than drawing it without.
  static Atlas? read(String text, {String? image}) {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (parsed is! Map<String, Object?>) return null;

    final frames = parsed['frames'];
    final meta = parsed['meta'];
    final regions = <String, Region>{};

    void take(String name, Object? entry) {
      if (entry is! Map) return;
      final map = entry.cast<String, Object?>();
      final frame = map['frame'];
      if (frame is! Map) return;
      final box = frame.cast<String, Object?>();

      final source = map['spriteSourceSize'];
      final sourceBox = source is Map
          ? source.cast<String, Object?>()
          : const <String, Object?>{};
      final size = map['sourceSize'];
      final sizeBox = size is Map
          ? size.cast<String, Object?>()
          : const <String, Object?>{};

      regions[name] = Region(
        name: name,
        x: _int(box['x']),
        y: _int(box['y']),
        width: _int(box['w']),
        height: _int(box['h']),
        rotated: map['rotated'] == true,
        trimmed: map['trimmed'] == true,
        offsetX: _int(sourceBox['x']),
        offsetY: _int(sourceBox['y']),
        sourceWidth: _int(sizeBox['w']),
        sourceHeight: _int(sizeBox['h']),
      );
    }

    if (frames is Map) {
      frames.forEach((key, value) => take('$key', value));
    } else if (frames is List) {
      for (final entry in frames) {
        if (entry is! Map) continue;
        final name = entry['filename'];
        take(name is String ? name : '${regions.length}', entry);
      }
    } else {
      return null;
    }

    final metaMap = meta is Map
        ? meta.cast<String, Object?>()
        : const <String, Object?>{};
    final metaSize = metaMap['size'];
    final sizeBox = metaSize is Map
        ? metaSize.cast<String, Object?>()
        : const <String, Object?>{};

    return Atlas(
      image:
          image ??
          (metaMap['image'] is String ? metaMap['image']! as String : ''),
      regions: regions,
      width: _int(sizeBox['w']),
      height: _int(sizeBox['h']),
    );
  }
}

int _int(Object? value) => value is num ? value.round() : 0;

/// Compares names so that `run_2` comes before `run_10`.
///
/// Plain string order puts `run_10` before `run_2`, which reverses the middle
/// of every animation with more than nine frames — and does it only for those,
/// so it looks like a bad export rather than a sort.
int _naturally(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);
    final aDigit = ca >= 48 && ca <= 57;
    final bDigit = cb >= 48 && cb <= 57;

    if (aDigit && bDigit) {
      var x = 0;
      while (i < a.length && a.codeUnitAt(i) >= 48 && a.codeUnitAt(i) <= 57) {
        x = x * 10 + (a.codeUnitAt(i) - 48);
        i++;
      }
      var y = 0;
      while (j < b.length && b.codeUnitAt(j) >= 48 && b.codeUnitAt(j) <= 57) {
        y = y * 10 + (b.codeUnitAt(j) - 48);
        j++;
      }
      if (x != y) return x.compareTo(y);
      continue;
    }
    if (ca != cb) return ca.compareTo(cb);
    i++;
    j++;
  }
  return (a.length - i).compareTo(b.length - j);
}
