# Changelog

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
