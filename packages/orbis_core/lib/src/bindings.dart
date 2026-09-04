// Raw FFI declarations for the core's C ABI. Nothing here interprets a result
// or owns a lifetime — see world.dart for that.

import 'dart:ffi';

const String kOrbisCoreAsset = 'package:orbis_core/orbis_core';

final class OrbisWorldStruct extends Opaque {}

final class OrbisQueryStruct extends Opaque {}

@Native<Pointer<OrbisWorldStruct> Function()>(
    symbol: 'orbis_world_create', assetId: kOrbisCoreAsset)
external Pointer<OrbisWorldStruct> worldCreate();

@Native<Void Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_world_destroy', assetId: kOrbisCoreAsset)
external void worldDestroy(Pointer<OrbisWorldStruct> world);

@Native<Uint64 Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_world_version', assetId: kOrbisCoreAsset)
external int worldVersion(Pointer<OrbisWorldStruct> world);

@Native<Uint32 Function(Pointer<OrbisWorldStruct>, Pointer<Char>, Uint32, Uint32)>(
    symbol: 'orbis_component_register', assetId: kOrbisCoreAsset)
external int componentRegister(
    Pointer<OrbisWorldStruct> world, Pointer<Char> name, int size, int alignment);

@Native<Uint32 Function(Pointer<OrbisWorldStruct>, Pointer<Char>)>(
    symbol: 'orbis_component_lookup', assetId: kOrbisCoreAsset)
external int componentLookup(Pointer<OrbisWorldStruct> world, Pointer<Char> name);

@Native<Uint32 Function(Pointer<OrbisWorldStruct>, Uint32)>(
    symbol: 'orbis_component_size', assetId: kOrbisCoreAsset)
external int componentSize(Pointer<OrbisWorldStruct> world, int component);

@Native<Uint32 Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_component_count', assetId: kOrbisCoreAsset)
external int componentCount(Pointer<OrbisWorldStruct> world);

@Native<Uint64 Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_entity_create', assetId: kOrbisCoreAsset)
external int entityCreate(Pointer<OrbisWorldStruct> world);

@Native<Void Function(Pointer<OrbisWorldStruct>, Uint64)>(
    symbol: 'orbis_entity_destroy', assetId: kOrbisCoreAsset)
external void entityDestroy(Pointer<OrbisWorldStruct> world, int entity);

@Native<Bool Function(Pointer<OrbisWorldStruct>, Uint64)>(
    symbol: 'orbis_entity_alive', assetId: kOrbisCoreAsset)
external bool entityAlive(Pointer<OrbisWorldStruct> world, int entity);

@Native<Uint32 Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_entity_count', assetId: kOrbisCoreAsset)
external int entityCount(Pointer<OrbisWorldStruct> world);

@Native<Bool Function(Pointer<OrbisWorldStruct>, Uint64, Uint32, Pointer<Void>)>(
    symbol: 'orbis_entity_add', assetId: kOrbisCoreAsset)
external bool entityAdd(Pointer<OrbisWorldStruct> world, int entity,
    int component, Pointer<Void> value);

@Native<Bool Function(Pointer<OrbisWorldStruct>, Uint64, Uint32)>(
    symbol: 'orbis_entity_remove', assetId: kOrbisCoreAsset)
external bool entityRemove(
    Pointer<OrbisWorldStruct> world, int entity, int component);

@Native<Bool Function(Pointer<OrbisWorldStruct>, Uint64, Uint32)>(
    symbol: 'orbis_entity_has', assetId: kOrbisCoreAsset)
external bool entityHas(
    Pointer<OrbisWorldStruct> world, int entity, int component);

@Native<Pointer<Void> Function(Pointer<OrbisWorldStruct>, Uint64, Uint32)>(
    symbol: 'orbis_entity_get', assetId: kOrbisCoreAsset)
external Pointer<Void> entityGet(
    Pointer<OrbisWorldStruct> world, int entity, int component);

@Native<
    Pointer<OrbisQueryStruct> Function(
        Pointer<OrbisWorldStruct>, Pointer<Uint32>, Uint32)>(
    symbol: 'orbis_query_create', assetId: kOrbisCoreAsset)
external Pointer<OrbisQueryStruct> queryCreate(
    Pointer<OrbisWorldStruct> world, Pointer<Uint32> components, int count);

@Native<Void Function(Pointer<OrbisQueryStruct>)>(
    symbol: 'orbis_query_destroy', assetId: kOrbisCoreAsset)
external void queryDestroy(Pointer<OrbisQueryStruct> query);

@Native<Uint32 Function(Pointer<OrbisQueryStruct>)>(
    symbol: 'orbis_query_chunk_count', assetId: kOrbisCoreAsset)
external int queryChunkCount(Pointer<OrbisQueryStruct> query);

@Native<Uint32 Function(Pointer<OrbisQueryStruct>, Uint32)>(
    symbol: 'orbis_query_chunk_length', assetId: kOrbisCoreAsset)
external int queryChunkLength(Pointer<OrbisQueryStruct> query, int chunk);

@Native<Pointer<Void> Function(Pointer<OrbisQueryStruct>, Uint32, Uint32)>(
    symbol: 'orbis_query_chunk_column', assetId: kOrbisCoreAsset)
external Pointer<Void> queryChunkColumn(
    Pointer<OrbisQueryStruct> query, int chunk, int slot);

@Native<Pointer<Uint64> Function(Pointer<OrbisQueryStruct>, Uint32)>(
    symbol: 'orbis_query_chunk_entities', assetId: kOrbisCoreAsset)
external Pointer<Uint64> queryChunkEntities(
    Pointer<OrbisQueryStruct> query, int chunk);

@Native<
    Uint32 Function(
        Pointer<OrbisQueryStruct>, Uint32, Pointer<Uint32>, Uint32)>(
    symbol: 'orbis_query_chunk_components', assetId: kOrbisCoreAsset)
external int queryChunkComponents(Pointer<OrbisQueryStruct> query, int chunk,
    Pointer<Uint32> out, int capacity);

@Native<Pointer<Void> Function(Pointer<OrbisQueryStruct>, Uint32, Uint32)>(
    symbol: 'orbis_query_chunk_component_column', assetId: kOrbisCoreAsset)
external Pointer<Void> queryChunkComponentColumn(
    Pointer<OrbisQueryStruct> query, int chunk, int component);

/// The three component ids the core's transform support registers.
final class OrbisTransformsStruct extends Struct {
  @Uint32()
  external int local;

  @Uint32()
  external int world;

  @Uint32()
  external int parent;
}

@Native<OrbisTransformsStruct Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_transform_register', assetId: kOrbisCoreAsset)
external OrbisTransformsStruct transformRegister(
    Pointer<OrbisWorldStruct> world);

@Native<Uint32 Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_transform_propagate', assetId: kOrbisCoreAsset)
external int transformPropagate(Pointer<OrbisWorldStruct> world);

@Native<Void Function(Pointer<Float>, Pointer<Float>)>(
    symbol: 'orbis_transform_compose', assetId: kOrbisCoreAsset)
external void transformCompose(Pointer<Float> trs, Pointer<Float> out);

@Native<Void Function(Pointer<OrbisWorldStruct>, Double)>(
    symbol: 'orbis_world_tick', assetId: kOrbisCoreAsset)
external void worldTick(Pointer<OrbisWorldStruct> world, double delta);

@Native<Double Function(Pointer<OrbisWorldStruct>)>(
    symbol: 'orbis_world_elapsed', assetId: kOrbisCoreAsset)
external double worldElapsed(Pointer<OrbisWorldStruct> world);
