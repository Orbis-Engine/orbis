import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_ui/orbis_ui.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    UiNode description, {
    UiEvent? onEvent,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UiSurface(description: description, onEvent: onEvent),
        ),
      ),
    );
  }

  group('a description becomes widgets', () {
    testWidgets('text arrives as text', (tester) async {
      await show(tester, const UiNode(type: 'text', text: 'Health'));
      expect(find.text('Health'), findsOneWidget);
    });

    testWidgets('a row is a Row and a column is a Column', (tester) async {
      await show(
        tester,
        const UiNode(
          type: 'row',
          children: [
            UiNode(type: 'text', text: 'a'),
            UiNode(type: 'text', text: 'b'),
          ],
        ),
      );
      expect(find.byType(Row), findsOneWidget);

      await show(
        tester,
        const UiNode(
          type: 'column',
          children: [
            UiNode(type: 'text', text: 'a'),
            UiNode(type: 'text', text: 'b'),
          ],
        ),
      );
      expect(find.byType(Column), findsWidgets);
    });

    testWidgets('a gap goes between children, not around them', (tester) async {
      await show(
        tester,
        const UiNode(
          type: 'row',
          classes: 'gap-4',
          children: [
            UiNode(type: 'text', text: 'a'),
            UiNode(type: 'text', text: 'b'),
            UiNode(type: 'text', text: 'c'),
          ],
        ),
      );

      final row = tester.widget<Row>(find.byType(Row));
      // Three children and two gaps: the first and last stay flush with the
      // edges, which is what a gap means and what margins would get wrong.
      expect(row.children.length, 5);
    });

    testWidgets('a class list reaches the widgets it describes', (
      tester,
    ) async {
      await show(
        tester,
        const UiNode(
          type: 'box',
          classes: 'p-4 bg-slate-800 rounded-lg',
          children: [UiNode(type: 'text', text: 'inside')],
        ),
      );

      final padding = tester.widget<Padding>(find.byType(Padding).first);
      expect(padding.padding, const EdgeInsets.all(16));

      final decorated = tester.widget<DecoratedBox>(
        find.byType(DecoratedBox).first,
      );
      final decoration = decorated.decoration as BoxDecoration;
      expect(decoration.color, isNotNull);
      expect(decoration.borderRadius, BorderRadius.circular(10));
    });

    testWidgets('lining up on the baseline does not need to be told twice', (
      tester,
    ) async {
      // Flutter asserts if a baseline alignment arrives without a baseline,
      // and a script asking for one should not be the thing that takes the
      // frame down.
      await show(
        tester,
        const UiNode(
          type: 'row',
          classes: 'items-baseline',
          children: [
            UiNode(type: 'text', text: 'Score'),
            UiNode(type: 'text', classes: 'text-2xl', text: '1840'),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing in a description can throw a frame away', (
      tester,
    ) async {
      // Half-written trees are the normal case: script is reloaded on save,
      // so an element with no type and a child that is not a map arrive
      // regularly while somebody is typing.
      final node = UiNode.decode('{"type": "row", "children": [null, 3, {}]}');
      await show(tester, node);
      expect(tester.takeException(), isNull);
    });
  });

  group('events', () {
    testWidgets('a button says which handler was pressed', (tester) async {
      final fired = <String>[];
      await show(
        tester,
        const UiNode(
          type: 'button',
          text: 'Start',
          props: {'onPressed': 'startGame'},
        ),
        onEvent: (handler, payload) => fired.add(handler),
      );

      await tester.tap(find.text('Start'));
      expect(fired, ['startGame']);
    });

    testWidgets('anything can be tapped, not only buttons', (tester) async {
      final fired = <String>[];
      await show(
        tester,
        const UiNode(
          type: 'box',
          classes: 'p-4',
          props: {'onTap': 'closePanel'},
          children: [UiNode(type: 'text', text: 'x')],
        ),
        onEvent: (handler, payload) => fired.add(handler),
      );

      await tester.tap(find.text('x'));
      expect(fired, ['closePanel']);
    });

    testWidgets('a handler nobody supplied is not a press', (tester) async {
      final fired = <String>[];
      await show(
        tester,
        const UiNode(type: 'button', text: 'Quiet'),
        onEvent: (handler, payload) => fired.add(handler),
      );

      await tester.tap(find.text('Quiet'));
      expect(fired, isEmpty);
    });
  });

  group('what arrives as JSON', () {
    test('reads the shape script sends', () {
      final node = UiNode.decode('''
{
  "type": "column",
  "class": "p-4 gap-2",
  "children": [
    {"type": "text", "text": "Score", "class": "text-sm text-slate-400"},
    {"type": "button", "text": "Again", "props": {"onPressed": "restart"}}
  ]
}
''');

      expect(node.type, 'column');
      expect(node.classes, 'p-4 gap-2');
      expect(node.children.length, 2);
      expect(node.children.last.handlerFor('onPressed'), 'restart');
    });

    test('a plain string is text', () {
      expect(UiNode.decode('"just words"').type, 'text');
      expect(UiNode.decode('"just words"').text, 'just words');
    });

    test(
      'something that is not a description says so rather than throwing',
      () {
        final node = UiNode.decode('{oh dear');
        expect(node.type, 'text');
        expect(node.text, contains('could not be read'));
      },
    );

    test('a description survives a round trip', () {
      const node = UiNode(
        type: 'box',
        classes: 'p-2',
        css: 'color: #fff',
        children: [UiNode(type: 'text', text: 'hello')],
      );
      final back = UiNode.fromJson(node.toJson());

      expect(back.type, node.type);
      expect(back.classes, node.classes);
      expect(back.css, node.css);
      expect(back.children.single.text, 'hello');
    });
  });
}
