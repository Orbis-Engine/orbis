import 'package:vector_math/vector_math_64.dart';

/// A box in world space.
class OrbisBounds {
  const OrbisBounds(this.minimum, this.maximum);

  /// A box around one point.
  factory OrbisBounds.at(Vector3 point) => OrbisBounds(point, point);

  /// A box around everything in [boxes], or null if there are none.
  static OrbisBounds? around(Iterable<OrbisBounds> boxes) {
    OrbisBounds? all;
    for (final box in boxes) {
      all = all == null ? box : all.union(box);
    }
    return all;
  }

  final Vector3 minimum;
  final Vector3 maximum;

  Vector3 get centre => (minimum + maximum) * 0.5;
  Vector3 get size => maximum - minimum;

  /// The surface area, which is what a tree is built to minimise.
  ///
  /// Not for its own sake: the chance of a random ray hitting a box is
  /// proportional to its surface area, so a tree whose boxes have less area
  /// between them is a tree that answers a query having opened fewer of them.
  /// That is the whole of the surface-area heuristic and the reason it beats
  /// splitting down the middle.
  double get area {
    final extent = size;
    if (extent.x < 0 || extent.y < 0 || extent.z < 0) return 0;
    return 2 *
        (extent.x * extent.y + extent.y * extent.z + extent.z * extent.x);
  }

  OrbisBounds union(OrbisBounds other) => OrbisBounds(
    Vector3(
      minimum.x < other.minimum.x ? minimum.x : other.minimum.x,
      minimum.y < other.minimum.y ? minimum.y : other.minimum.y,
      minimum.z < other.minimum.z ? minimum.z : other.minimum.z,
    ),
    Vector3(
      maximum.x > other.maximum.x ? maximum.x : other.maximum.x,
      maximum.y > other.maximum.y ? maximum.y : other.maximum.y,
      maximum.z > other.maximum.z ? maximum.z : other.maximum.z,
    ),
  );

  bool overlaps(OrbisBounds other) =>
      minimum.x <= other.maximum.x &&
      maximum.x >= other.minimum.x &&
      minimum.y <= other.maximum.y &&
      maximum.y >= other.minimum.y &&
      minimum.z <= other.maximum.z &&
      maximum.z >= other.minimum.z;

  bool contains(Vector3 point) =>
      point.x >= minimum.x &&
      point.x <= maximum.x &&
      point.y >= minimum.y &&
      point.y <= maximum.y &&
      point.z >= minimum.z &&
      point.z <= maximum.z;

  /// Where a ray enters and leaves, or null if it misses.
  ///
  /// The slab test: the ray is clipped against each pair of parallel faces in
  /// turn, and what survives all three is the span inside the box. Written
  /// without branches on the sign of the direction because a divide by zero
  /// gives an infinity here that compares correctly — a ray parallel to a slab
  /// is either inside it for ever or outside it for ever, and that is exactly
  /// what infinity says.
  ({double near, double far})? hit(Vector3 from, Vector3 direction) {
    var near = 0.0;
    var far = double.infinity;

    for (var axis = 0; axis < 3; axis++) {
      final origin = from[axis];
      final along = direction[axis];
      final low = minimum[axis];
      final high = maximum[axis];

      if (along.abs() < 1e-12) {
        // Parallel to this pair of faces: either between them all the way, or
        // never.
        if (origin < low || origin > high) return null;
        continue;
      }

      var first = (low - origin) / along;
      var second = (high - origin) / along;
      if (first > second) {
        final swap = first;
        first = second;
        second = swap;
      }
      if (first > near) near = first;
      if (second < far) far = second;
      if (near > far) return null;
    }
    return (near: near, far: far);
  }
}

/// One thing in the tree.
class OrbisVolume {
  const OrbisVolume(this.key, this.bounds);

  /// Whatever the application calls it — an object's key, an index, an id.
  final int key;

  final OrbisBounds bounds;
}

/// A tree of boxes over a scene, for asking what is where.
///
/// Two questions, one structure. What can the camera see, and what does this
/// ray hit — and both are the same walk: open a box, and if it is worth
/// opening, open its children. A scene of a hundred thousand things answers
/// either in about seventeen steps instead of a hundred thousand.
///
/// Built once and rebuilt when the scene changes shape, not every frame.
/// Building is the expensive half and a scene being looked at does not change
/// shape at all; what moves within it is handled by [refit], which keeps the
/// tree's structure and just grows the boxes back over what is inside them.
///
/// The split is chosen by surface area rather than by cutting down the middle.
/// The chance of a ray meeting a box goes with its area, so the tree that
/// answers fastest is the one whose boxes have the least area between them —
/// and the difference against a middle split is not small on a scene laid out
/// the way people actually lay scenes out, in clusters with space between
/// them.
class OrbisBvh {
  OrbisBvh._(this._nodes, this._volumes);

  /// Builds a tree over [volumes].
  ///
  /// [leafSize] is how many things a leaf may hold before it is split. Above
  /// one because a tree of single items is mostly pointers: testing four boxes
  /// in a leaf is cheaper than three levels of tree to keep them apart.
  factory OrbisBvh.of(List<OrbisVolume> volumes, {int leafSize = 4}) {
    final held = [...volumes];
    final nodes = <_Node>[];
    if (held.isNotEmpty) {
      _build(nodes, held, 0, held.length, leafSize.clamp(1, 64));
    }
    return OrbisBvh._(nodes, held);
  }

  final List<_Node> _nodes;
  final List<OrbisVolume> _volumes;

  bool get isEmpty => _volumes.isEmpty;
  int get length => _volumes.length;

  /// How many boxes the tree holds, leaves and branches together.
  int get nodeCount => _nodes.length;

  /// How deep it goes. For a test that wants to know the build is balanced.
  int get depth => _nodes.isEmpty ? 0 : _depthFrom(0);

  /// A box around everything.
  OrbisBounds? get bounds => _nodes.isEmpty ? null : _nodes.first.bounds;

  int _depthFrom(int index) {
    final node = _nodes[index];
    if (node.isLeaf) return 1;
    final left = _depthFrom(node.left);
    final right = _depthFrom(node.right);
    return 1 + (left > right ? left : right);
  }

  /// Everything whose box overlaps [box].
  List<int> inside(OrbisBounds box) {
    final found = <int>[];
    _walk(0, (node) => node.bounds.overlaps(box), (volume) {
      if (volume.bounds.overlaps(box)) found.add(volume.key);
    });
    return found;
  }

  /// Everything the camera can see, given the six planes of its frustum.
  ///
  /// A plane is `nx, ny, nz, d` with its normal pointing inwards, so a point
  /// is inside when `dot(n, p) + d >= 0` for all six. A box is outside when
  /// every one of its corners is behind one plane — tested by pushing the box
  /// to its furthest corner *towards* the plane, which is one dot product
  /// rather than eight.
  List<int> visible(List<Vector4> planes) {
    final found = <int>[];
    bool worthOpening(_Node node) => _inFrustum(node.bounds, planes);
    _walk(0, worthOpening, (volume) {
      if (_inFrustum(volume.bounds, planes)) found.add(volume.key);
    });
    return found;
  }

  /// What a ray hits, nearest first.
  ///
  /// The distances are to each box, not to the geometry inside it: a tree
  /// knows where things are, not what shape they are. What this is for is
  /// cutting a hundred thousand candidates down to the two or three worth
  /// asking properly.
  List<({int key, double distance})> along(
    Vector3 from,
    Vector3 direction, {
    double within = double.infinity,
  }) {
    final found = <({int key, double distance})>[];
    if (_nodes.isEmpty) return found;

    final ray = direction.normalized();
    void search(int index) {
      final node = _nodes[index];
      final entry = node.bounds.hit(from, ray);
      if (entry == null || entry.near > within) return;

      if (node.isLeaf) {
        for (var i = node.first; i < node.first + node.count; i++) {
          final volume = _volumes[i];
          final at = volume.bounds.hit(from, ray);
          if (at != null && at.near <= within) {
            found.add((key: volume.key, distance: at.near));
          }
        }
        return;
      }
      search(node.left);
      search(node.right);
    }

    search(0);
    found.sort((a, b) => a.distance.compareTo(b.distance));
    return found;
  }

  /// The first thing a ray hits, or null.
  ({int key, double distance})? first(
    Vector3 from,
    Vector3 direction, {
    double within = double.infinity,
  }) {
    final hits = along(from, direction, within: within);
    return hits.isEmpty ? null : hits.first;
  }

  /// Grows every box back over what is inside it, keeping the structure.
  ///
  /// For a scene where things move but the arrangement does not change much —
  /// which is most scenes, most of the time. Rebuilding is O(n log n) and this
  /// is O(n), and the tree it leaves is slightly worse at answering than a
  /// fresh one. Worth doing every frame; worth rebuilding occasionally.
  ///
  /// [boundsOf] is asked for the new box of each key. Returning null leaves
  /// the old one, which is the right answer for something that has not moved.
  void refit(OrbisBounds? Function(int key) boundsOf) {
    for (var i = 0; i < _volumes.length; i++) {
      final replacement = boundsOf(_volumes[i].key);
      if (replacement != null) {
        _volumes[i] = OrbisVolume(_volumes[i].key, replacement);
      }
    }
    if (_nodes.isNotEmpty) _refitFrom(0);
  }

  OrbisBounds _refitFrom(int index) {
    final node = _nodes[index];
    if (node.isLeaf) {
      var box = _volumes[node.first].bounds;
      for (var i = node.first + 1; i < node.first + node.count; i++) {
        box = box.union(_volumes[i].bounds);
      }
      node.bounds = box;
      return box;
    }
    final box = _refitFrom(node.left).union(_refitFrom(node.right));
    node.bounds = box;
    return box;
  }

  void _walk(
    int index,
    bool Function(_Node) worthOpening,
    void Function(OrbisVolume) found,
  ) {
    if (_nodes.isEmpty) return;
    final node = _nodes[index];
    if (!worthOpening(node)) return;

    if (node.isLeaf) {
      for (var i = node.first; i < node.first + node.count; i++) {
        found(_volumes[i]);
      }
      return;
    }
    _walk(node.left, worthOpening, found);
    _walk(node.right, worthOpening, found);
  }

  static bool _inFrustum(OrbisBounds box, List<Vector4> planes) {
    for (final plane in planes) {
      // The corner furthest along the plane's inward normal. If even that is
      // behind the plane, every corner is, and the box is out.
      final furthest = Vector3(
        plane.x >= 0 ? box.maximum.x : box.minimum.x,
        plane.y >= 0 ? box.maximum.y : box.minimum.y,
        plane.z >= 0 ? box.maximum.z : box.minimum.z,
      );
      if (plane.x * furthest.x +
              plane.y * furthest.y +
              plane.z * furthest.z +
              plane.w <
          0) {
        return false;
      }
    }
    return true;
  }

  /// How many buckets a split is looked for in.
  ///
  /// Twelve rather than trying every position: the best of twelve is within a
  /// percent or two of the best of all of them on any real scene, and it is
  /// the difference between a build that is linear in the number of things
  /// and one that is quadratic.
  static const int _buckets = 12;

  /// Builds one node over `volumes[from..to)` and returns its index.
  static int _build(
    List<_Node> nodes,
    List<OrbisVolume> volumes,
    int from,
    int to,
    int leafSize,
  ) {
    var box = volumes[from].bounds;
    var centroids = OrbisBounds.at(volumes[from].bounds.centre);
    for (var i = from + 1; i < to; i++) {
      box = box.union(volumes[i].bounds);
      centroids = centroids.union(OrbisBounds.at(volumes[i].bounds.centre));
    }

    final count = to - from;
    if (count <= leafSize) {
      nodes.add(_Node.leaf(box, from, count));
      return nodes.length - 1;
    }

    // The axis the things are most spread along. Splitting across the
    // narrowest one makes two boxes that overlap almost entirely, which is a
    // tree that has to open both halves for every query.
    final spread = centroids.size;
    var axis = 0;
    if (spread.y > spread.x) axis = 1;
    if (spread.z > spread[axis]) axis = 2;

    var middle = from + count ~/ 2;
    final low = centroids.minimum[axis];
    final high = centroids.maximum[axis];

    if (high - low > 1e-9) {
      final counts = List<int>.filled(_buckets, 0);
      final boxes = List<OrbisBounds?>.filled(_buckets, null);
      final scale = _buckets / (high - low);

      int bucketOf(OrbisVolume volume) {
        final at = ((volume.bounds.centre[axis] - low) * scale).floor();
        return at < 0 ? 0 : (at >= _buckets ? _buckets - 1 : at);
      }

      for (var i = from; i < to; i++) {
        final bucket = bucketOf(volumes[i]);
        counts[bucket]++;
        boxes[bucket] = boxes[bucket] == null
            ? volumes[i].bounds
            : boxes[bucket]!.union(volumes[i].bounds);
      }

      // The cost of cutting after each bucket: how much area is on each side,
      // weighted by how many things are on it. What a query pays is the
      // chance of having to open a box times what is in it.
      var bestCost = double.infinity;
      var bestCut = -1;
      for (var cut = 0; cut < _buckets - 1; cut++) {
        OrbisBounds? left;
        var leftCount = 0;
        for (var i = 0; i <= cut; i++) {
          if (boxes[i] == null) continue;
          left = left == null ? boxes[i] : left.union(boxes[i]!);
          leftCount += counts[i];
        }
        OrbisBounds? right;
        var rightCount = 0;
        for (var i = cut + 1; i < _buckets; i++) {
          if (boxes[i] == null) continue;
          right = right == null ? boxes[i] : right.union(boxes[i]!);
          rightCount += counts[i];
        }
        if (leftCount == 0 || rightCount == 0) continue;

        final cost = left!.area * leftCount + right!.area * rightCount;
        if (cost < bestCost) {
          bestCost = cost;
          bestCut = cut;
        }
      }

      if (bestCut >= 0) {
        // Partitioned in place, the way quicksort does it: everything below
        // the cut to the left, everything above to the right, no second list.
        var write = from;
        for (var i = from; i < to; i++) {
          if (bucketOf(volumes[i]) <= bestCut) {
            final swap = volumes[write];
            volumes[write] = volumes[i];
            volumes[i] = swap;
            write++;
          }
        }
        // A partition that moved everything to one side is not a split. Falls
        // back to halving, which always makes progress and so always ends.
        if (write > from && write < to) middle = write;
      }
    }

    // Reserved before the children so the branch keeps its place in the list:
    // the children are appended by the recursion and would otherwise take it.
    final index = nodes.length;
    nodes.add(_Node.leaf(box, from, count));
    final left = _build(nodes, volumes, from, middle, leafSize);
    final right = _build(nodes, volumes, middle, to, leafSize);
    nodes[index] = _Node.branch(box, left, right);
    return index;
  }
}

class _Node {
  _Node.leaf(this.bounds, this.first, this.count) : left = -1, right = -1;
  _Node.branch(this.bounds, this.left, this.right) : first = 0, count = 0;

  OrbisBounds bounds;

  /// A leaf's slice of the volume list.
  final int first;
  final int count;

  /// A branch's children, as indices into the node list.
  final int left;
  final int right;

  bool get isLeaf => left < 0;
}
