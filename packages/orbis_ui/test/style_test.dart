import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_ui/orbis_ui.dart';

void main() {
  const utilities = UiUtilities();
  const css = UiCss();

  group('a class list', () {
    test('spacing is counted in steps, not pixels', () {
      // Four to the step, so p-4 is sixteen: the arithmetic every utility
      // vocabulary uses, and the reason the names look right to somebody who
      // has never seen this engine.
      expect(utilities.parse('p-4').paddingTop, 16);
      expect(utilities.parse('px-2').paddingLeft, 8);
      expect(utilities.parse('px-2').paddingTop, isNull);
      expect(utilities.parse('mt-1').marginTop, 4);
    });

    test('a measurement in brackets is in pixels', () {
      // The one number in a design that does not sit on the grid.
      expect(utilities.parse('p-[13]').paddingTop, 13);
      expect(utilities.parse('w-[220]').width, 220);
    });

    test('layout reads the way it is written', () {
      final style = utilities.parse('row items-center justify-between gap-3');
      expect(style.direction, 'row');
      expect(style.crossAxis, 'center');
      expect(style.mainAxis, 'between');
      expect(style.gap, 12);
    });

    test('colours come from the palette, or are written out', () {
      expect(utilities.parse('bg-slate-800').background, isNotNull);
      expect(utilities.parse('text-ember-500').colour, const Color(0xFFC25E22));
      expect(utilities.parse('bg-[#123456]').background,
          const Color(0xFF123456));
      expect(utilities.parse('bg-nonesuch-500').background, isNull);
    });

    test('text sizes and weights are named', () {
      expect(utilities.parse('text-lg').fontSize, 16);
      expect(utilities.parse('font-semibold').fontWeight, 600);
      expect(utilities.parse('text-center').textAlign, 'center');
    });

    test('later classes win over earlier ones', () {
      expect(utilities.parse('p-2 p-8').paddingTop, 32);
      // And a specific side wins over the shorthand it follows.
      expect(utilities.parse('p-2 pt-8').paddingTop, 32);
      expect(utilities.parse('p-2 pt-8').paddingBottom, 8);
    });

    test('a word nobody knows is ignored rather than fatal', () {
      // A class list is written by hand under time pressure. An interface
      // that refuses to draw because one word was misspelt is worse than one
      // that draws without the rounded corner.
      final style = utilities.parse('p-4 rounded-lg wobbly bg-slate-800');
      expect(style.paddingTop, 16);
      expect(style.background, isNotNull);
      expect(utilities.unknownIn('p-4 wobbly nonsense-9'),
          ['wobbly', 'nonsense-9']);
    });

    test('opacity is a percentage, because that is how it is written', () {
      expect(utilities.parse('opacity-50').opacity, 0.5);
    });
  });

  group('a block of CSS', () {
    test('the shorthands expand the way CSS expands them', () {
      final one = css.parse('padding: 8px');
      expect([one.paddingTop, one.paddingRight], [8, 8]);

      final two = css.parse('padding: 8px 12px');
      expect([two.paddingTop, two.paddingRight, two.paddingLeft], [8, 12, 12]);

      final four = css.parse('padding: 1px 2px 3px 4px');
      expect(
        [four.paddingTop, four.paddingRight, four.paddingBottom, four.paddingLeft],
        [1, 2, 3, 4],
      );
    });

    test('colours arrive in any of the notations', () {
      expect(css.parse('color: #fff').colour, const Color(0xFFFFFFFF));
      expect(css.parse('color: #1a2b3c').colour, const Color(0xFF1A2B3C));
      // CSS puts the alpha last; Dart puts it first.
      expect(css.parse('color: #11223380').colour, const Color(0x80112233));
      expect(css.parse('color: rgb(255, 0, 0)').colour, const Color(0xFFFF0000));
      expect(css.parse('color: rgba(0, 0, 0, 0.5)').colour,
          const Color(0x80000000));
      expect(css.parse('color: slate-500').colour, isNotNull);
    });

    test('flex properties mean what they mean in flexbox', () {
      final style = css.parse(
        'display: flex; align-items: center; justify-content: space-between;'
        ' gap: 12px; flex: 1',
      );
      expect(style.direction, 'row');
      expect(style.crossAxis, 'center');
      expect(style.mainAxis, 'between');
      expect(style.gap, 12);
      expect(style.grow, 1);
    });

    test('a border is read out of the shorthand', () {
      final style = css.parse('border: 2px solid #334455');
      expect(style.borderWidth, 2);
      expect(style.borderColour, const Color(0xFF334455));
    });

    test('a selector and braces around it are tolerated', () {
      // What somebody pastes out of a stylesheet.
      final style = css.parse('.card { padding: 6px; border-radius: 4px }');
      expect(style.paddingTop, 6);
      expect(style.radius, 4);
    });

    test('what it does not understand, it says', () {
      expect(css.unknownIn('float: left; padding: 4px'), ['float']);
    });
  });

  group('the two notations together', () {
    test('CSS is laid over the classes rather than replacing them', () {
      final builder = UiBuilder();
      final style = builder.styleOf(const UiNode(
        type: 'box',
        classes: 'p-4 bg-slate-800 rounded-lg',
        css: 'padding: 24px',
      ));

      // The one thing the CSS said wins; everything else the classes said
      // survives.
      expect(style.paddingTop, 24);
      expect(style.background, isNotNull);
      expect(style.radius, 10);
    });
  });
}
