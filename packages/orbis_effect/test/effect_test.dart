import 'dart:math' as math;

import 'package:orbis_effect/orbis_effect.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Vector3 v(double x, [double y = 0, double z = 0]) => Vector3(x, y, z);

  group('curves', () {
    test('every one starts at nothing and ends at everything', () {
      final curves = <String, Ease>{
        'linear': Eases.linear,
        'inQuad': Eases.inQuad,
        'outQuad': Eases.outQuad,
        'inCubic': Eases.inCubic,
        'outCubic': Eases.outCubic,
        'inOutQuad': Eases.inOutQuad,
        'inOutCubic': Eases.inOutCubic,
        'outBack': Eases.outBack,
        'outElastic': Eases.outElastic,
        'outBounce': Eases.outBounce,
      };
      curves.forEach((name, ease) {
        expect(ease(0), closeTo(0, 1e-6), reason: name);
        expect(ease(1), closeTo(1, 1e-6), reason: name);
      });
    });

    test('eases in slower than out, and out slower than in', () {
      // The two are each other's mirror, which is the whole distinction.
      expect(Eases.inQuad(0.25), lessThan(0.25));
      expect(Eases.outQuad(0.25), greaterThan(0.25));
    });

    test('back overshoots and comes home', () {
      final most = [
        for (var i = 0; i <= 100; i++) Eases.outBack(i / 100),
      ].reduce(math.max);
      expect(most, greaterThan(1));
      expect(Eases.outBack(1), closeTo(1, 1e-9));
    });

    test('there and back ends where it began', () {
      final curve = Eases.thereAndBack(Eases.linear);
      expect(curve(0), closeTo(0, 1e-9));
      expect(curve(0.5), closeTo(1, 1e-9));
      expect(curve(1), closeTo(0, 1e-9));
    });

    test('reversed runs the other way', () {
      final curve = Eases.reversed(Eases.inQuad);
      expect(curve(0), closeTo(0, 1e-9));
      expect(curve(1), closeTo(1, 1e-9));
      expect(curve(0.25), greaterThan(0.25));
    });
  });

  group('one effect', () {
    test('a move is nothing at the start and everything at the end', () {
      final move = MoveBy(Vector3.zero(), 1);
      expect(move.at(0).move.length, 0);

      final along = MoveBy(v(10), 2, ease: Eases.linear);
      expect(along.at(0).move.x, closeTo(0, 1e-9));
      expect(along.at(1).move.x, closeTo(5, 1e-9));
      expect(along.at(2).move.x, closeTo(10, 1e-9));
    });

    test('it holds its end rather than snapping back', () {
      // A sequence asks its earlier members what they finished as while a
      // later one runs; an effect that reset would undo them.
      final along = MoveBy(v(10), 2, ease: Eases.linear);
      expect(along.at(50).move.x, closeTo(10, 1e-9));
    });

    test('asking about the middle does not need the beginning run', () {
      // The whole reason for sampling rather than stepping.
      final along = MoveBy(v(10), 2, ease: Eases.linear);
      expect(along.at(1).move.x, closeTo(5, 1e-9));
      expect(along.at(1).move.x, along.at(1).move.x);
    });

    test('a grow goes from one towards the factor', () {
      // Halfway through is halfway there, not half the size.
      final grow = GrowTo(v(3, 3, 3), 2, ease: Eases.linear);
      expect(grow.at(0).grow.x, closeTo(1, 1e-9));
      expect(grow.at(1).grow.x, closeTo(2, 1e-9));
      expect(grow.at(2).grow.x, closeTo(3, 1e-9));
    });

    test('a fade goes from one towards the opacity', () {
      const fade = FadeTo(0, 2);
      expect(fade.at(0).fade, closeTo(1, 1e-9));
      expect(fade.at(1).fade, closeTo(0.5, 1e-9));
      expect(fade.at(2).fade, closeTo(0, 1e-9));
    });

    test('a turn turns', () {
      // Tested through the matrix, which is the path that actually ships.
      // vector_math's `Quaternion.rotated` disagrees with composing the same
      // quaternion into a Matrix4 — it returns +Z where the matrix returns
      // -Z — so a test written against it would be asserting the opposite of
      // what the renderer draws.
      final turn = TurnBy(math.pi / 2, duration: 2, ease: Eases.linear);
      final matrix = applied(Matrix4.identity(), turn.at(2));
      final facing = matrix.transform3(v(1));

      expect(facing.x, closeTo(0, 1e-6));
      expect(facing.z, closeTo(-1, 1e-6));
    });

    test('an effect of no duration is finished immediately', () {
      final instant = MoveBy(v(5), 0);
      expect(instant.at(0).move.x, closeTo(5, 1e-9));
      expect(instant.doneBy(0), isTrue);
    });
  });

  group('changes together', () {
    test('offsets add and scales multiply', () {
      final a = Change(move: v(1, 2), grow: v(2, 2, 2), fade: 0.5);
      final b = Change(move: v(3), grow: v(3, 3, 3), fade: 0.5);
      final both = a.and(b);

      expect(both.move.x, closeTo(4, 1e-9));
      expect(both.move.y, closeTo(2, 1e-9));
      expect(both.grow.x, closeTo(6, 1e-9));
      expect(both.fade, closeTo(0.25, 1e-9));
    });

    test('nothing added to something is that something', () {
      final one = Change(move: v(1, 2, 3), fade: 0.4);
      final same = Change.none.and(one);
      expect(same.move, one.move);
      expect(same.fade, closeTo(one.fade, 1e-9));
    });

    test('nothing is recognisably nothing', () {
      expect(Change.none.isNothing, isTrue);
      expect(Change(move: v(1)).isNothing, isFalse);
    });
  });

  group('composing', () {
    test('a sequence runs its steps in order and keeps what they did', () {
      // Without holding the earlier ends, a move followed by a turn snaps
      // back to the start of the move the moment the turn begins.
      final story = Then([
        MoveBy(v(10), 1, ease: Eases.linear),
        MoveBy(v(0, 10), 1, ease: Eases.linear),
      ]);

      expect(story.duration, closeTo(2, 1e-9));
      expect(story.at(0.5).move.x, closeTo(5, 1e-9));
      expect(story.at(0.5).move.y, closeTo(0, 1e-9));
      expect(story.at(1.5).move.x, closeTo(10, 1e-9));
      expect(story.at(1.5).move.y, closeTo(5, 1e-9));
      expect(story.at(9).move.y, closeTo(10, 1e-9));
    });

    test('two at once are both applied', () {
      final both = Both([
        MoveBy(v(10), 2, ease: Eases.linear),
        const FadeTo(0, 2),
      ]);
      expect(both.duration, closeTo(2, 1e-9));
      expect(both.at(1).move.x, closeTo(5, 1e-9));
      expect(both.at(1).fade, closeTo(0.5, 1e-9));
    });

    test('a pause is part of the length and changes nothing', () {
      final story = Then([const Wait(1), MoveBy(v(10), 1, ease: Eases.linear)]);
      expect(story.duration, closeTo(2, 1e-9));
      expect(story.at(0.5).move.x, closeTo(0, 1e-9));
      expect(story.at(1.5).move.x, closeTo(5, 1e-9));
    });

    test('a delay holds everything off', () {
      final late = After(2, MoveBy(v(10), 1, ease: Eases.linear));
      expect(late.duration, closeTo(3, 1e-9));
      expect(late.at(1).move.x, closeTo(0, 1e-9));
      expect(late.at(2.5).move.x, closeTo(5, 1e-9));
    });

    test('a repeat is as cheap to ask about late as early', () {
      final again = Again(MoveBy(v(10), 1, ease: Eases.linear), times: 3);
      expect(again.duration, closeTo(3, 1e-9));
      expect(again.at(0.5).move.x, closeTo(5, 1e-9));
      // The thousandth run of a forever effect costs what the first does.
      final forever = Again(MoveBy(v(10), 1, ease: Eases.linear));
      expect(forever.duration, double.infinity);
      expect(forever.at(1000.5).move.x, closeTo(5, 1e-9));
    });

    test('out and back ends where it started', () {
      final pulse = OutAndBack(GrowTo(v(2, 2, 2), 1, ease: Eases.linear));
      expect(pulse.duration, closeTo(2, 1e-9));
      expect(pulse.at(1).grow.x, closeTo(2, 1e-9));
      expect(pulse.at(2).grow.x, closeTo(1, 1e-9));
    });

    test('a sequence of sequences is still a sequence', () {
      final nested = Then([
        Then([MoveBy(v(1), 1, ease: Eases.linear)]),
        Both([MoveBy(v(0, 1), 1, ease: Eases.linear), const FadeTo(0.5, 1)]),
      ]);
      expect(nested.duration, closeTo(2, 1e-9));
      expect(nested.at(2).move.x, closeTo(1, 1e-9));
      expect(nested.at(2).move.y, closeTo(1, 1e-9));
      expect(nested.at(2).fade, closeTo(0.5, 1e-9));
    });
  });

  group('a shake', () {
    test('the same shake looks the same twice', () {
      const shake = Shake(0.5, 1, seed: 4);
      expect(shake.at(0.3).move.x, shake.at(0.3).move.x);
    });

    test('two shakes with different seeds differ', () {
      expect(
        const Shake(0.5, 1, seed: 1).at(0.3).move.x,
        isNot(const Shake(0.5, 1, seed: 2).at(0.3).move.x),
      );
    });

    test('it fades out rather than stopping', () {
      const shake = Shake(1, 1, seed: 9);
      final early = [
        for (var i = 0; i < 20; i++) shake.at(i * 0.005).move.length,
      ].reduce(math.max);
      final late = [
        for (var i = 0; i < 20; i++) shake.at(0.9 + i * 0.005).move.length,
      ].reduce(math.max);
      expect(late, lessThan(early));
      expect(shake.at(1).move.length, closeTo(0, 1e-9));
    });

    test('it stays inside its strength', () {
      const shake = Shake(0.5, 2, seed: 3);
      for (var i = 0; i < 200; i++) {
        expect(shake.at(i * 0.01).move.x.abs(), lessThanOrEqualTo(0.5 + 1e-9));
      }
    });
  });

  group('playing them', () {
    test('it adds up everything running', () {
      final playing = Playing()
        ..start(MoveBy(v(10), 2, ease: Eases.linear))
        ..start(const FadeTo(0, 2));

      playing.advance(1);
      expect(playing.change.move.x, closeTo(5, 1e-9));
      expect(playing.change.fade, closeTo(0.5, 1e-9));
    });

    test('what has finished keeps contributing until it is baked', () {
      // The trap this design has to avoid: a change is a difference, so an
      // effect dropped the moment it finishes takes its offset with it and
      // the thing snaps back to where it started.
      final playing = Playing()..start(MoveBy(v(10), 1, ease: Eases.linear));
      playing.advance(2);

      expect(playing.length, 0);
      expect(playing.change.move.x, closeTo(10, 1e-9));

      // Once a host has folded it in, it stops being counted twice.
      expect(playing.bake().move.x, closeTo(10, 1e-9));
      expect(playing.change.move.x, closeTo(0, 1e-9));
    });

    test('it says what has just finished', () {
      // The moment a host wants to do the next thing; polling for it is
      // worse.
      final playing = Playing()..start(MoveBy(v(1), 1));
      expect(playing.advance(0.5), isEmpty);
      expect(playing.advance(0.6), hasLength(1));
      expect(playing.length, 0);
    });

    test('an effect started later runs on its own clock', () {
      final playing = Playing()..start(MoveBy(v(10), 2, ease: Eases.linear));
      playing.advance(1);
      playing.start(MoveBy(v(0, 10), 2, ease: Eases.linear));
      playing.advance(1);

      expect(playing.change.move.x, closeTo(10, 1e-9));
      expect(playing.change.move.y, closeTo(5, 1e-9));
    });

    test('nothing running is no change', () {
      expect(Playing().change.isNothing, isTrue);
    });
  });

  group('applying a change', () {
    test('a move moves and a grow grows', () {
      final start = Matrix4.identity()..setTranslation(v(1, 2, 3));
      final moved = applied(start, Change(move: v(10), grow: v(2, 2, 2)));

      expect(moved.getTranslation().x, closeTo(11, 1e-9));
      expect(moved.getColumn(0).length, closeTo(2, 1e-9));
    });

    test('nothing applied leaves it where it was', () {
      final start = Matrix4.identity()..setTranslation(v(1, 2, 3));
      final same = applied(start, Change.none);
      expect(same.getTranslation().x, closeTo(1, 1e-9));
      expect(same.getColumn(0).length, closeTo(1, 1e-9));
    });
  });

  group('small helpers', () {
    test('lerp goes from one to the other', () {
      expect(lerp(10, 20, 0.5), closeTo(15, 1e-9));
    });

    test('a turn takes the short way round', () {
      // The long way is a character spinning 350 degrees to look 10 the other
      // way, which is the classic version of this bug.
      expect(shortestTurn(0.1, 6.1), closeTo(-0.283, 0.01));
      expect(shortestTurn(0, math.pi / 2), closeTo(math.pi / 2, 1e-9));
    });
  });
}
