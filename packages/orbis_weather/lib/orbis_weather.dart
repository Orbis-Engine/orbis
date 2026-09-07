/// What the air is doing, and what is above it.
///
/// Weather as a set of facts rather than as a set of renderer parameters: a
/// condition, how far through a change to it the scene is, where the sun
/// stands at this hour, how much light that puts on the ground, and what a
/// camera has to be set to for any of it to be visible.
///
/// Nothing here draws anything, and nothing here knows what a renderer is.
/// That is the whole point of it being its own package: the mapping from these
/// facts to a particular renderer's description belongs to whoever is doing
/// the drawing, and a scene running on a console has the same weather as one
/// running in the editor.
///
/// It has no Flutter in it either, for the same reason.
library;

export 'src/sky.dart' show CameraExposure, CelestialBody, DayCycle, SkyState;
export 'src/strike.dart' show Strike;
export 'src/weather.dart' show CloudKind, WeatherCondition, WeatherState;
