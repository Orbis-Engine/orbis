import 'dart:convert';

import 'package:orbis_sprite/orbis_sprite.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('an atlas from a grid', () {
    final sheet = Atlas.grid(
      image: 'hero.png',
      imageWidth: 96,
      imageHeight: 64,
      cellWidth: 32,
      cellHeight: 32,
      name: 'run',
    );

    test('it cuts the whole sheet in reading order', () {
      expect(sheet.length, 6);
      expect(sheet['run_0']!.x, 0);
      expect(sheet['run_2']!.x, 64);
      expect(sheet['run_3']!.y, 32);
    });

    test('a count stops it early', () {
      final four = Atlas.grid(
        image: 'a.png',
        imageWidth: 96,
        imageHeight: 64,
        cellWidth: 32,
        cellHeight: 32,
        count: 4,
      );
      expect(four.length, 4);
    });

    test('spacing and margin are counted', () {
      final spaced = Atlas.grid(
        image: 'a.png',
        imageWidth: 70,
        imageHeight: 36,
        cellWidth: 32,
        cellHeight: 32,
        spacing: 2,
        margin: 2,
      );
      expect(spaced.length, 2);
      expect(spaced['frame_1']!.x, 36);
    });

    test('a cell of no size is refused rather than looping', () {
      expect(
        Atlas.grid(
          image: 'a.png',
          imageWidth: 96,
          imageHeight: 64,
          cellWidth: 0,
          cellHeight: 0,
        ).length,
        0,
      );
    });

    test('texture coordinates are fractions of the image', () {
      final uv = sheet['run_1']!.uv(96, 64);
      expect(uv.u0, closeTo(32 / 96, 1e-9));
      expect(uv.u1, closeTo(64 / 96, 1e-9));
      expect(uv.v0, closeTo(0, 1e-9));
    });
  });

  group('an atlas from a packer', () {
    String packed({bool asList = false}) {
      final frame = {
        'frame': {'x': 10, 'y': 20, 'w': 30, 'h': 40},
        'rotated': true,
        'trimmed': true,
        'spriteSourceSize': {'x': 3, 'y': 4},
        'sourceSize': {'w': 36, 'h': 48},
      };
      return jsonEncode({
        'frames': asList
            ? [
                {'filename': 'walk_1', ...frame},
              ]
            : {'walk_1': frame},
        'meta': {
          'image': 'sheet.png',
          'size': {'w': 512, 'h': 256},
        },
      });
    }

    test('both shapes of the same format read the same', () {
      // Which one a file has depends on a checkbox in the tool, which is not
      // a thing a game should have to care about.
      final asMap = Atlas.read(packed())!;
      final asList = Atlas.read(packed(asList: true))!;

      expect(asMap.length, asList.length);
      expect(asMap['walk_1']!.x, asList['walk_1']!.x);
      expect(asMap.image, 'sheet.png');
      expect(asMap.width, 512);
    });

    test('rotation and trimming are carried, not dropped', () {
      // Dropping rotation draws the handful of frames that packed sideways on
      // their side; dropping the trim offset makes every frame jump about.
      final region = Atlas.read(packed())!['walk_1']!;
      expect(region.rotated, isTrue);
      expect(region.trimmed, isTrue);
      expect(region.offsetX, 3);
      expect(region.placedSize, (36, 48));
    });

    test('an untrimmed region is its own size', () {
      final plain = Atlas.grid(
        image: 'a.png',
        imageWidth: 32,
        imageHeight: 32,
        cellWidth: 32,
        cellHeight: 32,
      );
      expect(plain['frame_0']!.placedSize, (32, 32));
    });

    test('something that is not an atlas is null, not an exception', () {
      // An atlas is a path somebody typed; refusing to load the level because
      // one is malformed is worse than drawing it without.
      expect(Atlas.read('not json at all'), isNull);
      expect(Atlas.read('{"nothing": 1}'), isNull);
    });

    test('frames are ordered by number, not by string', () {
      // Plain string order puts run_10 before run_2, which reverses the
      // middle of every animation with more than nine frames.
      final many = Atlas.read(
        jsonEncode({
          'frames': {
            for (var i = 0; i < 12; i++)
              'run_$i': {
                'frame': {'x': i, 'y': 0, 'w': 1, 'h': 1},
              },
          },
        }),
      )!;
      expect(many.sequence('run_').map((r) => r.x).toList(), [
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
      ]);
    });

    test('a sequence takes only what matches', () {
      final mixed = Atlas.read(
        jsonEncode({
          'frames': {
            'run_0': {
              'frame': {'x': 1, 'y': 0, 'w': 1, 'h': 1},
            },
            'idle_0': {
              'frame': {'x': 2, 'y': 0, 'w': 1, 'h': 1},
            },
          },
        }),
      )!;
      expect(mixed.sequence('run_'), hasLength(1));
    });
  });

  group('an animation', () {
    final sheet = Atlas.grid(
      image: 'hero.png',
      imageWidth: 128,
      imageHeight: 32,
      cellWidth: 32,
      cellHeight: 32,
      name: 'run',
    );

    test('it shows each frame in turn', () {
      final run = SpriteAnimation.from(sheet, 'run', fps: 10);
      expect(run.duration, closeTo(0.4, 1e-9));
      expect(run.indexAt(0), 0);
      expect(run.indexAt(0.15), 1);
      expect(run.indexAt(0.25), 2);
      expect(run.indexAt(0.35), 3);
    });

    test('a loop starts again and is cheap to ask about late', () {
      final run = SpriteAnimation.from(sheet, 'run', fps: 10);
      expect(run.indexAt(0.45), 0);
      expect(run.indexAt(1000.45), 0);
    });

    test('a run that does not loop holds its last frame', () {
      final once = SpriteAnimation.from(sheet, 'run', fps: 10, loop: false);
      expect(once.indexAt(9), 3);
      expect(once.doneBy(0.5), isTrue);
      expect(once.doneBy(0.2), isFalse);
    });

    test('ping-pong comes back down without holding the far end twice', () {
      // A plain loop shows a jump on every repeat; a ping-pong that repeated
      // the end frame would hold it for twice as long as every other.
      final breathe = SpriteAnimation.from(
        sheet,
        'run',
        fps: 10,
        pingPong: true,
      );
      expect(breathe.cycle, closeTo(0.8, 1e-9));
      expect(breathe.indexAt(0.35), 3);
      expect(breathe.indexAt(0.45), 3);
      expect(breathe.indexAt(0.55), 2);
      expect(breathe.indexAt(0.75), 0);
    });

    test('frames can be held for different lengths', () {
      // An animator's timing is not even: a punch holds on the wind-up and
      // flies through the strike.
      final punch = SpriteAnimation([
        Frame(sheet['run_0']!, 0.5),
        Frame(sheet['run_1']!, 0.05),
        Frame(sheet['run_2']!, 0.05),
      ], loop: false);

      expect(punch.indexAt(0.4), 0);
      expect(punch.indexAt(0.52), 1);
      expect(punch.indexAt(0.58), 2);
    });

    test('an empty animation shows nothing rather than throwing', () {
      const nothing = SpriteAnimation([]);
      expect(nothing.isEmpty, isTrue);
      expect(nothing.at(1), isNull);
      expect(nothing.indexAt(1), 0);
    });

    test('a negative time is the beginning', () {
      final run = SpriteAnimation.from(sheet, 'run', fps: 10);
      expect(run.indexAt(-5), 0);
    });
  });

  group('a flipbook', () {
    final sheet = Atlas.grid(
      image: 'hero.png',
      imageWidth: 64,
      imageHeight: 32,
      cellWidth: 32,
      cellHeight: 32,
      name: 'f',
    );
    Flipbook make() => Flipbook({
      'idle': SpriteAnimation.from(sheet, 'f', fps: 10),
      'walk': SpriteAnimation.from(sheet, 'f', fps: 20),
    }, playing: 'idle');

    test('playing the same clip again is not a restart', () {
      // A game says "walk" on every frame the stick is held; restarting on
      // each of those is a character stuck on frame one.
      final book = make()..advance(0.15);
      book.play('idle');
      expect(book.since, closeTo(0.15, 1e-9));
    });

    test('changing clip starts the new one from the beginning', () {
      final book = make()..advance(0.15);
      book.play('walk');
      expect(book.playing, 'walk');
      expect(book.since, 0);
    });

    test('restarting is possible when it is asked for', () {
      final book = make()..advance(0.15);
      book.play('idle', restart: true);
      expect(book.since, 0);
    });

    test('a clip it does not have is ignored', () {
      final book = make();
      book.play('nonesuch');
      expect(book.playing, 'idle');
    });

    test('it says which frame to draw', () {
      final book = make()..advance(0.15);
      expect(book.frame, isNotNull);
      expect(book.frame!.name, 'f_1');
    });
  });

  group('parallax', () {
    test('nearer layers move more than further ones', () {
      const scene = Parallax([
        Layer(image: 'sky.png', depth: 0),
        Layer(image: 'hills.png', depth: 0.2),
        Layer(image: 'ground.png', depth: 1),
      ]);
      final places = scene.at(100, 0);

      expect(places[0], closeTo(0, 1e-9));
      expect(places[1], closeTo(-20, 1e-9));
      expect(places[2], closeTo(-100, 1e-9));
    });

    test('a wrapping layer stays inside one width however far it scrolls', () {
      // What keeps a long-running background from juddering: the numbers
      // never grow large enough to lose precision.
      const scene = Parallax([Layer(image: 'a.png', depth: 1, size: 64)]);
      for (final camera in [0.0, 100.0, 10000.0, 1e7]) {
        final place = scene.at(camera, 0).single;
        expect(place, greaterThan(-64.0000001));
        expect(place, lessThanOrEqualTo(0.0000001));
      }
    });

    test('drift moves a layer with no camera at all', () {
      // A still sky reads as a painted backdrop rather than as weather.
      const scene = Parallax([Layer(image: 'cloud.png', depth: 0, drift: 3)]);
      expect(scene.at(0, 2).single, closeTo(6, 1e-9));
    });

    test('enough copies are asked for to cover the screen', () {
      // One short is a gap at the edge that appears once per wrap.
      const layer = Layer(image: 'a.png', size: 64);
      expect(Parallax.copiesFor(layer, 200), 6);
      expect(Parallax.copiesFor(const Layer(image: 'a.png'), 200), 1);
    });
  });

  group('a 2D camera', () {
    test('it follows without snapping', () {
      final view = View2(width: 10, height: 10);
      view.follow(Vector2(100, 0), 0.1);

      expect(view.at.x, greaterThan(0));
      expect(view.at.x, lessThan(100));
    });

    test('following is the same at any frame rate', () {
      // A camera that follows by a fixed fraction each frame follows twice as
      // fast at twice the frame rate.
      final slow = View2(width: 10, height: 10);
      final fast = View2(width: 10, height: 10);
      for (var i = 0; i < 30; i++) {
        slow.follow(Vector2(100, 0), 1 / 30);
      }
      for (var i = 0; i < 120; i++) {
        fast.follow(Vector2(100, 0), 1 / 120);
      }
      expect(fast.at.x, closeTo(slow.at.x, 1.5));
    });

    test('it stays inside its bounds', () {
      final view = View2(
        width: 10,
        height: 10,
        bounds: (minimum: Vector2(0, 0), maximum: Vector2(100, 100)),
      );
      view.jumpTo(Vector2(-50, 200));

      expect(view.at.x, closeTo(5, 1e-9));
      expect(view.at.y, closeTo(95, 1e-9));
    });

    test('a world narrower than the screen centres rather than inverting', () {
      // Clamping to a negative range would put the camera outside the world
      // it was being kept inside.
      final view = View2(
        width: 100,
        height: 100,
        bounds: (minimum: Vector2(0, 0), maximum: Vector2(20, 20)),
      );
      view.jumpTo(Vector2(0, 0));
      expect(view.at.x, closeTo(10, 1e-9));
    });
  });

  group('a tile map', () {
    String tiled({
      String orientation = 'orthogonal',
      String? encoding,
      String? compression,
      bool external = false,
    }) => jsonEncode({
      'orientation': orientation,
      'width': 3,
      'height': 2,
      'tilewidth': 16,
      'tileheight': 16,
      'layers': [
        {
          'type': 'tilelayer',
          'name': 'ground',
          'width': 3,
          'height': 2,
          'data': [1, 0, 2, 0, 3, 0],
          if (encoding != null) 'encoding': encoding,
          if (compression != null) 'compression': compression,
        },
        {'type': 'objectgroup', 'name': 'things'},
      ],
      'tilesets': [
        if (external)
          {'firstgid': 1, 'source': 'outside.tsx'}
        else ...[
          {
            'firstgid': 1,
            'name': 'grass',
            'image': 'grass.png',
            'tilewidth': 16,
            'tileheight': 16,
            'columns': 4,
            'tilecount': 8,
          },
          {
            'firstgid': 9,
            'name': 'stone',
            'image': 'stone.png',
            'tilewidth': 16,
            'tileheight': 16,
            'columns': 4,
            'tilecount': 8,
          },
        ],
      ],
    });

    test('it reads the layers and skips the ones it does not draw', () {
      final map = TileMap.read(tiled())!;
      expect(map.width, 3);
      expect(map.layers, hasLength(1));
      expect(map.layer('ground')!.at(0, 0), 1);
      expect(map.layer('ground')!.at(2, 0), 2);
      expect(map.layer('ground')!.at(1, 1), 3);
    });

    test('outside the map is empty rather than an error', () {
      // A map is walked by things that wander off the edge of it.
      final ground = TileMap.read(tiled())!.layer('ground')!;
      expect(ground.at(-1, 0), 0);
      expect(ground.at(99, 99), 0);
      expect(ground.isEmptyAt(1, 0), isTrue);
    });

    test('a tile is traced back to the set it came from', () {
      // Getting this backwards draws the right shape from the wrong sheet.
      final map = TileMap.read(tiled())!;
      expect(map.setFor(1)!.name, 'grass');
      expect(map.setFor(8)!.name, 'grass');
      expect(map.setFor(9)!.name, 'stone');
      expect(map.setFor(12)!.name, 'stone');
      expect(map.setFor(0), isNull);
    });

    test('a tile knows where it sits in its own image', () {
      final set = TileMap.read(tiled())!.tilesets.first;
      expect(set.rectOf(1), (x: 0, y: 0, width: 16, height: 16));
      expect(set.rectOf(5), (x: 0, y: 16, width: 16, height: 16));
    });

    test('a point on the map picks out a cell', () {
      final map = TileMap.read(tiled())!;
      expect(map.cellAt(0, 0), (0, 0));
      expect(map.cellAt(31.5, 17), (1, 1));
      expect(map.cellAt(-1, -1), (-1, -1));
    });

    test('solidity can be asked of the whole map or of named layers', () {
      final map = TileMap.read(tiled())!;
      expect(map.isSolidAt(0, 0), isTrue);
      expect(map.isSolidAt(1, 0), isFalse);
      expect(map.isSolidAt(0, 0, only: {'nothing'}), isFalse);
    });

    test('what it cannot read comes back null rather than half a map', () {
      // A map that silently lost a floor is worse than one that did not load.
      expect(TileMap.read(tiled(orientation: 'isometric')), isNull);
      expect(TileMap.read(tiled(encoding: 'base64')), isNull);
      expect(TileMap.read(tiled(compression: 'zlib')), isNull);
      expect(TileMap.read(tiled(external: true)), isNull);
      expect(TileMap.read('not json'), isNull);
    });

    test('csv encoding is read, because that is what it already is', () {
      expect(TileMap.read(tiled(encoding: 'csv')), isNotNull);
    });
  });
}
