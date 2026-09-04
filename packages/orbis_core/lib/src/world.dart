import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart' as native;

/// What a component is made of, so a column can be handed back as the right
/// typed list rather than as bytes the caller has to reinterpret.
enum ComponentKind {
  float32(4),
  float64(8),
  int32(4),
  uint32(4),
  int64(8),
  uint8(1);

  const ComponentKind(this.bytesPerElement);

  final int bytesPerElement;
}

/// A registered component type.
class ComponentType {
  const ComponentType({
    required this.id,
    required this.name,
    required this.kind,
    required this.arity,
  });

  final int id;
  final String name;
  final ComponentKind kind;

  /// How many elements one component holds — 3 for a position, 16 for a
  /// matrix, 1 for a scalar.
  final int arity;

  int get byteSize => kind.bytesPerElement * arity;

  @override
  String toString() => 'ComponentType($name, ${kind.name} x$arity)';
}

/// Thrown when a handle is used after the entity it named was destroyed.
class DeadEntityError extends StateError {
  DeadEntityError(int entity)
      : super('Entity $entity is not alive. Its slot may have been reused; '
            'generational handles make that detectable rather than silent.');
}

/// One run of entities that all carry the queried components.
///
/// The columns are windows onto the engine's own memory. Reading and writing
/// them touches no boundary and copies nothing — which is the whole reason a
/// system asks for a chunk instead of asking about an entity.
///
/// A chunk is valid until the next structural change to the world: creating or
/// destroying an entity, or adding or removing a component. Those move rows
/// between archetypes, and a view taken before one is a view onto memory that
/// has since been reused. Finish the loop, then mutate.
class Chunk {
  Chunk._(this._query, this._index, this._types, this.length);

  final Pointer<native.OrbisQueryStruct> _query;
  final int _index;
  final List<ComponentType> _types;

  /// How many entities this run holds.
  final int length;

  /// The entity handles, in the same order as every column.
  Uint64List get entities =>
      native.queryChunkEntities(_query, _index).asTypedList(length);

  Pointer<Void> _column(int slot) {
    final pointer = native.queryChunkColumn(_query, _index, slot);
    if (pointer == nullptr) {
      throw RangeError('No column at slot $slot for this query.');
    }
    return pointer;
  }

  int _elements(int slot) => length * _types[slot].arity;

  /// A column of float32 components, laid out end to end: entity `i`'s
  /// elements start at `i * arity`.
  Float32List float32(int slot) {
    _expect(slot, ComponentKind.float32);
    return _column(slot).cast<Float>().asTypedList(_elements(slot));
  }

  Float64List float64(int slot) {
    _expect(slot, ComponentKind.float64);
    return _column(slot).cast<Double>().asTypedList(_elements(slot));
  }

  Int32List int32(int slot) {
    _expect(slot, ComponentKind.int32);
    return _column(slot).cast<Int32>().asTypedList(_elements(slot));
  }

  Uint32List uint32(int slot) {
    _expect(slot, ComponentKind.uint32);
    return _column(slot).cast<Uint32>().asTypedList(_elements(slot));
  }

  Int64List int64(int slot) {
    _expect(slot, ComponentKind.int64);
    return _column(slot).cast<Int64>().asTypedList(_elements(slot));
  }

  /// The raw bytes of a column, for a component with no natural element type.
  Uint8List bytes(int slot) => _column(slot)
      .cast<Uint8>()
      .asTypedList(length * _types[slot].byteSize);

  /// Every component the entities in this run carry, including ones the query
  /// did not ask for.
  ///
  /// The whole run shares one component set, so this is answered once per run
  /// rather than once per entity — which is what lets replication decide what
  /// to send without walking the world.
  List<int> get componentIds {
    final count = native.queryChunkComponents(_query, _index, nullptr, 0);
    if (count == 0) return const [];
    return using((arena) {
      final buffer = arena<Uint32>(count);
      native.queryChunkComponents(_query, _index, buffer, count);
      return List<int>.unmodifiable(buffer.asTypedList(count));
    });
  }

  /// The raw bytes of a component this run carries, whether or not the query
  /// named it. Null when the component is absent.
  Uint8List? bytesOfComponent(ComponentType type) {
    final pointer =
        native.queryChunkComponentColumn(_query, _index, type.id);
    if (pointer == nullptr) return null;
    return pointer.cast<Uint8>().asTypedList(length * type.byteSize);
  }

  /// A float32 column addressed by component rather than by slot.
  Float32List? float32OfComponent(ComponentType type) {
    final pointer =
        native.queryChunkComponentColumn(_query, _index, type.id);
    if (pointer == nullptr) return null;
    return pointer.cast<Float>().asTypedList(length * type.arity);
  }

  void _expect(int slot, ComponentKind kind) {
    if (_types[slot].kind != kind) {
      throw ArgumentError('Slot $slot is ${_types[slot].kind.name}, '
          'not ${kind.name}.');
    }
  }
}

/// A standing question about which entities carry a set of components.
///
/// Queries are worth keeping across frames: the matching archetypes are cached
/// and only recomputed when the world's structure actually changes.
class Query {
  Query._(this._query, this.types);

  final Pointer<native.OrbisQueryStruct> _query;

  /// The queried components, in slot order.
  final List<ComponentType> types;

  bool _disposed = false;

  /// The matching runs. Iterating recomputes the match once, at the start.
  Iterable<Chunk> get chunks sync* {
    _checkAlive();
    final count = native.queryChunkCount(_query);
    for (var i = 0; i < count; i++) {
      final length = native.queryChunkLength(_query, i);
      if (length == 0) continue;
      yield Chunk._(_query, i, types, length);
    }
  }

  /// How many entities the query currently matches.
  int get entityCount {
    _checkAlive();
    var total = 0;
    final count = native.queryChunkCount(_query);
    for (var i = 0; i < count; i++) {
      total += native.queryChunkLength(_query, i);
    }
    return total;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    native.queryDestroy(_query);
  }

  void _checkAlive() {
    if (_disposed) throw StateError('This Query has been disposed.');
  }
}

/// An entity-component world.
///
/// Dart owns the lifetime and drives the frame; the storage and the systems
/// that run per entity live in C++. See [Query] for the reason that split is
/// worth the boundary.
class World {
  World() : _world = native.worldCreate() {
    if (_world == nullptr) {
      throw StateError('Could not create an Orbis world.');
    }
  }

  Pointer<native.OrbisWorldStruct> _world;

  bool get isDisposed => _world == nullptr;

  /// Increments on every structural change. A view taken at one version is not
  /// safe to use at another.
  int get version => native.worldVersion(_alive);

  int get entityCount => native.entityCount(_alive);

  int get componentCount => native.componentCount(_alive);

  /// Seconds accumulated across [tick] calls.
  double get elapsed => native.worldElapsed(_alive);

  /// Registers a component type, or returns the existing one if [name] was
  /// already registered with this exact layout.
  ComponentType registerComponent(
    String name, {
    required ComponentKind kind,
    int arity = 1,
  }) {
    final size = kind.bytesPerElement * arity;
    final id = using((arena) => native.componentRegister(
          _alive,
          name.toNativeUtf8(allocator: arena).cast<Char>(),
          size,
          kind.bytesPerElement,
        ));
    if (id == 0) {
      throw ArgumentError(
          'Component "$name" is already registered with a different layout.');
    }
    return ComponentType(id: id, name: name, kind: kind, arity: arity);
  }

  int createEntity() => native.entityCreate(_alive);

  void destroyEntity(int entity) => native.entityDestroy(_alive, entity);

  bool isAlive(int entity) => native.entityAlive(_alive, entity);

  /// Adds [type] to [entity]. Without a [value] the component starts zeroed.
  void add(int entity, ComponentType type, [TypedData? value]) {
    if (!isAlive(entity)) throw DeadEntityError(entity);

    final added = value == null
        ? native.entityAdd(_alive, entity, type.id, nullptr)
        : using((arena) {
            final buffer = arena<Uint8>(type.byteSize);
            buffer.asTypedList(type.byteSize).setAll(
                  0,
                  value.buffer.asUint8List(value.offsetInBytes, type.byteSize),
                );
            return native.entityAdd(
                _alive, entity, type.id, buffer.cast<Void>());
          });

    if (!added) {
      throw StateError('Entity $entity already has ${type.name}.');
    }
  }

  bool remove(int entity, ComponentType type) =>
      native.entityRemove(_alive, entity, type.id);

  bool has(int entity, ComponentType type) =>
      native.entityHas(_alive, entity, type.id);

  /// A view of one entity's component, or null if it does not have it.
  ///
  /// Convenient, and the slow path by construction: a system touching many
  /// entities should take a [Query] instead, which costs one crossing rather
  /// than one per entity.
  Float32List? float32Of(int entity, ComponentType type) {
    final pointer = native.entityGet(_alive, entity, type.id);
    if (pointer == nullptr) return null;
    return pointer.cast<Float>().asTypedList(type.arity);
  }

  Uint8List? bytesOf(int entity, ComponentType type) {
    final pointer = native.entityGet(_alive, entity, type.id);
    if (pointer == nullptr) return null;
    return pointer.cast<Uint8>().asTypedList(type.byteSize);
  }

  /// A standing query over every entity carrying all of [types].
  ///
  /// The caller owns it and should keep it rather than rebuild it per frame.
  Query query(List<ComponentType> types) {
    final pointer = using((arena) {
      final ids = arena<Uint32>(types.length);
      for (var i = 0; i < types.length; i++) {
        ids[i] = types[i].id;
      }
      return native.queryCreate(_alive, ids, types.length);
    });
    return Query._(pointer, List.unmodifiable(types));
  }

  /// Runs the native systems once. Dart systems run around this, over views.
  void tick(double delta) => native.worldTick(_alive, delta);

  void dispose() {
    if (_world == nullptr) return;
    native.worldDestroy(_world);
    _world = nullptr;
  }

  Pointer<native.OrbisWorldStruct> get _alive {
    if (_world == nullptr) throw StateError('This World has been disposed.');
    return _world;
  }
}
