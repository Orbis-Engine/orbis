import 'dart:convert';

/// One layer of a tile map.
class TileLayer {
  const TileLayer({
    required this.name,
    required this.width,
    required this.height,
    required this.tiles,
    this.visible = true,
    this.opacity = 1,
  });

  final String name;
  final int width;
  final int height;

  /// The tile at each cell, in reading order. Zero is nothing.
  ///
  /// Zero rather than -1 because that is what every editor writes, and
  /// translating it on the way in is one more place for an off-by-one.
  final List<int> tiles;

  final bool visible;
  final double opacity;

  /// The tile at a cell, or zero outside the map.
  ///
  /// Outside is empty rather than an error: a map is walked by things that
  /// wander off the edge of it, and every caller checking the bounds itself
  /// is every caller getting it slightly wrong.
  int at(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return 0;
    return tiles[y * width + x];
  }

  bool isEmptyAt(int x, int y) => at(x, y) == 0;
}

/// Which image a tile number comes from, and where in it.
class Tileset {
  const Tileset({
    required this.name,
    required this.image,
    required this.firstId,
    required this.tileWidth,
    required this.tileHeight,
    required this.columns,
    this.count = 0,
    this.spacing = 0,
    this.margin = 0,
  });

  final String name;
  final String image;

  /// The number the first tile of this set has in the map.
  ///
  /// A map with several tilesets numbers them end to end, so which set a tile
  /// belongs to is worked out by finding the last set whose first id is not
  /// above it. Getting that backwards draws the right shape from the wrong
  /// sheet, which reads as a corrupt map rather than a lookup fault.
  final int firstId;

  final int tileWidth;
  final int tileHeight;
  final int columns;
  final int count;
  final int spacing;
  final int margin;

  bool has(int id) => id >= firstId && (count == 0 || id < firstId + count);

  /// Where tile [id] sits in this set's image, in pixels.
  ({int x, int y, int width, int height})? rectOf(int id) {
    if (!has(id) || columns <= 0) return null;
    final local = id - firstId;
    final column = local % columns;
    final row = local ~/ columns;
    return (
      x: margin + column * (tileWidth + spacing),
      y: margin + row * (tileHeight + spacing),
      width: tileWidth,
      height: tileHeight,
    );
  }
}

/// A map of tiles, as an editor wrote it.
///
/// Read rather than reinvented. Tiled is what people already use, its format
/// is stable, and a bespoke one would mean an editor to go with it — so this
/// takes the subset that matters and says plainly what it ignores.
class TileMap {
  const TileMap({
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
    required this.layers,
    required this.tilesets,
    this.properties = const {},
  });

  /// In tiles.
  final int width;
  final int height;

  /// In pixels.
  final int tileWidth;
  final int tileHeight;

  final List<TileLayer> layers;
  final List<Tileset> tilesets;

  /// Whatever the map carried, unchanged.
  final Map<String, Object?> properties;

  TileLayer? layer(String name) {
    for (final found in layers) {
      if (found.name == name) return found;
    }
    return null;
  }

  /// Which set tile [id] comes from.
  Tileset? setFor(int id) {
    if (id <= 0) return null;
    Tileset? best;
    for (final set in tilesets) {
      if (set.firstId <= id && (best == null || set.firstId > best.firstId)) {
        best = set;
      }
    }
    return best;
  }

  /// The cell a point in world pixels falls in.
  (int, int) cellAt(double x, double y) =>
      ((x / tileWidth).floor(), (y / tileHeight).floor());

  /// Whether any layer has something at a cell.
  bool isSolidAt(int x, int y, {Set<String>? only}) {
    for (final layer in layers) {
      if (only != null && !only.contains(layer.name)) continue;
      if (!layer.visible) continue;
      if (layer.at(x, y) != 0) return true;
    }
    return false;
  }

  /// Reads a Tiled map saved as JSON.
  ///
  /// The orthogonal, uncompressed subset — which is what the editor writes by
  /// default and covers nearly every 2D game. What it does not read is said
  /// out loud rather than failing quietly: isometric and hexagonal maps,
  /// base64 or zlib layer data, object layers, and external tileset files.
  /// Any of those come back as null, so a caller knows to look rather than
  /// wondering why the map is empty.
  static TileMap? read(String text) {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (parsed is! Map<String, Object?>) return null;

    // Anything but a plain grid is a different reader, and pretending
    // otherwise draws a map at the wrong angle.
    final orientation = parsed['orientation'];
    if (orientation is String && orientation != 'orthogonal') return null;

    final layers = <TileLayer>[];
    final rawLayers = parsed['layers'];
    if (rawLayers is! List) return null;

    for (final entry in rawLayers) {
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      if (map['type'] != 'tilelayer') continue;

      // Compressed or base64 data is a decoder this does not have. Returning
      // an empty layer would be a map that silently lost a floor.
      final encoding = map['encoding'];
      if (encoding != null && encoding != 'csv') return null;
      if (map['compression'] != null && map['compression'] != '') return null;

      final data = map['data'];
      if (data is! List) return null;

      layers.add(
        TileLayer(
          name: map['name'] is String ? map['name']! as String : '',
          width: _int(map['width']),
          height: _int(map['height']),
          tiles: [for (final tile in data) _int(tile)],
          visible: map['visible'] != false,
          opacity: map['opacity'] is num
              ? (map['opacity']! as num).toDouble()
              : 1.0,
        ),
      );
    }

    final tilesets = <Tileset>[];
    final rawSets = parsed['tilesets'];
    if (rawSets is List) {
      for (final entry in rawSets) {
        if (entry is! Map) continue;
        final map = entry.cast<String, Object?>();
        // An external tileset is a second file this was not given.
        if (map['source'] != null) return null;

        tilesets.add(
          Tileset(
            name: map['name'] is String ? map['name']! as String : '',
            image: map['image'] is String ? map['image']! as String : '',
            firstId: _int(map['firstgid']),
            tileWidth: _int(map['tilewidth']),
            tileHeight: _int(map['tileheight']),
            columns: _int(map['columns']),
            count: _int(map['tilecount']),
            spacing: _int(map['spacing']),
            margin: _int(map['margin']),
          ),
        );
      }
    }

    return TileMap(
      width: _int(parsed['width']),
      height: _int(parsed['height']),
      tileWidth: _int(parsed['tilewidth']),
      tileHeight: _int(parsed['tileheight']),
      layers: layers,
      tilesets: tilesets,
      properties: parsed['properties'] is Map
          ? (parsed['properties']! as Map).cast<String, Object?>()
          : const {},
    );
  }
}

int _int(Object? value) => value is num ? value.round() : 0;
