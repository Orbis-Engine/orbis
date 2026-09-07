import 'package:vector_math/vector_math_64.dart';

/// One version of a mesh, and how far away it stops being worth drawing.
class OrbisStep {
  const OrbisStep(this.mesh, this.until);

  /// The file, or null for the built-in cube.
  final String? mesh;

  /// How far from the camera this version is used up to, in metres.
  ///
  /// Not a range: the previous step's [until] is where this one starts, so
  /// there is no gap to fall down and no overlap to argue about. The last
  /// step's [until] is where the object stops being drawn — pass
  /// [double.infinity] for something that is never too far.
  final double until;
}

/// A mesh chosen by how far away it is.
///
/// Detail nobody can see is detail nobody should pay for. A tree at four
/// hundred metres covers a dozen pixels, and drawing the version with every
/// leaf on it costs the same as the one in front of the camera and looks the
/// same as the crudest version that fits.
///
/// The decision is made here rather than in the renderer, and deliberately.
/// The renderer knows where the camera is and nothing else; the application
/// knows which of its meshes are versions of the same thing, which is the part
/// that cannot be worked out from a scene. So this resolves before the scene
/// is published — the renderer never hears about it, and there is no second
/// idea of what an object is for the two ends to disagree about.
class OrbisLod {
  const OrbisLod(this.steps, {this.hysteresis = 0.1});

  /// The versions, nearest first.
  ///
  /// Not sorted here: an unsorted list is a mistake worth seeing rather than
  /// quietly correcting, because the order is the whole meaning and a list
  /// silently reordered is a bug that never surfaces.
  final List<OrbisStep> steps;

  /// How far past a boundary the camera must go before the step changes, as a
  /// fraction of the distance.
  ///
  /// Without it, an object sitting exactly on a boundary swaps back and forth
  /// on every frame the camera breathes — a visible flicker, and one that
  /// costs a mesh change each time it happens. A tenth is enough that nothing
  /// oscillates and small enough that nobody sees the swap arrive late.
  final double hysteresis;

  /// Whether the steps run outwards, which is what makes [meshAt] meaningful.
  bool get isOrdered {
    for (var i = 1; i < steps.length; i++) {
      if (steps[i].until < steps[i - 1].until) return false;
    }
    return true;
  }

  /// How far this stops being drawn at all. Nothing, for no steps.
  ///
  /// A level of detail with no levels draws nothing rather than throwing: it
  /// is what a half-written asset looks like, and one of those should show up
  /// as a missing tree rather than as a dead frame.
  double get range => steps.isEmpty ? 0 : steps.last.until;

  /// The step to use at [distance] metres, given [was] a moment ago.
  ///
  /// [was] is what makes the hysteresis work: it is the step this object was
  /// already showing, and moving away from it costs more than staying. Pass
  /// null the first time, which takes the boundary at face value.
  int stepAt(double distance, {int? was}) {
    if (steps.isEmpty) return 0;
    for (var i = 0; i < steps.length; i++) {
      var boundary = steps[i].until;

      // The boundary moves outwards while this step is the one being shown,
      // so the camera has to mean it before the mesh changes.
      if (was != null && was == i && boundary.isFinite) {
        boundary *= 1 + hysteresis;
      }
      if (distance <= boundary) return i;
    }
    return steps.length - 1;
  }

  /// The mesh to draw at [distance], or null when it is past the last step.
  ///
  /// Null is "do not draw this", not "draw the cube": an object beyond its own
  /// range is one the application has said is not worth the pixels, and
  /// falling back to a default mesh would put the crudest version of it on
  /// screen forever.
  String? meshAt(double distance, {int? was}) {
    if (steps.isEmpty || distance > range) return null;
    return steps[stepAt(distance, was: was)].mesh;
  }

  /// Whether anything is drawn at [distance].
  bool isVisibleAt(double distance) => steps.isNotEmpty && distance <= range;
}

/// Which step each object is showing, so the hysteresis has a yesterday.
///
/// Kept by the application beside its objects rather than inside the level of
/// detail, because one [OrbisLod] describes a kind of thing — a species of
/// tree — and a thousand of them are each at their own distance.
class OrbisDetailState {
  final Map<int, int> _showing = {};

  /// The step object [key] should show at [distance], remembering what it was
  /// showing before.
  int stepFor(int key, OrbisLod lod, double distance) {
    final step = lod.stepAt(distance, was: _showing[key]);
    _showing[key] = step;
    return step;
  }

  /// The mesh object [key] should show, or null when it is out of range.
  String? meshFor(int key, OrbisLod lod, Vector3 at, Vector3 camera) {
    final distance = (at - camera).length;
    if (!lod.isVisibleAt(distance)) {
      // Forgotten rather than remembered as the last step: something out of
      // range for a while and then in front of the camera should pick its
      // step from where it is, not from where it was a minute ago.
      _showing.remove(key);
      return null;
    }
    return lod.steps[stepFor(key, lod, distance)].mesh;
  }

  /// Forgets everything, for a scene that has been closed or reloaded.
  void clear() => _showing.clear();

  /// Forgets one object.
  void forget(int key) => _showing.remove(key);

  int get length => _showing.length;
}
