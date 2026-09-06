import 'package:vector_math/vector_math_64.dart';

import 'blend.dart';
import 'camera_state.dart';
import 'virtual_camera.dart';

/// Chooses which shot is live, and gets there.
///
/// The single point where "which camera" is decided. Game code raises and
/// lowers priorities and never touches a transform, which is what stops two
/// systems fighting over the camera — the failure that makes cameras the
/// worst part of most codebases.
class CameraBrain {
  CameraBrain({double aspect = 16 / 9, BlendTable? blends})
    : _aspect = aspect,
      blends = blends ?? BlendTable();

  double _aspect;

  /// Frame width over height. Affects composition, since a dead zone is a
  /// fraction of the frame and the frame is not square.
  double get aspect => _aspect;

  /// Anything that is not a real ratio is ignored rather than stored.
  ///
  /// A host reads this off its own surface, and a surface that has not been
  /// laid out yet is zero by zero — which is not a small number, it is a NaN.
  /// One of those reaches the projection, comes back out as a rotation, and
  /// is then damped towards on the next frame from a value that is already
  /// NaN. Nothing recovers: the camera is pointed nowhere for the rest of the
  /// run, from one frame during startup.
  ///
  /// Refusing it here rather than asking every host to check is the only
  /// version of this that stays fixed.
  set aspect(double value) {
    if (value.isFinite && value > 0) _aspect = value;
  }

  final BlendTable blends;

  final List<VirtualCamera> _cameras = [];

  /// What the real camera should be doing this frame.
  final CameraState state = CameraState();

  VirtualCamera? _live;
  CameraState? _blendFrom;
  Blend _blend = const Blend.cut();
  double _blendElapsed = 0;
  double _time = 0;

  /// The camera currently in charge, or null if none is enabled.
  VirtualCamera? get live => _live;

  /// Between zero and one while a transition is running.
  double get blendProgress => _blendFrom == null
      ? 1
      : (_blendElapsed / _blend.duration).clamp(0.0, 1.0);

  bool get isBlending => _blendFrom != null;

  List<VirtualCamera> get cameras => List.unmodifiable(_cameras);

  void add(VirtualCamera camera) {
    _cameras.add(camera);
    camera.snap(aspect: aspect);
  }

  void remove(VirtualCamera camera) {
    _cameras.remove(camera);
    if (_live == camera) _live = null;
  }

  /// The enabled camera with the highest priority.
  ///
  /// Ties go to the one added first, so a scene's ordering is a tiebreak
  /// rather than a coin toss — the same scene always produces the same shot.
  VirtualCamera? _choose() {
    VirtualCamera? best;
    for (final camera in _cameras) {
      if (!camera.enabled) continue;
      if (best == null || camera.priority > best.priority) best = camera;
    }
    return best;
  }

  void update(double delta) {
    _time += delta;

    // Every camera keeps solving, live or not. A camera that only started
    // thinking when it became live would cut in from wherever it was left,
    // which is the jarring transition this whole design exists to avoid.
    for (final camera in _cameras) {
      if (camera.enabled) camera.solve(delta, aspect: aspect);
    }

    final wanted = _choose();
    if (wanted != _live) {
      // Blending from the current output rather than from the outgoing
      // camera, so interrupting a transition continues from what is on screen
      // instead of jumping back to where the last one started.
      final blend = blends.between(_live?.name, wanted?.name);
      if (_live != null && wanted != null && blend.duration > 0) {
        _blendFrom = state.clone();
        _blend = blend;
        _blendElapsed = 0;
      } else {
        _blendFrom = null;
      }
      _live = wanted;
    }

    final target = _live?.state;
    if (target == null) return;

    final from = _blendFrom;
    if (from == null) {
      state
        ..position = target.position.clone()
        ..rotation = target.rotation.clone()
        ..lens = target.lens;
    } else {
      _blendElapsed += delta;
      final t = _blend.ease(_blendElapsed / _blend.duration);
      final blended = CameraState.lerp(from, target, t);
      state
        ..position = blended.position
        ..rotation = blended.rotation
        ..lens = blended.lens;
      if (t >= 1) _blendFrom = null;
    }

    _applyNoise();
  }

  /// Handheld movement, added last so it disturbs the finished frame rather
  /// than the framing decision — a composer should not fight a wobble.
  void _applyNoise() {
    final noise = _live?.noise;
    if (noise == null) return;

    final offset = noise.positionAt(_time);
    state.position += rotateVector(state.rotation, offset);

    final wobble = noise.rotationAt(_time) * (3.14159265358979 / 180);
    state.rotation =
        state.rotation *
        (Quaternion.euler(wobble.y, wobble.x, wobble.z)..normalize());
  }

  /// Cuts to whatever should be live, with no transition.
  void snap() {
    for (final camera in _cameras) {
      if (camera.enabled) camera.snap(aspect: aspect);
    }
    _live = _choose();
    _blendFrom = null;
    final target = _live?.state;
    if (target == null) return;
    state
      ..position = target.position.clone()
      ..rotation = target.rotation.clone()
      ..lens = target.lens;
  }
}
