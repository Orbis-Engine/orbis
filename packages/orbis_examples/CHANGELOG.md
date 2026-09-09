# Changelog

## 0.17.0

- **A new example, Bounced light.** Two coloured walls facing each other across
  a pale floor, with white boxes between them — the arrangement every renderer
  has been photographed in since Cornell in 1984, because it is the one that
  shows bounced light plainly. The sky's ambient is turned right down on
  purpose: ambient fills shadows evenly and for free, and a room where it does
  that is a room where a second bounce has nothing left to add.

## 0.16.0

- Blocks stops taking itself apart at the draw distance. It fades nothing —
  a solid world has no intermediate shape a cube can hold without tearing it —
  and pairs the range with fog worked out from that range, so the boundary is
  reached inside opaque air rather than in plain sight.

## 0.15.0

- Blocks fades its distance by shrinking rather than sinking, which is what
  stops the far side of the world turning into coloured plates hanging in the
  sky. A block sits on other blocks, not on the ground, so sinking one to its
  own bottom left it exactly where it was.

- The Runner supplies its own camera and cannot be orbited. A runner is
  followed, not looked at: its world only exists in a wedge in front of the
  character — the track is laid one way, there is nothing behind it, and the
  scenery is drawn to a range measured from the camera — so orbiting round to
  the side, or under the ground plane, showed the empty half, with hazards and
  coins over a horizon and the road they belong to out of frame. It leans with
  the runner as it weaves, because a camera welded to the centre line makes
  that read as the world sliding sideways rather than the character moving.

## 0.14.0

- An example can say what it needs that the repository does not carry, and
  under what terms. The Bistro scenes are somebody else's art and hundreds of
  megabytes of it, so they are fetched rather than committed — and until they
  are, the example drew a placeholder and explained itself to somebody who
  then had to go and find a shell script. A description rather than a
  download: the example says what it wants and which command brings it, and
  whatever is showing it decides whether that becomes a button.

## 0.13.0

- Blocks generates a world rather than a heightfield. Four climate fields
  instead of one height: continentalness decides how far above the sea a
  region sits and is what makes coasts, erosion decides how much the land is
  allowed to vary there, and temperature and humidity decide what grows.
  Height is continentalness through a curve, scaled by erosion — the curve
  matters, because a straight line gives as much land at every altitude and a
  real world has a lot of coast, a lot of gentle ground and a little that is
  high. Surface rules by biome give beaches, deserts, a snow line that moves
  with temperature, and trees where it is warm and damp enough. The shape of
  that is Pebble's approach read as a reference and written again; none of its
  code is here.

- The runner's buildings stood in the road. The track is 4.6 either side of
  the middle and the scenery started at 4.2, so a tower could be in the third
  lane — which is what "it keeps generating really long objects" was: a
  building with the road running through it. They also varied only in height,
  all of them the same 1.8 across and up to eleven high, which is a six-to-one
  slab; a row of those beside the camera is a wall with slots in it rather
  than a city. And there is ground under them now, because a tower with
  nothing beneath it reads as a bug rather than as distance.

- Blocks is a world you are in rather than one you look at. WASD and space to
  walk and jump, drag to look, click to dig and right-click to put a block
  back. The world is a grid of bytes now instead of a list of what to draw —
  the moment somebody can dig, "what is at this point" is asked constantly, by
  the body falling and by every ray under the crosshair, and a grid answers
  that in one lookup rather than sixty thousand comparisons. Only blocks with
  air beside them are drawn, which in a world of solid hills is about an
  eighth of them.

## 0.12.1

- The runner's black shapes were shadows. Three things at once: the track was
  a twentieth of full brightness, so a shadow on it was simply black; the sky
  was dim enough that a shadowed surface got almost nothing; and the coins,
  which are thin discs, cast hard-edged rectangles onto the road with nothing
  above them to explain the shape. A lighter road, more sky, and coins that
  float without casting.

## 0.12.0

- Two whole small worlds rather than one technique each.

  **Blocks**: a generated landscape of sixty thousand cubes with grass, stone,
  snow and lakes, in one buffer uploaded when the world changes and not again.
  Only the block somebody can see is built — a column of height twelve is one
  cube, not twelve — and a column fills down to its lowest neighbour so a
  cliff is a wall rather than floating tops.

  **Runner**: a track that never ends and never allocates a piece of one. A
  fixed set of hazards, coins and roadside blocks laid out once; what changes
  is how far the world has come, and a piece that goes behind the camera comes
  round the front by a modulo. The runner does not run — it stays where it is
  and the world moves past.
## 0.11.0

- `Example` carries a `note`, so any example can say what the renderer told it
  about the scene. That report used to reach one example and be dropped for
  all the others, which is why a Bistro whose files had never been downloaded
  showed a grey placeholder cube and said nothing — and a scene that draws the
  wrong thing in silence reads as the engine being broken rather than as a
  file being absent.

## 0.10.0

- The Bistro exterior no longer judders. It was asking for four shadow
  cascades of two thousand square and contact shadows, which came to fifty-five
  milliseconds a frame with the camera looking down the street — twelve frames
  a second, arriving unevenly, which is what a judder is. Three cascades of a
  thousand and no contact shadows is within a millisecond and a half of having
  no shadows at all, and the walk now runs at a hundred and twenty frames a
  second with one percent unevenness. Resolution is adaptive as well, so what
  is in view changing between a wall and a hundred and seventy metres of street
  changes the pixel count rather than the frame rate.

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
