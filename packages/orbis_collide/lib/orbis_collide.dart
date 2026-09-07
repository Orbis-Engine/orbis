/// Shapes, raycasts and overlap tests — in three dimensions and in two.
///
/// Queries rather than a simulation. Nothing here integrates anything or
/// resolves anything beyond pushing two overlapping bodies apart: what it
/// answers is where things are and what they are touching, which is what a
/// character controller, a pickup, a line of sight and a mouse click all
/// actually ask.
///
/// **Two names clash with `vector_math`**, which almost everything here also
/// imports: `Sphere` and `Ray`. Theirs are bare geometry with a couple of
/// intersection tests; these carry the query surface below. Import this one
/// and hide those:
///
/// ```dart
/// import 'package:vector_math/vector_math_64.dart' hide Ray, Sphere;
/// ```
///
/// Said here rather than left to be discovered, because the error a clash
/// produces names neither package as the one to change.
///
/// The shape list is short and stays short. Every shape here has a
/// closed-form nearest point to a point, which is what makes the queries
/// exact rather than iterative — the moment one without it is added, every
/// query grows a numerical path beside the exact one.
library;

export 'src/flat.dart'
    show
        Body,
        Circle,
        Collision,
        Hitbox,
        Rect2,
        Rectangle,
        Touch,
        World2,
        touching;
export 'src/queries.dart'
    show Broadphase, Hit, Layers, Ray, raycast, raycastAll, raycastFirst;
export 'src/shapes.dart'
    show
        Aabb,
        Box,
        Capsule,
        Contact,
        Shape,
        Sphere,
        contact,
        nearestBetweenSegments,
        nearestOnSegment,
        overlaps;
