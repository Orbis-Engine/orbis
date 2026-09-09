import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

OrbisObject one(int key, {List<double>? shapes}) => OrbisObject(
  key: key,
  transform: Matrix4.identity(),
  colour: Vector3(1, 1, 1),
  mesh: '/models/$key.glb',
  morphWeights: shapes,
);

Map<String, Object?> sent(List<OrbisObject> objects) => OrbisScene(
  objects: objects,
  camera: OrbisCamera(position: Vector3(0, 2, 8), target: Vector3.zero()),
).toMessage(1);

void main() {
  group('morph weights on the wire', () {
    test('an object with no shapes takes no room', () {
      final message = sent([one(1), one(2)]);
      expect((message['objectMorphCounts']! as Int32List).toList(), [0, 0]);
    });

    test(
      'counts say where each object\'s shapes are, and they pack in order',
      () {
        // The far side walks the weights alongside the objects, so the counts
        // and the buffer have to agree exactly. Getting this wrong reads one
        // object's face onto another and there is no error to see it by.
        final message = sent([
          one(1, shapes: [0.25]),
          one(2),
          one(3, shapes: [0.5, 0.75, 1.0]),
        ]);

        expect((message['objectMorphCounts']! as Int32List).toList(), [
          1,
          0,
          3,
        ]);
        expect((message['objectMorphWeights']! as Float32List).toList(), [
          0.25,
          0.5,
          0.75,
          1.0,
        ]);
      },
    );

    test('the counts add up to the weights, whatever the mix', () {
      final message = sent([
        one(1, shapes: [0.1, 0.2]),
        one(2),
        one(3, shapes: [0.3]),
        one(4, shapes: []),
      ]);
      final counts = message['objectMorphCounts']! as Int32List;
      final weights = message['objectMorphWeights']! as Float32List;
      expect(counts.reduce((a, b) => a + b), weights.length);
    });

    test('a scene with no shapes anywhere still sends a buffer', () {
      // The far side takes a pointer, and an empty typed list has none to
      // give. One unread float is cheaper than a special case at both ends.
      final weights = sent([one(1)])['objectMorphWeights']! as Float32List;
      expect(weights, isNotEmpty);
    });
  });
}
