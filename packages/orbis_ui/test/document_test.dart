import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_ui/orbis_ui.dart';

void main() {
  const tree = UiNode(
    type: 'column',
    classes: 'p-4',
    children: [
      UiNode(type: 'text', text: 'Title'),
      UiNode(
        type: 'row',
        children: [
          UiNode(type: 'button', text: 'One'),
          UiNode(type: 'button', text: 'Two'),
        ],
      ),
    ],
  );

  group('finding a node', () {
    test('an empty path is the root', () {
      expect(tree.at(const [])!.type, 'column');
    });

    test('a path walks child indices', () {
      expect(tree.at(const [1, 0])!.text, 'One');
    });

    test('a path that leads nowhere is null rather than a crash', () {
      expect(tree.at(const [9]), isNull);
      expect(tree.at(const [0, 0]), isNull);
      expect(tree.at(const [-1]), isNull);
    });
  });

  group('editing', () {
    test('replacing leaves the original alone', () {
      final changed = tree.replaceAt(
        const [1, 1],
        const UiNode(type: 'button', text: 'Changed'),
      );

      expect(changed.at(const [1, 1])!.text, 'Changed');
      expect(tree.at(const [1, 1])!.text, 'Two');
    });

    test('siblings are shared rather than copied', () {
      final changed = tree.replaceAt(
        const [1, 1],
        const UiNode(type: 'button', text: 'Changed'),
      );

      // An edit deep in a large interface copies the spine and nothing else.
      expect(identical(changed.children.first, tree.children.first), isTrue);
      expect(
        identical(changed.at(const [1, 0]), tree.at(const [1, 0])),
        isTrue,
      );
    });

    test('replacing the root replaces everything', () {
      final changed =
          tree.replaceAt(const [], const UiNode(type: 'text', text: 'Only'));
      expect(changed.type, 'text');
    });

    test('inserting puts it where it was asked for', () {
      final changed = tree.insertAt(
        const [1],
        1,
        const UiNode(type: 'button', text: 'Middle'),
      );

      expect([for (final c in changed.at(const [1])!.children) c.text],
          ['One', 'Middle', 'Two']);
    });

    test('an index past the end appends rather than failing', () {
      final changed = tree.insertAt(
        const [1],
        99,
        const UiNode(type: 'button', text: 'Last'),
      );
      expect(changed.at(const [1])!.children.last.text, 'Last');
    });

    test('removing takes the subtree with it', () {
      final changed = tree.removeAt(const [1]);

      expect(changed.children, hasLength(1));
      expect(changed.children.single.text, 'Title');
    });

    test('the root cannot be removed', () {
      expect(tree.removeAt(const []).type, 'column');
    });

    test('a path that leads nowhere changes nothing', () {
      expect(tree.removeAt(const [9]).children, hasLength(2));
      expect(
        tree.insertAt(const [9], 0, const UiNode(type: 'box')).children,
        hasLength(2),
      );
    });

    test('moving reorders among siblings', () {
      final changed = tree.moveAt(const [1, 1], 0);
      expect([for (final c in changed.at(const [1])!.children) c.text],
          ['Two', 'One']);
    });
  });

  group('walking', () {
    test('gives every node with the path to it', () {
      final seen = tree.walk().toList();

      expect(seen, hasLength(5));
      expect(seen.first.path, isEmpty);
      expect(seen.last.path, [1, 1]);
      // Deepest last, so the last match under a point is what is drawn on top.
      expect(seen[3].node.text, 'One');
    });

    test('every path it gives leads back to its node', () {
      for (final found in tree.walk()) {
        expect(identical(tree.at(found.path), found.node), isTrue);
      }
    });
  });

  group('the canvas', () {
    test('fitting inside never cuts anything off', () {
      const canvas = UiCanvas(width: 1920, height: 1080);

      // A screen that is too tall: width decides.
      expect(canvas.scaleFor(960, 1080), closeTo(0.5, 1e-9));
      // A screen that is too wide: height decides.
      expect(canvas.scaleFor(1920, 540), closeTo(0.5, 1e-9));
    });

    test('matching one dimension lets the other overflow', () {
      const wide = UiCanvas(width: 1920, height: 1080, fit: CanvasFit.width);
      expect(wide.scaleFor(3840, 540), closeTo(2, 1e-9));

      const tall = UiCanvas(width: 1920, height: 1080, fit: CanvasFit.height);
      expect(tall.scaleFor(3840, 540), closeTo(0.5, 1e-9));
    });

    test('actual size does not scale', () {
      const canvas = UiCanvas(fit: CanvasFit.none);
      expect(canvas.scaleFor(100, 100), 1);
    });

    test('a canvas with no size does not divide by zero', () {
      const canvas = UiCanvas(width: 0, height: 0);
      expect(canvas.scaleFor(100, 100), 1);
      expect(canvas.aspect, 1);
    });
  });

  group('the file', () {
    test('survives a round trip', () {
      final document = UiDocument(
        name: 'Main menu',
        canvas: const UiCanvas(width: 1280, height: 720, fit: CanvasFit.width),
        root: tree,
      );

      final back = UiDocument.read(document.toText())!;
      expect(back.name, 'Main menu');
      expect(back.canvas.width, 1280);
      expect(back.canvas.fit, CanvasFit.width);
      expect(back.root.at(const [1, 1])!.text, 'Two');
    });

    test('is not read from something that is not one', () {
      expect(UiDocument.read('nonsense'), isNull);
      expect(UiDocument.read('{"kind":"orbis.data"}'), isNull);
    });

    test('a fit it does not know falls back to fitting inside', () {
      expect(UiCanvas.fromJson({'fit': 'sideways'}).fit, CanvasFit.contain);
    });

    test('a safe area outside the possible is clamped', () {
      expect(UiCanvas.fromJson({'safeArea': 9.0}).safeArea, 0.45);
      expect(UiCanvas.fromJson({'safeArea': -1.0}).safeArea, 0);
    });

    test('a new one has something on it', () {
      final made = UiDocument.blank('menu');
      expect(made.root.children, isNotEmpty);
      expect(made.name, 'menu');
    });
  });

  group('the design chrome', () {
    testWidgets('a decorator sees every element, with its path',
        (tester) async {
      final seen = <String, List<int>>{};

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UiSurface(
            description: tree,
            decorate: (node, path, built) {
              seen['${node.type}${node.text ?? ''}'] = path;
              return built;
            },
          ),
        ),
      ));

      expect(seen['column'], isEmpty);
      expect(seen['buttonTwo'], [1, 1]);
      expect(seen, hasLength(5));
    });

    testWidgets('without one, nothing is wrapped', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: UiSurface(description: tree)),
      ));

      // The point of the hook being null in a game: the chrome is not stripped
      // out at build time, it was never built.
      expect(find.text('One'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
