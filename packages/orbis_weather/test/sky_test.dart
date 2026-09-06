import 'dart:math' as math;

import 'package:orbis_light/orbis_light.dart';
import 'package:orbis_weather/orbis_weather.dart';
import 'package:test/test.dart';

void main() {
  group('the day', () {
    test('the sun is up at noon and the moon at midnight', () {
      expect(DayCycle.at(12).body, CelestialBody.sun);
      expect(DayCycle.at(0).body, CelestialBody.moon);
      expect(DayCycle.at(23).body, CelestialBody.moon);
    });

    test('it comes from overhead at noon', () {
      // Light travelling downwards, which is what a sun overhead does.
      expect(DayCycle.at(12).direction.y, lessThan(-0.85));
    });

    test('it rises on one side and sets on the other', () {
      final morning = DayCycle.at(8).direction;
      final evening = DayCycle.at(16).direction;

      // Light in the morning comes from the opposite side to light in the
      // evening. A sun that went back the way it came would light both ends
      // of a day identically.
      expect(morning.x.sign, isNot(evening.x.sign));
    });

    test('the moon is opposite where the sun would have been', () {
      // Two in the morning, and the sun eight hours later.
      final moon = DayCycle.at(2).direction;
      final sun = DayCycle.at(10).direction;

      // Sideways, they are opposed; the moon is not simply the sun upside
      // down, it is on the other side of the sky.
      expect(moon.x.sign, isNot(sun.x.sign));
      expect(moon.y, lessThan(0));
    });

    test('the light goes warm at the horizon and white overhead', () {
      final dawn = DayCycle.at(6.5).lightColour;
      final noon = DayCycle.at(12).lightColour;

      double warmth(Tint colour) => colour.red - colour.blue;
      expect(warmth(dawn), greaterThan(warmth(noon)));
    });

    test('the sky is darker at night than at noon', () {
      double lightness(Tint colour) =>
          colour.red + colour.green + colour.blue;
      expect(
        lightness(DayCycle.at(1).skyColour),
        lessThan(lightness(DayCycle.at(12).skyColour)),
      );
    });

    test('a night is many stops darker than a day', () {
      // Not a little darker: about seventeen stops. Which is the whole reason
      // the exposure has to move — on one setting, one of the two is a solid
      // colour.
      expect(DayCycle.at(12).power, greaterThan(DayCycle.at(0).power * 10000));
    });

    test('the camera opens up for the night and stops down for the day', () {
      final night = DayCycle.at(0).exposure;
      final noon = DayCycle.at(12).exposure;

      expect(night.aperture, lessThan(noon.aperture));
      expect(night.shutterSpeed, greaterThan(noon.shutterSpeed));
      expect(night.sensitivity, greaterThan(noon.sensitivity));
    });

    test('noon meters where a century of film boxes put it', () {
      final noon = DayCycle.at(12).exposure;
      // Sunny sixteen is EV 15 at ISO 100, and a meter that lands anywhere
      // else has its calibration wrong.
      expect(noon.ev100, closeTo(15, 0.5));
      expect(noon.sensitivity, 100);
    });

    test('no hour of the day comes out blown out or black', () {
      // The one that matters. A cycle whose light levels and whose exposure
      // are authored separately will disagree somewhere, and the way it shows
      // up is an editor full of white shapes with nothing on them. Metering
      // off the light that is actually falling on the scene is what stops
      // that, and this is what proves it at every hour rather than the two
      // that happened to be looked at.
      for (var minute = 0; minute < 24 * 60; minute += 5) {
        final sky = DayCycle.at(minute / 60);

        final incident = sky.power * 683 * math.max(0, math.sin(sky.altitude)) +
            sky.ambient;
        // What Filament does with the three numbers, and then what a
        // mid-grey surface facing the light comes out as.
        final exposure = 1 / (1.2 * math.pow(2, sky.exposure.ev100));
        final grey = incident * 0.5 / math.pi * exposure;

        expect(
          grey,
          inInclusiveRange(0.05, 0.6),
          reason: 'at ${minute ~/ 60}:${(minute % 60).toString().padLeft(2, '0')}'
              ' a mid-grey surface comes out at $grey',
        );
      }
    });

    test('the light and the sky rise and fall together', () {
      // The sky is lit by the same body everything else is, so the two cannot
      // be authored apart without the shadows going the wrong depth at some
      // hour of the day.
      for (final hour in [7.0, 9.0, 12.0, 15.0, 17.0]) {
        final sky = DayCycle.at(hour);
        expect(sky.ambient, closeTo(sky.power * 683 * DayCycle.skyShare, 1));
      }
    });

    test('an hour past the end of the day is an hour into the next', () {
      expect(DayCycle.at(25).body, DayCycle.at(1).body);
      expect(DayCycle.at(25).power, DayCycle.at(1).power);
    });

    test('each body crosses the sky smoothly', () {
      // Walked a minute at a time through the sun's half of the day and then
      // the moon's. Within one arc there is nothing to jump over, and a body
      // that teleported would read as a light being switched on somewhere
      // else.
      for (final span in const [(6.2, 17.8), (18.2, 29.8)]) {
        var previous = DayCycle.at(span.$1);
        for (var minute = 1; minute < (span.$2 - span.$1) * 60; minute++) {
          final now = DayCycle.at(span.$1 + minute / 60);
          expect(
            (now.direction - previous.direction).length,
            lessThan(0.01),
            reason: 'jumped at ${span.$1 + minute / 60} hours',
          );
          previous = now;
        }
      }
    });

    test('the swap at the horizon happens in the dark', () {
      // The one place the direction does jump: the sun sets on one side and
      // the moon is already up on the other, which is what those two bodies
      // actually do. It is only allowed to be a jump because there is no
      // light left in it to see by — the sun has faded to nothing by the time
      // it reaches the horizon.
      for (final hour in const [6.0, 18.0]) {
        expect(DayCycle.at(hour - 0.01).power, lessThan(0.05));
        expect(DayCycle.at(hour + 0.01).power, lessThan(0.05));
      }
    });

    test('everything that can be seen changes smoothly across dawn', () {
      final before = DayCycle.at(5.99);
      final after = DayCycle.at(6.01);

      double gap(Tint a, Tint b) => (a.red - b.red).abs() +
          (a.green - b.green).abs() +
          (a.blue - b.blue).abs();

      expect(gap(before.skyColour, after.skyColour), lessThan(0.02));
      expect(
        (before.exposure.sensitivity - after.exposure.sensitivity).abs(),
        lessThan(50),
      );
      expect((before.ambient - after.ambient).abs(), lessThan(200));
    });
  });
}
