import 'dart:typed_data';
import 'dart:ui' show Color;

import 'key_list.dart';

/// What becomes of the parts of an outlined object that something else hides.
///
/// The reason an outline is worth drawing in the renderer rather than as a box
/// over the picture: a box does not know what is in front of what, and an
/// outline does. An object selected behind a wall should still be findable —
/// but it should also be obvious that it *is* behind the wall, which is what
/// drawing its hidden edge differently says.
enum OrbisOccluded {
  /// Drawn exactly like the visible edge. The cheapest style, because the
  /// renderer never has to work out what hides what.
  shown,

  /// Drawn at [OrbisOutline.occludedOpacity].
  faint,

  /// Faint, and broken into dashes [OrbisOutline.dash] pixels long.
  dashed,

  /// Not drawn: only the visible edge is outlined.
  hidden,
}

/// A line drawn round the silhouettes of some of the scene's objects — what
/// an editor shows its selection with.
///
/// It follows the shape rather than a box round it, and it is drawn after the
/// frame is finished: after tone mapping, so [colour] lands on the screen as
/// exactly the colour given; and after anti-aliasing, so it never enters a
/// temporal history and never crawls as the camera moves. Which is why the
/// colours here are Flutter [Color]s — display colours — where an object's
/// colour is linear: this one is never lit and never graded.
///
/// One object may be [primary], the active one, drawn in [primaryColour] —
/// brighter by default, the way an editor distinguishes the object the
/// inspector is showing from the rest of what is selected.
///
/// Costs nothing while [keys] is empty and [primary] is null. When something
/// is outlined it costs a depth-only render of the outlined objects, one of
/// the whole scene if hidden parts are to look different, and two passes over
/// the screen whose cost grows with [width] rather than its square.
///
/// Only [OrbisScene.objects] can be outlined. A population is drawn in one
/// call for all its members and has no single one to pick out.
class OrbisOutline {
  const OrbisOutline({
    this.keys = const {},
    this.primary,
    this.colour = defaultColour,
    this.primaryColour = defaultPrimaryColour,
    this.width = 2,
    this.occluded = OrbisOccluded.dashed,
    this.occludedOpacity = 0.4,
    this.dash = 6,
  });

  /// Nothing outlined.
  static const none = OrbisOutline();

  /// A deep orange for the selection, and a lighter, brighter one for the
  /// active object — the convention most 3D tools have settled on, so the
  /// colours mean something to somebody before they have read anything.
  static const Color defaultColour = Color(0xFFF15800);
  static const Color defaultPrimaryColour = Color(0xFFFFAA40);

  /// The widest outline the renderer draws, in pixels.
  ///
  /// Both passes look a fixed distance in the worst case, so this is what
  /// bounds the cost. Sixteen is wider than any selection wants to be.
  static const double maxWidth = 16;

  /// How many floats the settings take on the wire.
  static const int stride = 14;

  /// The objects outlined, by [OrbisObject.key]. Keys the scene does not
  /// have are ignored, so a selection that outlives its object is harmless.
  final Set<int> keys;

  /// The active object, drawn in [primaryColour]. Outlined whether or not it
  /// is also in [keys].
  final int? primary;

  final Color colour;
  final Color primaryColour;

  /// In pixels of the frame, up to [maxWidth]. A fractional width gives the
  /// outermost pixel partial cover.
  final double width;

  final OrbisOccluded occluded;

  /// How opaque a hidden edge is, nought to one, for the faint and dashed
  /// styles.
  final double occludedOpacity;

  /// How long a dash is, in pixels, for the dashed style.
  final double dash;

  /// Whether this outlines nothing, and so costs nothing.
  bool get isEmpty => keys.isEmpty && primary == null;

  OrbisOutline copyWith({
    Set<int>? keys,
    int? primary,
    bool clearPrimary = false,
    Color? colour,
    Color? primaryColour,
    double? width,
    OrbisOccluded? occluded,
    double? occludedOpacity,
    double? dash,
  }) => OrbisOutline(
    keys: keys ?? this.keys,
    primary: clearPrimary ? null : primary ?? this.primary,
    colour: colour ?? this.colour,
    primaryColour: primaryColour ?? this.primaryColour,
    width: width ?? this.width,
    occluded: occluded ?? this.occluded,
    occludedOpacity: occludedOpacity ?? this.occludedOpacity,
    dash: dash ?? this.dash,
  );

  /// The keys as they travel: the active one first, then the rest, each once.
  ///
  /// Ordered rather than flagged because the renderer only needs to know how
  /// many at the front are active, and a count is one number where a flag per
  /// key is a second array.
  List<int> get packedKeys {
    final active = primary;
    return keyListFrom([
      if (active != null) active,
      for (final key in keys)
        if (key != active) key,
    ]);
  }

  /// The settings, [stride] floats: the selection's colour and the active
  /// object's as RGBA from nought to one, the width, the hidden style, its
  /// opacity, the dash length, how many of [packedKeys] are active, and one
  /// spare.
  Float32List get packed {
    final out = Float32List(stride);
    void put(int at, Color colour) {
      out[at] = colour.r;
      out[at + 1] = colour.g;
      out[at + 2] = colour.b;
      out[at + 3] = colour.a;
    }

    put(0, colour);
    put(4, primaryColour);
    out[8] = width.clamp(0, maxWidth).toDouble();
    out[9] = occluded.index.toDouble();
    out[10] = occludedOpacity.clamp(0, 1).toDouble();
    out[11] = dash < 0 ? 0 : dash;
    out[12] = primary == null ? 0 : 1;
    out[13] = 0;
    return out;
  }
}
