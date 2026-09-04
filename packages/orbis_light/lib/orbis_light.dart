/// Lights described the way an artist states them.
///
/// Power in watts, sizes in metres, angles in degrees — the units on a real
/// fixture and in the tool a scene was authored in. The conversion to the
/// photometric units a renderer works in happens in one place, so changing
/// renderer does not mean re-authoring every light.
library;

export 'src/light.dart'
    show AreaShape, Light, LightType, RendererLight, RendererLightKind;
export 'src/units.dart' show Photometry;
