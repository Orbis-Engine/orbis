// The `setScene` message, decoded and applied — the web's OrbisScene.kt.
//
// This is the third reader of the same message: OrbisFilamentPlugin.swift's
// `Scene`, OrbisScene.kt, and this. It mirrors the Kotlin one deliberately —
// the same field names in the same order, the same "absent means this part of
// the scene has nothing to say" defaults, and the same apply order — so a
// change made to one is easy to find in the others.
//
// What differs is only the crossing. Kotlin gets a `FloatArray` from the
// standard codec and hands it to JNI; here the arrays arrive as Dart typed
// data and have to be copied into the wasm module's own heap before the C ABI
// can read them (OrbisHeap), because a pointer into Dart's heap means nothing
// to WebAssembly.
//
// One deliberate narrowing, the same one Kotlin made: this checks that the
// arrays a call reads are the *shape* the renderer needs, not that every index
// inside them points somewhere valid. Those numbers come from
// `OrbisScene.toMessage()`, the one place they are built.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'orbis_module.dart';

/// The strides the three sides share, as `native_contract_test.dart` pins
/// them. Only the ones this file needs to turn an array length back into a
/// count — the rest are the renderer's business.
const int _lightStride = 22;
const int _probeStride = 8;
const int _materialStride = 37;
const int _materialMaps = 7;
const int _videoStride = 4;
const int _decalStride = 22;
const int _splatStride = 18;
const int _passStride = 13;
const int _targetStride = 6;

/// TEMPORARY, for the diagnostics in [OrbisSceneWeb._apply].
bool _loggedShapes = false;
bool _loggedOutcomes = false;

/// TEMPORARY: `?ORBIS_WEB_SKIP=pipeline,graph` leaves those scene calls out.
///
/// For bisecting what a frame's shading actually depends on. The plain-JS host
/// in native/web/host/ makes five of these twenty-two calls and lights its
/// scene correctly; this is how to find out which of the other seventeen a
/// Flutter scene is being darkened by, without a rebuild per guess.
final Set<String> _skips = (Uri.base.queryParameters['ORBIS_WEB_SKIP'] ?? '')
    .split(',')
    .map((one) => one.trim())
    .where((one) => one.isNotEmpty)
    .toSet();

bool _skipped(String name) => _skips.contains(name);

/// A scene as it arrives over the channel, applied to one renderer.
///
/// [from] returns null for a message missing what every scene must carry —
/// the object arrays and a camera — which is the `bad-scene` case the Swift
/// and Kotlin plugins answer with. Everything else is optional.
class OrbisSceneWeb {
  OrbisSceneWeb._(this._args);

  final Map<Object?, Object?> _args;

  static OrbisSceneWeb? from(Map<Object?, Object?> args) {
    // The same seven the Kotlin side insists on. `objectKeys` is a plain
    // List<int> rather than an Int64List here: dart2js has no Int64List at
    // all, so scene.dart builds its key arrays through `makeKeyList`, whose
    // web half is an ordinary list. See lib/src/key_list.dart.
    if (args['objectKeys'] is! List ||
        args['transforms'] is! Float32List ||
        args['colours'] is! Float32List ||
        args['meshes'] is! Int32List ||
        args['objectFlags'] is! Int32List ||
        args['cameraPosition'] is! Float32List ||
        args['cameraTarget'] is! Float32List) {
      return null;
    }
    final scene = OrbisSceneWeb._(args);
    final count = scene.count;
    if (scene.objectKeys.length != count ||
        scene.meshes.length != count ||
        scene.objectFlags.length != count ||
        scene.colours.length != count * 3 ||
        scene.cameraPosition.length != 3 ||
        scene.cameraTarget.length != 3) {
      return null;
    }
    return scene;
  }

  // ---- readers, with the same "absent is empty" defaults ----------------

  Float32List _floats(String key) =>
      _args[key] as Float32List? ?? Float32List(0);

  Int32List _ints(String key) => _args[key] as Int32List? ?? Int32List(0);

  Uint8List _bytes(String key) => _args[key] as Uint8List? ?? Uint8List(0);

  /// A key array. Int64 on the wire everywhere else; an ordinary list of ints
  /// here, for want of an Int64List on the web.
  List<int> _keys(String key) => [
    for (final value in (_args[key] as List? ?? const []))
      if (value is int) value else (value as num).toInt(),
  ];

  List<String> _strings(String key) => [
    for (final value in (_args[key] as List? ?? const []))
      if (value is String) value else '',
  ];

  String _string(String key) => _args[key] as String? ?? '';

  double _number(String key, double fallback) {
    final value = _args[key];
    return value is num ? value.toDouble() : fallback;
  }

  bool _flag(String key) => _args[key] as bool? ?? false;

  int get count => _floats('transforms').length ~/ 16;

  List<int> get objectKeys => _keys('objectKeys');
  Float32List get colours => _floats('colours');
  Int32List get meshes => _ints('meshes');
  Int32List get objectFlags => _ints('objectFlags');
  Float32List get cameraPosition => _floats('cameraPosition');
  Float32List get cameraTarget => _floats('cameraTarget');

  /// Applies every part of the scene, in the order `Viewport.write(scene:)`
  /// and `OrbisScene.applyTo` both use. The order is not arbitrary — the
  /// renderer resolves indices between calls, so materials must land before
  /// the objects that name them.
  void applyTo(OrbisModule module, int renderer) {
    final heap = OrbisHeap(module);
    try {
      _apply(module, renderer, heap);
    } finally {
      heap.free();
    }
  }

  void _apply(OrbisModule module, int renderer, OrbisHeap heap) {
    // TEMPORARY: what actually arrived, once. Several of the ABI's arrays
    // carry no length of their own — `kinds` and `flags` on apply_lights, for
    // instance — so a short one is read as whatever follows it in the heap
    // and is never refused. That failure looks exactly like "the lighting is
    // broken" while every call returns ORBIS_OK.
    if (!_loggedShapes) {
      _loggedShapes = true;
      String shape(String key) {
        final value = _args[key];
        final length = value is List ? value.length : -1;
        return '$key=${value.runtimeType}[$length]';
      }

      web.console.warn(
        ('[orbis] decoded: ${shape('objectKeys')} ${shape('transforms')} '
                '${shape('lightKeys')} ${shape('lightKinds')} '
                '${shape('lightFlags')} ${shape('lightParams')} '
                '${shape('skyColour')} ambient=${_args['ambient']} '
                'aperture=${_args['aperture']} '
                'shutter=${_args['shutterSpeed']} iso=${_args['sensitivity']} '
                'lightParams=${_floats('lightParams').take(8).toList()} '
                // The likeliest cause of geometry that draws in the right
                // place in the wrong colour: a base colour of nought shades
                // black however well lit it is.
                'colours=${_floats('colours').toList()} '
                'objectFlags=${_ints('objectFlags').toList()} '
                'meshes=${_ints('meshes').toList()} '
                'objectMaterials=${(_args['objectMaterials'] as List?)?.toList()} '
                'skyColour=${_floats('skyColour').toList()}')
            .toJS,
      );
    }

    // Every orbis_result that is not ORBIS_OK, said out loud.
    //
    // The ABI answers a refusal with a code rather than throwing, and a scene
    // call that applies nothing — a short array, or a null pointer with a
    // non-zero count — is otherwise indistinguishable from one that worked:
    // the frame still draws, only without whatever was refused. That is
    // exactly the shape of a bug that looks like "the lighting is broken".
    final outcomes = <String>[];
    int call(String name, List<Object?> args) {
      final result = orbisCall(module, name, args);
      outcomes.add('${name.replaceFirst('orbis_renderer_', '')}=$result');
      if (result != 0) {
        // console, not debugPrint: this has to be audible in a release build,
        // which is what `flutter build web` produces and what a headless
        // capture runs. debugPrint goes through Flutter's own printing, which
        // a release build is free to say nothing through — and a diagnostic
        // that is silent in the build you actually ship is worse than none,
        // because its silence reads as "nothing was refused".
        web.console.warn('[orbis] $name refused the scene: $result'.toJS);
      }
      return result;
    }

    // 1. Environment.
    final environmentParams = _floats('environmentParams');
    if (!_skipped('environment')) {
      call('orbis_renderer_set_environment', [
        renderer,
        heap.string(_string('environmentRadiance')),
        heap.string(_string('environmentSkybox')),
        heap.floats(environmentParams),
        environmentParams.length,
      ]);
    }

    // 2. The render graph.
    final passes = _floats('graphPasses');
    final targets = _floats('graphTargets');
    final targetNames = _strings('graphTargetNames');
    if (!_skipped('graph')) {
      call('orbis_renderer_set_render_graph', [
        renderer,
        passes.length ~/ _passStride,
        heap.floats(passes),
        passes.length,
        targets.length ~/ _targetStride,
        heap.floats(targets),
        targets.length,
        heap.strings(targetNames),
        targetNames.length,
      ]);
    }

    // 3. Batching, then 4. god rays.
    call('orbis_renderer_set_batching', [renderer, _flag('batching') ? 1 : 0]);

    final godRays = _floats('godRayParams');
    final distortions = _floats('distortionParams');
    call('orbis_renderer_set_god_rays', [
      renderer,
      heap.floats(godRays),
      godRays.length,
      heap.floats(distortions),
      distortions.length,
    ]);

    // 5. Videos.
    final videoKeys = _keys('videoKeys');
    final videoParams = _floats('videoParams');
    call('orbis_renderer_apply_videos', [
      renderer,
      videoKeys.isNotEmpty ? videoKeys.length : videoParams.length ~/ _videoStride,
      heap.int64s(videoKeys),
      heap.ints(_ints('videoFlags')),
      heap.floats(videoParams),
      videoParams.length,
      heap.strings(_strings('videoPaths')),
      _strings('videoPaths').length,
    ]);

    // 6. Materials, before the objects that index them.
    final materialKeys = _keys('materialKeys');
    final materialParams = _floats('materialParams');
    final materialCount = materialKeys.isNotEmpty
        ? materialKeys.length
        : materialParams.length ~/ _materialStride;
    final materialMaps = _ints('materialMaps');
    final texturePaths = _strings('texturePaths');
    // Absent means "every material has no video", which is -1 each, not an
    // empty array — the same default Kotlin's `intsOr` supplies.
    final materialVideos = _args['materialVideos'] as Int32List? ??
        Int32List.fromList(List<int>.filled(materialCount, -1));
    call('orbis_renderer_apply_materials', [
      renderer,
      materialCount,
      heap.int64s(materialKeys),
      heap.ints(_ints('materialFlags')),
      heap.floats(materialParams),
      materialParams.length,
      heap.ints(materialMaps),
      // The total number of map indices, not the number of materials: the ABI
      // spells this the same way it spells `param_floats` just above — how
      // many elements the array holds end to end, which it checks against
      // count * ORBIS_STRIDE_MATERIAL_MAPS before reading any of them.
      materialMaps.length,
      heap.strings(texturePaths),
      heap.ints(_ints('textureSrgb')),
      texturePaths.length,
      heap.ints(materialVideos),
    ]);

    // 7. The objects themselves.
    final transforms = _floats('transforms');
    final objectColours = colours;
    final morphWeights = _floats('objectMorphWeights');
    final meshPaths = _strings('meshPaths');
    final objectMaterials = _args['objectMaterials'] as Int32List? ??
        Int32List.fromList(List<int>.filled(count, -1));
    final morphCounts =
        _args['objectMorphCounts'] as Int32List? ?? Int32List(count);
    call('orbis_renderer_apply_objects', [
      renderer,
      count,
      heap.int64s(objectKeys),
      heap.floats(transforms),
      transforms.length,
      heap.floats(objectColours),
      objectColours.length,
      heap.ints(meshes),
      heap.ints(objectFlags),
      heap.ints(objectMaterials),
      heap.ints(morphCounts),
      heap.floats(morphWeights),
      morphWeights.length,
      heap.strings(meshPaths),
      meshPaths.length,
    ]);

    // 8. Populations. Absent altogether when a scene has none.
    final populationKeys = _ints('populationKeys');
    if (populationKeys.isNotEmpty) {
      final bounds = _floats('populationBounds');
      final populationPaths = _strings('populationPaths');
      final changed = _ints('populationChanged');
      final populationTransforms = _floats('populationTransforms');
      final populationColours = _floats('populationColours');
      call('orbis_renderer_apply_populations', [
        renderer,
        populationKeys.length,
        heap.ints(populationKeys),
        heap.ints(_ints('populationCounts')),
        heap.ints(_ints('populationMeshes')),
        heap.ints(_ints('populationFlags')),
        heap.ints(_ints('populationRevisions')),
        heap.floats(_floats('populationRanges')),
        heap.floats(bounds),
        bounds.length,
        heap.strings(populationPaths),
        populationPaths.length,
        heap.ints(changed),
        changed.length,
        heap.floats(populationTransforms),
        populationTransforms.length,
        heap.floats(populationColours),
        populationColours.length,
      ]);
    }

    // 9. Splats.
    final splatKeys = _ints('splatKeys');
    final splatParams = _floats('splatParams');
    final splatPaths = _strings('splatPaths');
    final splatChanged = _ints('splatChanged');
    final splatData = _bytes('splatData');
    call('orbis_renderer_apply_splats', [
      renderer,
      splatKeys.isNotEmpty
          ? splatKeys.length
          : splatParams.length ~/ _splatStride,
      heap.ints(splatKeys),
      heap.ints(_ints('splatFlags')),
      heap.ints(_ints('splatRevisions')),
      heap.floats(splatParams),
      splatParams.length,
      heap.strings(splatPaths),
      splatPaths.length,
      heap.ints(splatChanged),
      heap.ints(_ints('splatChangedCounts')),
      splatChanged.length,
      heap.uint8s(splatData),
      splatData.length,
    ]);

    // 10. Lights.
    final lightKeys = _keys('lightKeys');
    final lightParams = _floats('lightParams');
    call('orbis_renderer_apply_lights', [
      renderer,
      lightKeys.isNotEmpty
          ? lightKeys.length
          : lightParams.length ~/ _lightStride,
      heap.int64s(lightKeys),
      heap.ints(_ints('lightKinds')),
      heap.ints(_ints('lightFlags')),
      heap.floats(lightParams),
      lightParams.length,
    ]);

    // 11. Decals.
    final decalParams = _floats('decalParams');
    final decalPaths = _strings('decalPaths');
    call('orbis_renderer_apply_decals', [
      renderer,
      decalParams.length ~/ _decalStride,
      heap.floats(decalParams),
      decalParams.length,
      heap.ints(_ints('decalImages')),
      heap.strings(decalPaths),
      decalPaths.length,
    ]);

    // 12. Probes.
    final probeKeys = _keys('probeKeys');
    final probeParams = _floats('probeParams');
    call('orbis_renderer_apply_probes', [
      renderer,
      probeKeys.isNotEmpty
          ? probeKeys.length
          : probeParams.length ~/ _probeStride,
      heap.int64s(probeKeys),
      heap.floats(probeParams),
      probeParams.length,
    ]);

    // 13. The irradiance field, only when there is one.
    final fieldParams = _floats('fieldParams');
    if (fieldParams.isNotEmpty && !_skipped('field')) {
      call('orbis_renderer_apply_field', [
        renderer,
        heap.floats(fieldParams),
        fieldParams.length,
        heap.string(_string('fieldFrom')),
      ]);
    }

    // 14-19. The atmosphere and the frame's composition.
    call('orbis_renderer_set_sky_colour', [
      renderer,
      heap.floats(_floats('skyColour')),
      _number('ambient', 0),
      _flag('showBody') ? 1 : 0,
    ]);

    final fogParams = _floats('fogParams');
    call('orbis_renderer_set_fog', [
      renderer,
      _flag('fogEnabled') ? 1 : 0,
      heap.floats(fogParams),
      fogParams.length,
    ]);

    final postParams = _floats('postParams');
    if (postParams.isNotEmpty && !_skipped('post')) {
      call('orbis_renderer_set_post_process', [
        renderer,
        heap.floats(postParams),
        postParams.length,
      ]);
    }

    final pipelineParams = _floats('pipelineParams');
    if (pipelineParams.isNotEmpty && !_skipped('pipeline')) {
      call('orbis_renderer_set_pipeline', [
        renderer,
        heap.floats(pipelineParams),
        pipelineParams.length,
      ]);
    }

    final precipitationParams = _floats('precipitationParams');
    call('orbis_renderer_set_precipitation', [
      renderer,
      _flag('precipitationEnabled') ? 1 : 0,
      heap.floats(precipitationParams),
      precipitationParams.length,
    ]);

    final skyParams = _floats('skyParams');
    if (!_skipped('sky')) {
      call('orbis_renderer_set_sky', [
        renderer,
        _flag('skyEnabled') ? 1 : 0,
        heap.floats(skyParams),
        skyParams.length,
      ]);
    }

    // 20-21. Where the camera is, and what the film is.
    call('orbis_renderer_set_camera', [
      renderer,
      heap.floats(cameraPosition),
      heap.floats(cameraTarget),
      _number('fieldOfView', 45),
      _flag('orthographic') ? 1 : 0,
      _number('viewHeight', 1),
      _number('at', 0),
    ]);

    call('orbis_renderer_set_exposure', [
      renderer,
      _number('aperture', 16),
      _number('shutterSpeed', 1.0 / 125.0),
      _number('sensitivity', 100),
    ]);

    // 22. What is outlined.
    final outlineKeys = _keys('outlineKeys');
    final outlineParams = _floats('outlineParams');
    call('orbis_renderer_set_outline', [
      renderer,
      heap.int64s(outlineKeys),
      outlineKeys.length,
      heap.floats(outlineParams),
      outlineParams.length,
    ]);

    // TEMPORARY: every call's orbis_result, once. A scene is twenty-two calls
    // and only some of them show on screen, so "which one refused" is the
    // first question worth asking of a frame that draws the right shapes in
    // the wrong colours.
    if (!_loggedOutcomes) {
      _loggedOutcomes = true;
      web.console.warn(
        ('[orbis] calls: ${outcomes.join(' ')} | materials='
                '${_keys('materialKeys').length} maps=${_ints('materialMaps').length} '
                'objectMaterials=${(_args['objectMaterials'] as List?)?.length} '
                'passes=${_floats('graphPasses').length ~/ _passStride} '
                'post=${_floats('postParams').length} '
                'pipeline=${_floats('pipelineParams').length}')
            .toJS,
      );
    }
  }
}
