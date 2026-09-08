# Changelog

## 0.9.0

- `Toggle` takes a `note` and an `enabled`, and the Bistro examples use it
  instead of `SwitchListTile`. A ListTile paints onto the nearest Material
  ancestor and reports itself broken when something opaque sits in between,
  which the settings panel is — so four switches were reporting an error on
  every frame they were on screen, and an editor showing the Bistro filled its
  console with them.

## 0.8.0

- A blending example: three ground panels that are the same two surfaces and
  the same mask, differing only in what the mask is taken to mean. The point
  is visible with the grass slider at half — the first two panels are half
  grass everywhere, and the third has grass in the mortar and stone on the
  stones. Its textures are generated rather than shipped, and the height it
  blends by is the cobble relief itself, which is what stops grass appearing
  where the stones are.

## 0.7.0

- The walk no longer goes through walls. The route is searched rather than
  chosen — a breadth-first flood of the open ground at half a metre, with the
  curve then checked at six hundred points for half a metre of clearance.
  Both earlier paths clipped: the polyline at 18 samples in 100, the curve
  through it at 17.

## 0.6.0

- The walk follows a Catmull-Rom curve rather than a polyline, so both where
  the camera is and where it points change smoothly the whole way. Measured
  at a peak of 84 degrees a second with no discontinuity across the cycle;
  the polyline turned instantly at every one of its waypoints.
- Walked at constant speed rather than constant parameter, because a spline's
  parameter is not its arc length.

## 0.5.0

- The walk turns round instead of reversing. Four phases on a loop — down the
  street, turn, back, turn — with the turn eased in and out so it starts and
  stops at zero speed.
- Temporal anti-aliasing, screen-space reflections, ACES tone mapping, contact
  shadows and stronger ambient occlusion.

## 0.4.0

- A prefiltered environment, built by `cmgen` when the scene is fetched. The
  flat one-band ambient is a placeholder by its own admission; this is a
  photograph of a real sky, with the reflection in its mip chain and the
  diffuse in its harmonics. It is most of the difference between a render and
  a photograph.
- The exterior walks the street instead of orbiting it, at a walking pace,
  with a bob and a slow look around. The route comes from an occupancy map of
  the scene rather than a guess — the first attempt followed the street lamps
  and walked through the restaurant, because the lamps stand on the pavement
  with the building between them.

## 0.3.0

- The Bistro's materials are repaired on fetch. All 132 omitted
  `metallicFactor`, and glTF's default is 1.0 — so every cobblestone, wall
  and awning was rendering as solid metal, which has no diffuse response and
  goes black whatever the lighting does.
- Night is lit like night: the moon at a few lux rather than 900, which was
  three thousand times a real one and flattened the whole street.
- Sliders for moonlight and film speed, four-sample anti-aliasing, ambient
  occlusion, and a shadow distance — `OrbisShadows.distance` defaults to 0,
  which leaves the shadow map covering nothing.

## 0.2.0

- Two Bistro examples, exterior and interior, lighting the Amazon Lumberyard
  Bistro (ORCA, CC BY 4.0). The first example built on somebody else's art,
  with reference images to judge the lighting against, and by a wide margin
  the heaviest thing here to measure a frame on.
- Fetched by `tool/fetch_bistro.sh`, which also derives the hundred-odd light
  positions from the scene's own emissive geometry — the conversion carries no
  `KHR_lights_punctual`, so the fixtures are ours to place.

## 0.1.0

- First cut of `orbis_examples`. Pre-alpha: everything is subject to change.
