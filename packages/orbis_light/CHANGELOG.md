# Changelog

## 0.2.0

- **An area light converts to a real one.** `toRenderer()` gave back a point
  at the shape's centre, because when it was written no renderer this targets
  had an area light. One does now, so a square and a rectangle arrive as
  themselves and `approximated` is false for them.

  A disk and an ellipse are squared off to a rectangle of the *same area* —
  not the same bounding box, which is over a quarter too big — and still say
  `approximated`, because the closed form the shading uses is for polygons.
  The light they throw is right; the outline reflected in something
  mirror-smooth is not.

## 0.1.0

- First cut of `orbis_light`. Pre-alpha: everything is subject to change.
