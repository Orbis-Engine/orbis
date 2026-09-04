/// The Orbis engine core.
///
/// An archetype entity-component store in C++, reached over a C ABI. Dart owns
/// the frame and the lifetime; component data is exposed as views onto the
/// engine's own memory, so a system crosses the boundary once per tick rather
/// than once per entity.
library;

export 'src/world.dart'
    show
        Chunk,
        ComponentKind,
        ComponentType,
        DeadEntityError,
        Query,
        TransformComponents,
        World,
        transform;
