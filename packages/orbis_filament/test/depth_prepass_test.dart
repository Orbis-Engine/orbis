import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

/// The depth prepass is one flag on the wire and nothing else, and these are
/// the ways that one flag could go missing between the author and the
/// renderer.
///
/// What a prepass does to a frame is measured on the device, on two GPUs of
/// different kinds, because the answer differs between them — see the
/// Overdraw example. What is checked here is that the scene says what the
/// author asked for, and says nothing else differently: a scene that turned
/// the prepass on and also packed its objects differently would be two
/// changes, and no measurement could tell which one moved the picture.
void main() {
  OrbisScene sceneOf({bool? depthPrepass}) {
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
    return depthPrepass == null
        ? OrbisScene(objects: objects, camera: camera)
        : OrbisScene(
            objects: objects,
            camera: camera,
            depthPrepass: depthPrepass,
          );
  }

  test('is off unless asked for', () {
    // Off because it was measured to be worth nothing on the hardware this
    // engine is developed on: an Apple GPU decides which surface wins a tile
    // before shading any of it, so there is no fragment cost left for a
    // second pass to save and the second pass is pure addition. A scene
    // written before the prepass existed, or one that never turns it on,
    // draws exactly as it always did.
    expect(sceneOf().depthPrepass, isFalse);
    expect(sceneOf().toMessage(1)['depthPrepass'], isFalse);
  });

  test('reaches the message when asked for', () {
    expect(sceneOf(depthPrepass: true).toMessage(1)['depthPrepass'], isTrue);
  });

  test('changes nothing else about the message', () {
    // The objects travel exactly as they did. Which of them the prepass
    // covers is decided on the far side, by looking at what arrives, not by
    // packing anything differently here.
    final off = sceneOf(depthPrepass: false).toMessage(1);
    final on = sceneOf(depthPrepass: true).toMessage(1);
    expect(off.keys.toSet(), on.keys.toSet());
    for (final key in off.keys) {
      if (key == 'depthPrepass') continue;
      expect(on[key], off[key], reason: '$key differs with the prepass on');
    }
  });

  test('survives copyWith, and can be changed by it', () {
    final on = sceneOf(depthPrepass: true);
    // Another field changed: the prepass is kept rather than quietly reset,
    // which is the way a flag added to a copyWith is usually lost.
    expect(on.copyWith(sky: OrbisSky()).depthPrepass, isTrue);
    expect(on.copyWith(depthPrepass: false).depthPrepass, isFalse);
    expect(sceneOf().copyWith(depthPrepass: true).depthPrepass, isTrue);
  });

  test('is independent of batching', () {
    // Two switches, not one: they are measured separately and a scene may
    // want either, both or neither. A batched group gets no prepass — it is
    // one instanced renderable and there is no second one built for it — so
    // turning both on must still carry both flags rather than one silently
    // standing for the other.
    final both = sceneOf().copyWith(batching: true, depthPrepass: true);
    expect(both.batching, isTrue);
    expect(both.depthPrepass, isTrue);
    expect(both.copyWith(batching: false).depthPrepass, isTrue);
    expect(both.copyWith(depthPrepass: false).batching, isTrue);

    final message = both.toMessage(1);
    expect(message['batching'], isTrue);
    expect(message['depthPrepass'], isTrue);
  });
}
