import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_ui/orbis_ui.dart';

void main() {
  const utilities = UiUtilities();
  const breakpoints = UiBreakpoints();

  group('breakpoints', () {
    test('a width is under every one it has not reached', () {
      expect(breakpoints.activeAt(320), isEmpty);
      expect(breakpoints.activeAt(700), ['sm']);
      expect(breakpoints.activeAt(1000), ['sm', 'md']);
      expect(breakpoints.activeAt(4000), ['sm', 'md', 'lg', 'xl']);
    });

    test('a width has a name somebody can be shown', () {
      expect(breakpoints.labelAt(320), 'base');
      expect(breakpoints.labelAt(1000), 'md');
      expect(breakpoints.labelAt(1920), 'xl');
    });
  });

  group('a responsive class list', () {
    test('a prefixed class waits for the width it names', () {
      expect(utilities.parse('text-base md:text-xl', width: 400).fontSize, 14);
      expect(utilities.parse('text-base md:text-xl', width: 1000).fontSize, 19);
    });

    test('without a width, only the unprefixed classes apply', () {
      // What a caller that does not know how wide it is should get: the
      // layout somebody wrote for the narrowest case, not a guess.
      expect(utilities.parse('text-base md:text-xl').fontSize, 14);
    });

    test('the widest that applies wins, whatever order it was typed in', () {
      // The order of the words in a class list is not a cascade. Both of
      // these are one design, and both have to be the same one.
      const forwards = 'md:text-xl lg:text-3xl';
      const backwards = 'lg:text-3xl md:text-xl';
      expect(utilities.parse(forwards, width: 1400).fontSize, 30);
      expect(utilities.parse(backwards, width: 1400).fontSize, 30);
      expect(utilities.parse(backwards, width: 1000).fontSize, 19);
    });

    test('a layout can change direction, not only size', () {
      // The reason to have breakpoints at all: a row of cards on a laptop is
      // a column of them on a phone.
      expect(utilities.parse('col md:row', width: 400).direction, 'column');
      expect(utilities.parse('col md:row', width: 1200).direction, 'row');
    });

    test('a prefix that is not a breakpoint is not a class', () {
      // Ignored rather than applied at every width: `hover:` is a real thing
      // to want and silently making it always-on would be worse than nothing.
      expect(utilities.parse('hover:text-xl', width: 4000).fontSize, isNull);
      expect(utilities.unknownIn('hover:text-xl'), ['hover:text-xl']);
      expect(utilities.unknownIn('md:text-xl'), isEmpty);
      expect(utilities.unknownIn('md:nonsense'), ['md:nonsense']);
    });
  });

  group('the fluid scale', () {
    test('a bigger screen shows a bigger interface, up to a point', () {
      const canvas = UiCanvas(fit: CanvasFit.responsive);
      expect(canvas.fluidScale(1920), 1);
      expect(canvas.fluidScale(2880), 1.5);
      // Clamped: a television is not four times the type size.
      expect(canvas.fluidScale(7680), 1.5);
      expect(canvas.fluidScale(390), 0.8);
    });

    test('a canvas that is already scaled is not scaled twice', () {
      // Every other fit magnifies the whole picture. Growing the text inside
      // it as well would compound.
      const canvas = UiCanvas();
      expect(canvas.fit, CanvasFit.contain);
      expect(canvas.fluidScale(3840), 1);
    });

    test('a scaled theme moves every measurement together', () {
      final theme = const UiTheme().scaled(2);
      expect(theme.step, 8);
      expect(theme.text['base'], 28);
      expect(UiUtilities(theme: theme).parse('p-4').paddingTop, 32);
      // The escape hatch stays an escape hatch.
      expect(UiUtilities(theme: theme).parse('p-[13]').paddingTop, 13);
    });

    test('scaling by one is the same theme', () {
      const theme = UiTheme();
      expect(identical(theme.scaled(1), theme), isTrue);
      expect(identical(theme.scaled(0), theme), isTrue);
    });
  });

  group('the column grid', () {
    test('columns and gutters divide the space inside the safe area', () {
      const canvas = UiCanvas(
        width: 1000,
        columns: 4,
        gutter: 20,
        safeArea: 0.05,
      );
      final columns = canvas.columnsAcross(1000);

      expect(columns, hasLength(4));
      // 900 usable, three 20px gutters, four 210px columns.
      expect(columns.first.left, 50);
      expect(columns.first.right, 260);
      expect(columns.last.right, closeTo(950, 0.001));
    });

    test('numbers that do not leave room draw nothing', () {
      // Twelve columns and a wide gutter on a phone. Better to draw no grid
      // than columns of negative width.
      const canvas = UiCanvas(columns: 12, gutter: 80);
      expect(canvas.columnsAcross(390), isEmpty);
    });

    test('a position near a column edge snaps to it', () {
      const canvas = UiCanvas(
        width: 1000,
        columns: 4,
        gutter: 20,
        safeArea: 0.05,
      );
      expect(canvas.snapAcross(53, 1000), 50);
      expect(canvas.snapAcross(257, 1000), 260);
      // Something put deliberately between two columns stays there.
      expect(canvas.snapAcross(150, 1000), isNull);
    });
  });

  group('a document', () {
    test('a new one is responsive from the first frame', () {
      expect(UiDocument.blank('Menu').canvas.fit, CanvasFit.responsive);
    });

    test('the grid and the scale survive a round trip', () {
      const canvas = UiCanvas(
        fit: CanvasFit.responsive,
        columns: 6,
        gutter: 32,
        minScale: 0.5,
        maxScale: 2,
      );
      final read = UiCanvas.fromJson(canvas.toJson());

      expect(read.fit, CanvasFit.responsive);
      expect(read.columns, 6);
      expect(read.gutter, 32);
      expect(read.minScale, 0.5);
      expect(read.maxScale, 2);
    });

    test('a file written before any of this reads with the old behaviour', () {
      final read = UiCanvas.fromJson({'width': 1280, 'height': 720});
      expect(read.fit, CanvasFit.contain);
      expect(read.columns, 12);
      expect(read.fluidScale(3840), 1);
    });
  });

  group('a surface', () {
    const card = UiNode(
      type: 'box',
      classes: 'col md:row gap-2',
      children: [
        UiNode(type: 'text', classes: 'text-base md:text-2xl', text: 'Play'),
        UiNode(type: 'text', text: 'Continue'),
      ],
    );

    /// Room for the widest case, so the test surface is never the thing
    /// deciding the layout.
    Future<void> roomFor(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    Future<double> sizeOfPlay(WidgetTester tester, double width) async {
      await roomFor(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: const UiSurface(
                  description: card,
                  canvas: UiCanvas(fit: CanvasFit.responsive),
                ),
              ),
            ),
          ),
        ),
      );
      return tester.widget<Text>(find.text('Play')).style!.fontSize!;
    }

    testWidgets('measures itself and lays out for what it found', (
      tester,
    ) async {
      // The whole point: nobody wired a width in. The surface asked.
      //
      // On a phone the base size, shrunk by the fluid floor. On a laptop the
      // `md:` size, still shrunk — 1200 is well under the 1920 it was drawn
      // against — and half again as large for it.
      expect(await sizeOfPlay(tester, 390), 14 * 0.8);
      expect(await sizeOfPlay(tester, 1200), 23 * 0.8);
    });

    testWidgets('the direction changes with the width', (tester) async {
      await roomFor(tester);
      Future<void> show(double width) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: const UiSurface(description: card),
              ),
            ),
          ),
        ),
      );

      await show(390);
      expect(find.byType(Column), findsWidgets);

      await show(1200);
      expect(find.byType(Row), findsWidgets);
    });

    testWidgets('a told width beats a measured one', (tester) async {
      // The editor showing a phone inside a panel: the width that decides the
      // layout is the phone's, not the panel it is drawn in.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: UiSurface(description: card, width: 390)),
        ),
      );
      expect(find.byType(Row), findsNothing);
    });
  });
}
