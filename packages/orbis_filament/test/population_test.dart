import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

OrbisPopulation crowd({required int count, int revision = 1, int key = 1}) =>
    OrbisPopulation(
      key: key,
      transforms: Float32List(count * 16),
      colours: Float32List(count * 3),
      minimum: Vector3(-10, 0, -10),
      maximum: Vector3(10, 4, 10),
      revision: revision,
    );

OrbisScene sceneOf(List<OrbisPopulation> populations) => OrbisScene(
  objects: const [],
  populations: populations,
  camera: OrbisCamera(position: Vector3(0, 2, 8), target: Vector3.zero()),
);

void main() {
  group('populations on the wire', () {
    test('a fresh renderer is sent everything', () {
      final message = sceneOf([crowd(count: 100)]).toMessage(1);

      expect(
        (message['populationTransforms']! as Float32List).length,
        100 * 16,
      );
      expect((message['populationColours']! as Float32List).length, 100 * 3);
      expect((message['populationChanged']! as Int32List).single, 1);
    });

    test('a renderer that already has them is sent none of it', () {
      // The whole performance story in one assertion. A hundred thousand
      // transforms is six megabytes, and a scene that is standing still must
      // not send it sixty times a second to say that nothing moved.
      final message = sceneOf([
        crowd(count: 100000, revision: 4),
      ]).toMessage(1, sentRevisions: {1: 4});

      expect((message['populationTransforms']! as Float32List), isEmpty);
      expect((message['populationColours']! as Float32List), isEmpty);
      expect((message['populationChanged']! as Int32List), isEmpty);

      // It still hears how many there are and where they are, because that is
      // what tells it whether to rebuild and how to cull.
      expect((message['populationCounts']! as Int32List).single, 100000);
      expect((message['populationRevisions']! as Int32List).single, 4);
    });

    test('only the one that moved is sent', () {
      final message = sceneOf([
        crowd(key: 1, count: 10, revision: 2),
        crowd(key: 2, count: 20, revision: 9),
      ]).toMessage(1, sentRevisions: {1: 2, 2: 8});

      expect((message['populationChanged']! as Int32List).single, 2);
      expect((message['populationTransforms']! as Float32List).length, 20 * 16);
    });

    test('the changed buffers are packed in the order they are named', () {
      final first = crowd(key: 1, count: 2, revision: 1);
      final second = crowd(key: 2, count: 3, revision: 1);
      first.transforms[0] = 7;
      second.transforms[0] = 11;

      final message = sceneOf([first, second]).toMessage(1);
      final named = message['populationChanged']! as Int32List;
      final packed = message['populationTransforms']! as Float32List;

      expect(named, [1, 2]);
      expect(packed[0], 7);
      // Three transforms of sixteen after the first population's two.
      expect(packed[2 * 16], 11);
    });

    test('how far a population is drawn from travels with it', () {
      final message = sceneOf([
        OrbisPopulation(
          key: 1,
          transforms: Float32List(16),
          colours: Float32List(3),
          minimum: Vector3(-800, 0, -800),
          maximum: Vector3(800, 6, 800),
          range: 350,
        ),
      ]).toMessage(1);

      expect((message['populationRanges']! as Float32List).single, 350);
    });

    test('drawing everything is the default, and says so', () {
      // Zero rather than infinity, because zero is what "no opinion" reads as
      // in a float array and infinity is what a mistake reads as.
      expect(crowd(count: 4).range, 0);
    });

    test('a scene with no populations says nothing about them', () {
      final message = sceneOf(const []).toMessage(1);
      expect(message.containsKey('populationKeys'), isFalse);
    });

    test('a transform and a colour are required of every member', () {
      expect(
        () => OrbisPopulation(
          key: 1,
          transforms: Float32List(32),
          colours: Float32List(3),
          minimum: Vector3.zero(),
          maximum: Vector3.zero(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
