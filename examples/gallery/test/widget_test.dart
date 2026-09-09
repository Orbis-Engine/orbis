import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_examples/orbis_examples.dart';

void main() {
  test('every example can be built and asked for a scene', () {
    // The gallery opens straight into one of these, so an example that throws
    // on construction takes the window with it. Cheap, and it is the check
    // nothing else was making: this package had no tests at all.
    for (final example in engineExamples()) {
      expect(example.name, isNotEmpty);
      final look = GalleryCamera.from(example.viewpoint);
      final scene = example.scene(look.toRenderCamera(), 0);
      expect(
        scene.camera,
        isNotNull,
        reason: '${example.name} returned a scene with no camera',
      );
    }
  });
}
