import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// Many copies of one mesh, drawn in one call.
///
/// The answer to a scene with a hundred thousand things in it. An
/// [OrbisObject] is a thing the renderer keeps track of: it has a key, it is
/// compared against what was there last frame, it gets its own entity and its
/// own place in the culling. That is the right shape for the dozens of things
/// somebody is arranging by hand, and the wrong shape for a forest — a
/// hundred thousand of them is a hundred thousand comparisons, a hundred
/// thousand entities and a hundred thousand draw calls, and no amount of
/// tuning rescues that.
///
/// A population turns the question around. There is one mesh, one material and
/// one buffer of transforms, and the renderer submits it once. The cost stops
/// being per object and becomes per population, which is the only way the
/// numbers work.
///
/// What it gives up is individuality: everything in a population shares a
/// mesh, is culled as one box, and is drawn or not drawn together. Anything
/// that needs to be picked, moved or lit on its own is an object, not a member
/// of a population. Most of what makes a world large is not.
class OrbisPopulation {
  OrbisPopulation({
    required this.key,
    required this.transforms,
    required this.colours,
    required this.minimum,
    required this.maximum,
    this.mesh,
    this.range = 0,
    this.revision = 0,
    this.castShadows = false,
    this.receiveShadows = true,
    this.layer = 0,
  }) : assert(
         transforms.length == colours.length ~/ 3 * 16,
         'one transform of sixteen and one colour of three for each',
       );

  /// What this population is, across frames. The renderer keeps its buffers
  /// against this key rather than rebuilding them.
  final int key;

  /// Sixteen floats each, column-major, in world space.
  ///
  /// Held as one flat buffer rather than a list of matrices because that is
  /// what both ends want: nothing here allocates per member, and the renderer
  /// uploads the whole thing in one go. An application that moves its members
  /// writes into this in place.
  final Float32List transforms;

  /// Three floats each, linear RGB.
  final Float32List colours;

  /// One box around the lot, in world space.
  ///
  /// Every member is culled by this one box, so it has to cover all of them —
  /// a box that is too small makes the whole population blink out when the
  /// camera turns away from where the box is rather than where the members
  /// are. Stated rather than worked out, because working it out means walking
  /// a hundred thousand transforms and the application usually knows the
  /// answer already.
  final Vector3 minimum;
  final Vector3 maximum;

  /// How far a member is still drawn from, in metres. Zero draws all of them.
  ///
  /// The other half of culling. What is in front of the camera is the
  /// renderer's business and it does it well; what is close enough to be worth
  /// drawing at all is the application's, because only it knows whether a
  /// thing a kilometre away is a tree that may as well not exist or a mountain
  /// that must.
  ///
  /// This is what lets a whole map be loaded rather than streamed: the members
  /// all sit in one buffer, uploaded once, and the ones too far to see cost a
  /// distance test each frame instead of a draw. They are tested in groups of
  /// sixty-four, so a hundred thousand of them is sixteen hundred tests.
  final double range;

  /// The mesh every member is a copy of, or null for the built-in cube.
  final String? mesh;

  /// Bumped by whoever writes into [transforms] or [colours].
  ///
  /// This is the whole performance story, and it is worth being plain about
  /// it: a hundred thousand transforms is six megabytes, and sending that
  /// sixty times a second is four hundred megabytes a second to say nothing
  /// changed. The revision is how the two ends agree that nothing did — the
  /// buffers are left out of the message entirely, and the renderer keeps
  /// drawing what it already has.
  ///
  /// A scene that is only being looked at therefore costs nothing per member
  /// per frame, which is the difference between a forest and a slideshow.
  final int revision;

  final bool castShadows;
  final bool receiveShadows;

  /// Which group of the scene this belongs to, the same way an object has one.
  ///
  /// A population is one thing to the renderer, so its whole membership is on
  /// one layer — which is the right grain: a forest is either in the
  /// reflection or it is not.
  final int layer;

  /// How many members there are.
  int get count => transforms.length ~/ 16;

  bool get isVisible => count > 0;

  /// Bit flags, in the order the renderer reads them. The layer rides in the
  /// high bits, as it does for an object.
  int get flags =>
      (castShadows ? 1 : 0) |
      (receiveShadows ? 2 : 0) |
      (layer.clamp(0, 6) << 8);
}
