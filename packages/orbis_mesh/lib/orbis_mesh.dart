/// Building and editing geometry in the editor.
///
/// Somebody blocking out a level needs boxes, stairs and a doorway before they
/// need a modelling package, and the round trip through one — export, import,
/// find it does not fit, go back — is where the time goes. This is the part
/// that is worth having in the editor: parametric shapes to start from, and
/// the handful of operations that turn one into something that was not a shape
/// any more.
///
/// It is not a modelling package and is not trying to become one. There is no
/// sculpting, no retopology and no UV editor; what there is is the geometry a
/// level is made of.
///
/// Nothing here knows about Flutter, the renderer or the editor. A mesh is
/// positions and faces; [Triangles] is what a graphics card takes; and `toGlb`
/// writes the file the renderer already loads, so a shape made here goes
/// through exactly the path a model exported from Blender does.
library;

export 'src/actions.dart' show MeshActions, MeshEdge, edgeOf;
export 'src/cut.dart'
    show
        AlongEdge,
        AtCorner,
        InsideFace,
        MeshCut,
        OnFace,
        flattenFace,
        pointInsideOutline,
        signedLoopArea;
export 'src/drawn.dart'
    show
        PolyShape,
        closesOutline,
        distanceToSegment,
        isNewPoint,
        outlineCrosses,
        signedAreaOf,
        turnBetween;
export 'src/edits.dart' show MeshEdits, MeshHandles, MeshShell;
export 'src/export.dart'
    show MeshExport, MeshFormat, Written, boundsOfGlb;
export 'src/mesh.dart' show Face, Mesh;
export 'src/shapes.dart' show Shape, ShapeKind;
export 'src/uv.dart' show FaceUv, UvFit;
export 'src/uv_edits.dart' show MeshUvs;
export 'src/triangles.dart'
    show GlbMaterial, MeshGlb, MeshTriangles, Triangles, angleBetween, cutUp;
