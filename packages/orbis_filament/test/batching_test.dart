import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

/// Batching is one flag on the wire and nothing else, and these are the ways
/// that one flag could go missing between the author and the renderer.
///
/// What batching does to a frame is measured on the device, where the frames
/// are; what is checked here is that the scene says what the author asked
/// for, and says nothing else differently — because a batched scene that also
/// packed its objects differently would be two changes, and the measurement
/// would not be able to tell which one moved the picture.
void main() {
  OrbisScene sceneOf({bool? batching}) {
    final objects = [
      for (var i = 0; i < 6; i++)
        OrbisObject(
          key: 100 + i,
          transform: Matrix4.translationValues(i.toDouble(), 0, 0),
          colour: Vector3(0.5, 0.4, 0.3),
        ),
    ];
    final camera = OrbisCamera(
      position: Vector3(0, 2, 8),
      target: Vector3.zero(),
    );
    return batching == null
        ? OrbisScene(objects: objects, camera: camera)
        : OrbisScene(objects: objects, camera: camera, batching: batching);
  }

  test('is off unless asked for', () {
    // Still off by default even now that the renderer builds a merged group
    // as one manually-instanced renderable rather than asking Filament's own
    // automatic instancing to notice one after the fact: proven bit-identical
    // wherever nothing casts a shadow onto or out of a batched group, but not
    // proven where one does — see the field's own doc comment for the
    // measurements this rests on. A scene written before batching existed,
    // or one that never turns it on, draws exactly as it always did either
    // way.
    expect(sceneOf().batching, isFalse);
    expect(sceneOf().toMessage(1)['batching'], isFalse);
  });

  test('reaches the message when asked for', () {
    expect(sceneOf(batching: true).toMessage(1)['batching'], isTrue);
  });

  test('changes nothing else about the message', () {
    // The objects travel exactly as they did. Batching is decided on the far
    // side by comparing what arrives, not by packing anything differently.
    final off = sceneOf(batching: false).toMessage(1);
    final on = sceneOf(batching: true).toMessage(1);
    expect(off.keys.toSet(), on.keys.toSet());
    for (final key in off.keys) {
      if (key == 'batching') continue;
      expect(on[key], off[key], reason: '$key differs with batching on');
    }
  });

  test('survives copyWith, and can be changed by it', () {
    final on = sceneOf(batching: true);
    // Another field changed: batching is kept rather than quietly reset,
    // which is the way a flag added to a copyWith is usually lost.
    expect(on.copyWith(sky: OrbisSky()).batching, isTrue);
    expect(on.copyWith(batching: false).batching, isFalse);
    expect(sceneOf().copyWith(batching: true).batching, isTrue);
  });
}
