import 'package:vector_math/vector_math_64.dart';

import 'aim.dart';
import 'body.dart';
import 'camera_state.dart';
import 'lens.dart';
import 'noise.dart';

/// A shot, not a camera.
///
/// There is one real camera; these describe what it should be doing. A scene
/// holds as many as it has situations, each already framed, and the engine
/// picks between them — which is why cutting to a different angle is raising a
/// number rather than moving anything.
class VirtualCamera {
  VirtualCamera({
    required this.name,
    this.priority = 10,
    this.enabled = true,
    this.lens = const Lens(),
    this.follow,
    this.lookAt,
    CameraBody? body,
    CameraAim? aim,
    this.noise,
    Vector3? position,
    Quaternion? rotation,
  }) : body = body ?? StaticBody(position ?? Vector3.zero()),
       aim = aim ?? StaticAim(rotation ?? Quaternion.identity()),
       state = CameraState(
         position: position ?? Vector3.zero(),
         rotation: rotation ?? Quaternion.identity(),
         lens: lens,
       );

  /// Used in blend rules and in the editor. Worth being a real name.
  final String name;

  /// The highest priority among the enabled cameras is the one in use.
  ///
  /// A number rather than a stack, so a camera can be armed long before it
  /// matters and take over the moment its situation arises — a danger camera
  /// that raises itself when the player is spotted, without anything having to
  /// know it exists.
  int priority;

  bool enabled;

  Lens lens;

  /// What the camera moves with.
  CameraTarget? follow;

  /// What it points at. Often, but not always, the same thing.
  CameraTarget? lookAt;

  CameraBody body;
  CameraAim aim;

  /// Optional handheld movement, applied after framing so it never fights it.
  CameraNoise? noise;

  /// Where this camera would be if it were live. Kept up to date whether or
  /// not it is, so cutting to it does not start from a stale position.
  CameraState state;

  /// Advances this camera's own solution by [delta] seconds.
  void solve(double delta, {required double aspect}) {
    state.lens = lens;
    state.position = body.solve(state.position, follow, delta);
    state.rotation = aim.solve(
      state.rotation,
      state.position,
      lookAt,
      lens: lens,
      aspect: aspect,
      delta: delta,
    );
  }

  /// Puts the camera exactly where it wants to be, with no lag.
  ///
  /// For the first frame after a camera is enabled, and for a cut: damping is
  /// about how a camera catches up to something, and there is nothing to catch
  /// up to when it has only just started existing.
  void snap({required double aspect}) {
    // A very large step drives every damping term to essentially one, which is
    // the definition of arriving immediately.
    solve(1e6, aspect: aspect);
  }
}
