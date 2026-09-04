/// Cameras as shots rather than as objects.
///
/// A scene holds as many virtual cameras as it has situations, each already
/// framed. Game code raises and lowers their priorities; the engine works out
/// where the real camera should be and blends between them. Nothing outside
/// this library moves a camera transform, which is what stops two systems
/// fighting over it.
library;

export 'src/aim.dart'
    show
        CameraAim,
        ComposerAim,
        HardLookAt,
        PovAim,
        ScreenPoint,
        StaticAim,
        project,
        rotationPlacing;
export 'src/blend.dart' show Blend, BlendStyle, BlendTable;
export 'src/body.dart'
    show
        CameraBody,
        FollowBinding,
        FollowBody,
        FramingBody,
        OrbitBody,
        StaticBody;
export 'src/brain.dart' show CameraBrain;
export 'src/camera_state.dart'
    show
        CameraState,
        CameraTarget,
        FixedTarget,
        lookRotation,
        rotateVector,
        slerpShortest;
export 'src/damping.dart' show damp, dampingFactor;
export 'src/lens.dart' show Lens;
export 'src/noise.dart' show CameraNoise;
export 'src/virtual_camera.dart' show VirtualCamera;
