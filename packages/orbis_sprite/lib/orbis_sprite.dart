/// Two dimensions: atlases, sprite animation, parallax and tile maps.
///
/// Data and timing, not drawing. Nothing here binds a texture or submits a
/// draw — what it answers is which rectangle of which image to draw, and
/// where. That is the half a renderer cannot work out, and keeping it apart
/// is why the same animation drives a sprite in a scene, a preview in an
/// editor and an assertion in a test.
///
/// Everything with a clock is sampled rather than stepped, like the effects
/// and the sequencer: asked what it looks like at a moment, not advanced by a
/// frame's worth.
library;

export 'src/animation.dart' show Flipbook, Frame, SpriteAnimation;
export 'src/atlas.dart' show Atlas, Region;
export 'src/parallax.dart' show Layer, Parallax, View2;
export 'src/tiles.dart' show TileLayer, TileMap, Tileset;
