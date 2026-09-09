import Foundation

#if os(iOS)
  import Flutter
  import QuartzCore
#else
  import CoreVideo
  import FlutterMacOS
#endif

// Under CocoaPods the renderer is in this same module; under Swift Package
// Manager it is its own target, because a package target holds one language
// and the renderer is Objective-C++. The import is conditional so one source
// file serves both.
#if canImport(orbis_filament_native)
  import orbis_filament_native
#endif

/// A once-per-refresh tick, from whichever display link this platform has.
///
/// The only part of the render loop that differs between the two: macOS has
/// CVDisplayLink, which calls a C function on a thread of its own, and iOS has
/// CADisplayLink, which targets a selector on a run loop. What is done with
/// the tick is identical, so only the clock is behind the #if.
private final class FrameClock {
  private var onTick: (() -> Void)?

  #if os(iOS)
    private var link: CADisplayLink?

    func start(_ tick: @escaping () -> Void) {
      onTick = tick
      // Added to the main run loop, so the tick arrives on the thread that
      // owns the engine. That is not an optimisation — Filament's job system
      // only accepts work from threads it has adopted.
      let link = CADisplayLink(target: self, selector: #selector(fire))
      link.add(to: .main, forMode: .common)
      self.link = link
    }

    @objc private func fire() { onTick?() }

    func stop() {
      link?.invalidate()
      link = nil
      onTick = nil
    }
  #else
    private var link: CVDisplayLink?

    func start(_ tick: @escaping () -> Void) {
      onTick = tick
      // CVDisplayLink is soft-deprecated on recent macOS in favour of the
      // NSView-attached variant, but that needs a view we do not own —
      // Flutter owns the hierarchy and hands us only a texture id.
      var link: CVDisplayLink?
      guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
            let link else { return }

      CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
        guard let context else { return kCVReturnSuccess }
        Unmanaged<FrameClock>.fromOpaque(context).takeUnretainedValue().onTick?()
        return kCVReturnSuccess
      }, Unmanaged.passUnretained(self).toOpaque())

      CVDisplayLinkStart(link)
      self.link = link
    }

    func stop() {
      if let link {
        CVDisplayLinkStop(link)
        self.link = nil
      }
      onTick = nil
    }
  #endif
}

/// The one thread the engine is allowed to be spoken to from.
///
/// Filament's job system only accepts work from threads it has adopted, and
/// the thread that creates the engine is the one it adopts. Everything after
/// that — every frame, every scene, every model read from disk — has to come
/// from the same thread or it aborts inside the job system.
///
/// That thread used to be the main one, which meant a model's half second of
/// reading and uploading was half a second of frozen application: no cursor,
/// no menus, no repaint. It is what "the scene takes a moment to load" was.
///
/// A `Thread` rather than a `DispatchQueue`, and the distinction is the whole
/// point: a serial queue promises the blocks do not overlap, not that they run
/// on the same thread, and Filament is asking about the thread. A queue would
/// work until the day the pool handed a block to a different worker, which is
/// the kind of fault that appears once a fortnight in someone else's build.
private final class EngineThread {
  private let thread: Thread
  private let ready = DispatchSemaphore(value: 0)
  private var loop: CFRunLoop?

  init() {
    var made: CFRunLoop?
    let start = DispatchSemaphore(value: 0)
    thread = Thread {
      made = CFRunLoopGetCurrent()
      start.signal()
      // A source that is never signalled, so the loop has something to wait
      // on and does not return the moment it is entered.
      let keep = CFRunLoopSourceContext()
      var context = keep
      let source = CFRunLoopSourceCreate(nil, 0, &context)
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
      CFRunLoopRun()
    }
    thread.name = "orbis.engine"
    // Above the default, below the display link's. This thread is what draws.
    thread.qualityOfService = .userInteractive
    thread.start()
    start.wait()
    loop = made
    ready.signal()
  }

  /// Runs `work` on the engine's thread and comes back when it is done.
  ///
  /// For the calls whose answer the caller needs: creating a viewport, asking
  /// what a frame cost, tearing one down.
  func sync<T>(_ work: @escaping () -> T) -> T {
    if Thread.current === thread { return work() }
    var answer: T!
    let done = DispatchSemaphore(value: 0)
    post { answer = work(); done.signal() }
    done.wait()
    return answer
  }

  /// Runs `work` on the engine's thread and returns immediately.
  ///
  /// For everything else, which is most of it: a frame, a scene, a resize.
  /// The caller has nothing to wait for and waiting is the thing being
  /// removed.
  func async(_ work: @escaping () -> Void) {
    post(work)
  }

  private func post(_ work: @escaping () -> Void) {
    guard let loop else { return }
    CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, work)
    CFRunLoopWakeUp(loop)
  }
}

/// One 3D surface: a renderer, the texture Flutter samples, and the display
/// link driving it.
///
/// The loop lives here rather than in Dart. Sending a render command across a
/// method channel sixty times a second would put the frame rate at the mercy
/// of the platform channel queue, and the simulation tick — which genuinely
/// does belong to Dart — is a separate concern arriving later.
private final class Viewport {
  let textureId: Int64
  private let renderer: OrbisRenderer
  private let registry: FlutterTextureRegistry
  private let engine: EngineThread
  private let clock = FrameClock()
  private let startedAt = CFAbsoluteTimeGetCurrent()
  private let frameLock = NSLock()
  private var framePending = false

  /// Set before teardown, and read on the engine's thread.
  ///
  /// A frame can already be on its way to that thread when a viewport is
  /// disposed — the display link fires, the block is posted, and the texture
  /// is unregistered before the block runs. Flutter then says it cannot mark
  /// a texture it no longer has, once per frame in flight. Ordering used to
  /// be implicit because all of this happened on one thread.
  private var stopped = false

  init(textureId: Int64, renderer: OrbisRenderer,
       registry: FlutterTextureRegistry, engine: EngineThread) {
    self.textureId = textureId
    self.renderer = renderer
    self.registry = registry
    self.engine = engine
  }

  /// What a frame usually costs this viewport's GPU, in milliseconds.
  var gpuMilliseconds: Double { engine.sync { self.renderer.gpuMilliseconds() } }

  /// What each pass of the last frame cost, and how much it drew — two
  /// numbers per pass, in the order they ran.
  var passTimings: [NSNumber] { engine.sync { self.renderer.passTimings } }

  func start() {
    clock.start { [weak self] in self?.tick() }
  }

  /// Called on the display link's own thread, which does not own the engine.
  ///
  /// Filament's job system only accepts work from threads it has adopted, and
  /// the one that created the engine is the only one adopted here — calling it
  /// from the display-link thread aborts inside `FScene::prepare`. So the link
  /// is a clock, not a worker: it schedules the frame onto the thread that does
  /// own the engine, which is also where the simulation tick will live.
  private func tick() {
    frameLock.lock()
    if framePending {
      // The main thread has not finished the previous frame. Dropping this one
      // keeps the display link from queueing work faster than it can be done.
      frameLock.unlock()
      return
    }
    framePending = true
    frameLock.unlock()

    let time = CFAbsoluteTimeGetCurrent() - startedAt
    engine.async { [weak self] in
      guard let self else { return }
      self.frameLock.lock()
      let gone = self.stopped
      self.frameLock.unlock()
      if gone { return }

      self.renderer.render(atTime: time)
      self.registry.textureFrameAvailable(self.textureId)
      self.frameLock.lock()
      self.framePending = false
      self.frameLock.unlock()
    }
  }

  func resize(width: UInt32, height: UInt32) {
    engine.async { self.renderer.resize(toWidth: width, height: height) }
  }

  /// Applies a scene sent from Dart.
  ///
  /// Handed to the engine's thread rather than done here. A scene can name a
  /// model that is not loaded yet, and loading one is half a second of reading
  /// and uploading — on the thread the channel call arrives on, that is half a
  /// second of frozen application. It is also the only thread Filament will
  /// accept the work from, so this is not a choice between two places to do
  /// it: it is the place.
  ///
  /// Scenes cannot overtake one another, because the engine's thread runs one
  /// block at a time and a frame is posted to the same queue — a scene is
  /// never swapped out from under a render in progress.
  /// [answered] is called on the main thread with whatever the renderer has
  /// to say, once the scene is actually in. Waiting for it here instead would
  /// put the load back on the thread this is trying to keep free.
  func apply(scene: Scene, answered: @escaping ([String: String]) -> Void) {
    engine.async {
      self.write(scene: scene)
      let notes = self.renderer.notes
      DispatchQueue.main.async { answered(notes) }
    }
  }

  private func write(scene: Scene) {
    // An empty Swift array's base address is nil, and the renderer's pointers
    // are not nullable. Nothing is read through them when the count is zero,
    // so an empty scene borrows a valid address it will not touch.
    let keys = scene.count == 0 ? [Int64(0)] : scene.keys
    let transforms = scene.count == 0 ? [Float(0)] : scene.transforms
    let colours = scene.count == 0 ? [Float(0)] : scene.colours
    let meshes = scene.count == 0 ? [Int32(-1)] : scene.meshes
    let flags = scene.count == 0 ? [Int32(0)] : scene.flags
    let objectMaterials = scene.count == 0 ? [Int32(-1)] : scene.objectMaterials
    let morphCounts = scene.count == 0 ? [Int32(0)] : scene.objectMorphCounts
    let morphWeights =
      scene.objectMorphWeights.isEmpty ? [Float(0)] : scene.objectMorphWeights

    // The place before anything in it, so that the first frame drawn with a
    // new environment is lit by it rather than by the one before.
    renderer.setEnvironmentRadiance(scene.environmentRadiance,
                                    skybox: scene.environmentSkybox,
                                    params: scene.environmentParams)

    // The graph next: a material may sample what a pass drew, and a target
    // that does not exist yet reads as a texture that failed to load.
    let graphPasses = scene.graphPasses.isEmpty ? [Float(0)] : scene.graphPasses
    let graphTargets =
      scene.graphTargets.isEmpty ? [Float(0)] : scene.graphTargets
    graphPasses.withUnsafeBufferPointer { passPointer in
      graphTargets.withUnsafeBufferPointer { targetPointer in
        renderer.setRenderGraph(
          passPointer.baseAddress!,
          count: UInt32(scene.graphPasses.count / 12),
          targets: targetPointer.baseAddress!,
          targetCount: UInt32(scene.graphTargets.count / 6),
          names: scene.graphTargetNames)
      }
    }

    // Videos before materials before objects, each because the next one may
    // point at it and a thing that does not exist yet reads as a thing that
    // was never asked for.
    let videoCount = scene.videoKeys.count
    let videoKeys = videoCount == 0 ? [Int64(0)] : scene.videoKeys
    let videoFlags = videoCount == 0 ? [Int32(0)] : scene.videoFlags
    let videoParams = videoCount == 0 ? [Float(0)] : scene.videoParams
    videoKeys.withUnsafeBufferPointer { keyPointer in
      videoFlags.withUnsafeBufferPointer { flagPointer in
        videoParams.withUnsafeBufferPointer { paramPointer in
          renderer.applyVideos(keyPointer.baseAddress!,
                               flags: flagPointer.baseAddress!,
                               params: paramPointer.baseAddress!,
                               paths: scene.videoPaths,
                               count: UInt32(videoCount))
        }
      }
    }

    let materialCount = scene.materialKeys.count
    let materialKeys = materialCount == 0 ? [Int64(0)] : scene.materialKeys
    let materialFlags = materialCount == 0 ? [Int32(0)] : scene.materialFlags
    let materialParams = materialCount == 0 ? [Float(0)] : scene.materialParams
    let materialMaps = materialCount == 0 ? [Int32(-1)] : scene.materialMaps
    let materialVideos = materialCount == 0 ? [Int32(-1)] : scene.materialVideos
    let textureSrgb = scene.textureSrgb.isEmpty ? [Int32(0)] : scene.textureSrgb

    materialKeys.withUnsafeBufferPointer { keyPointer in
      materialFlags.withUnsafeBufferPointer { flagPointer in
        materialParams.withUnsafeBufferPointer { paramPointer in
          materialMaps.withUnsafeBufferPointer { mapPointer in
            textureSrgb.withUnsafeBufferPointer { srgbPointer in
              materialVideos.withUnsafeBufferPointer { videoPointer in
                renderer.applyMaterials(keyPointer.baseAddress!,
                                        flags: flagPointer.baseAddress!,
                                        params: paramPointer.baseAddress!,
                                        maps: mapPointer.baseAddress!,
                                        texturePaths: scene.texturePaths,
                                        textureSrgb: srgbPointer.baseAddress!,
                                        videos: videoPointer.baseAddress!,
                                        count: UInt32(materialCount))
              }
            }
          }
        }
      }
    }

    keys.withUnsafeBufferPointer { keyPointer in
      transforms.withUnsafeBufferPointer { transformPointer in
        colours.withUnsafeBufferPointer { colourPointer in
          meshes.withUnsafeBufferPointer { meshPointer in
            flags.withUnsafeBufferPointer { flagPointer in
              objectMaterials.withUnsafeBufferPointer { materialPointer in
                morphCounts.withUnsafeBufferPointer { morphCountPointer in
                  morphWeights.withUnsafeBufferPointer { morphWeightPointer in
                    renderer.applyObjects(keyPointer.baseAddress!,
                                          transforms: transformPointer.baseAddress!,
                                          colours: colourPointer.baseAddress!,
                                          meshes: meshPointer.baseAddress!,
                                          flags: flagPointer.baseAddress!,
                                          materials: materialPointer.baseAddress!,
                                          morphCounts: morphCountPointer.baseAddress!,
                                          morphWeights: morphWeightPointer.baseAddress!,
                                          paths: scene.paths,
                                          count: UInt32(scene.count))
                  }
                }
              }
            }
          }
        }
      }
    }

    // Populations. Everything about them travels in parallel arrays, and the
    // buffers only travel for the ones whose revision has moved — which for a
    // scene that is standing still is none of them.
    let populationCount = scene.populationKeys.count
    if populationCount > 0 || renderer.hasPopulations {
      let keys = populationCount == 0 ? [Int32(0)] : scene.populationKeys
      let counts = populationCount == 0 ? [Int32(0)] : scene.populationCounts
      let meshes = populationCount == 0 ? [Int32(0)] : scene.populationMeshes
      let flags = populationCount == 0 ? [Int32(0)] : scene.populationFlags
      let revisions = populationCount == 0 ? [Int32(0)] : scene.populationRevisions
      let rangeValues = populationCount == 0 ? [Float(0)] : scene.populationRanges
      let bounds = populationCount == 0 ? [Float(0)] : scene.populationBounds
      let changed = scene.populationChanged.isEmpty ? [Int32(0)] : scene.populationChanged
      let transforms = scene.populationTransforms.isEmpty
        ? [Float(0)] : scene.populationTransforms
      let colours = scene.populationColours.isEmpty ? [Float(0)] : scene.populationColours

      keys.withUnsafeBufferPointer { keyPointer in
        counts.withUnsafeBufferPointer { countPointer in
          meshes.withUnsafeBufferPointer { meshPointer in
            flags.withUnsafeBufferPointer { flagPointer in
              revisions.withUnsafeBufferPointer { revisionPointer in
                rangeValues.withUnsafeBufferPointer { rangePointer in
                bounds.withUnsafeBufferPointer { boundsPointer in
                  changed.withUnsafeBufferPointer { changedPointer in
                    transforms.withUnsafeBufferPointer { transformPointer in
                      colours.withUnsafeBufferPointer { colourPointer in
                        renderer.applyPopulations(
                          keyPointer.baseAddress!,
                          counts: countPointer.baseAddress!,
                          meshes: meshPointer.baseAddress!,
                          flags: flagPointer.baseAddress!,
                          revisions: revisionPointer.baseAddress!,
                          ranges: rangePointer.baseAddress!,
                          bounds: boundsPointer.baseAddress!,
                          paths: scene.populationPaths,
                          changed: changedPointer.baseAddress!,
                          changedCount: UInt32(scene.populationChanged.count),
                          transforms: transformPointer.baseAddress!,
                          colours: colourPointer.baseAddress!,
                          count: UInt32(populationCount))
                      }
                    }
                  }
                }
                }
              }
            }
          }
        }
      }
    }

    let lightCount = scene.lightCount
    let lightKeys = lightCount == 0 ? [Int64(0)] : scene.lightKeys
    let lightKinds = lightCount == 0 ? [Int32(0)] : scene.lightKinds
    let lightFlags = lightCount == 0 ? [Int32(0)] : scene.lightFlags
    let lightParams = lightCount == 0 ? [Float(0)] : scene.lightParams

    lightKeys.withUnsafeBufferPointer { keyPointer in
      lightKinds.withUnsafeBufferPointer { kindPointer in
        lightFlags.withUnsafeBufferPointer { flagPointer in
          lightParams.withUnsafeBufferPointer { paramPointer in
            renderer.applyLights(keyPointer.baseAddress!,
                                 kinds: kindPointer.baseAddress!,
                                 flags: flagPointer.baseAddress!,
                                 params: paramPointer.baseAddress!,
                                 count: UInt32(lightCount))
          }
        }
      }
    }

    renderer.setSkyColour(scene.skyColour,
                          ambient: scene.ambient,
                          showBody: scene.showBody)
    renderer.setFogEnabled(scene.fogEnabled, params: scene.fogParams)
    if !scene.postParams.isEmpty {
      renderer.setPostProcess(scene.postParams, count: UInt(scene.postParams.count))
    }
    if !scene.pipelineParams.isEmpty {
      renderer.setPipeline(scene.pipelineParams,
                           count: UInt(scene.pipelineParams.count))
    }
    renderer.setPrecipitationEnabled(scene.precipitationEnabled,
                                     params: scene.precipitationParams)
    renderer.setSkyEnabled(scene.skyEnabled, params: scene.skyParams)
    renderer.setCameraPosition(scene.cameraPosition,
                               target: scene.cameraTarget,
                               fieldOfView: scene.fieldOfView,
                               orthographic: scene.orthographic,
                               viewHeight: scene.viewHeight,
                               at: scene.at)
    renderer.setExposure(scene.aperture,
                         shutter: scene.shutterSpeed,
                         sensitivity: scene.sensitivity)
  }

  /// What the scene asked for that could not be given, and why.
  func dispose() {
    // Said first, so a frame already on its way to the engine's thread turns
    // back rather than drawing into a texture that is about to be taken away.
    frameLock.lock()
    stopped = true
    frameLock.unlock()

    // Then the clock, so no more are posted; and the teardown itself waits,
    // because the caller unregisters the texture as soon as this returns and
    // the renderer is still holding its buffers.
    clock.stop()
    engine.sync { self.renderer.dispose() }
  }
}

/// A scene as it arrives over the channel.
///
/// Parsed once, here, so a malformed message is a channel error with something
/// to read rather than an out-of-bounds read inside the renderer.
private struct Scene {
  let count: Int
  let keys: [Int64]
  let transforms: [Float]
  let colours: [Float]
  let meshes: [Int32]
  let flags: [Int32]
  let paths: [String]
  let objectMaterials: [Int32]
  let objectMorphCounts: [Int32]
  let objectMorphWeights: [Float]
  let materialKeys: [Int64]
  let materialFlags: [Int32]
  let materialParams: [Float]
  let materialMaps: [Int32]
  let texturePaths: [String]
  let textureSrgb: [Int32]
  let materialVideos: [Int32]
  let videoKeys: [Int64]
  let videoFlags: [Int32]
  let videoParams: [Float]
  let videoPaths: [String]
  let lightCount: Int
  let lightKeys: [Int64]
  let lightKinds: [Int32]
  let lightFlags: [Int32]
  let lightParams: [Float]
  let cameraPosition: [Float]
  let cameraTarget: [Float]
  let fieldOfView: Float
  let aperture: Float
  let shutterSpeed: Float
  let sensitivity: Float
  let skyColour: [Float]
  let ambient: Float
  let showBody: Bool
  let fogEnabled: Bool
  let fogParams: [Float]
  let precipitationEnabled: Bool
  let precipitationParams: [Float]
  let skyEnabled: Bool

  /// Everything done to the image after the scene is drawn.
  ///
  /// Optional, and empty when a host has not sent any: an older application
  /// against a newer renderer should keep working with the defaults rather
  /// than failing to decode a scene.
  let postParams: [Float]
  let pipelineParams: [Float]

  /// The place the scene is standing in: a baked cubemap for the light, one
  /// for the backdrop, and how bright and how turned they are.
  let environmentRadiance: String
  let environmentSkybox: String
  let environmentParams: [Float]

  /// How the frame is put together: the passes, already in the order they
  /// run, the targets between them, and what those targets are called.
  let graphPasses: [Float]
  let graphTargets: [Float]
  let graphTargetNames: [String]

  /// The application's own clock, in seconds, when this scene was worked out.
  let at: Double
  let orthographic: Bool
  let viewHeight: Float

  /// Populations travel as parallel arrays, one entry each, plus the buffers
  /// for whichever of them have actually changed.
  let populationKeys: [Int32]
  let populationCounts: [Int32]
  let populationMeshes: [Int32]
  let populationFlags: [Int32]
  let populationRevisions: [Int32]
  let populationRanges: [Float]
  let populationBounds: [Float]
  let populationPaths: [String]
  let populationChanged: [Int32]
  let populationTransforms: [Float]
  let populationColours: [Float]
  let skyParams: [Float]

  /// How many floats one light occupies, and how many the fog does. Both
  /// match the packing on the Dart side; a mismatch is caught here as a
  /// refused message rather than there as a wrong-looking scene.
  private static let lightStride = 18

  /// How many floats a graph pass and a graph target take. Must match
  /// OrbisRenderGraph on the Dart side and the constants in the renderer.
  fileprivate static let environmentStride = 4
  fileprivate static let passStride = 13
  fileprivate static let targetStride = 6
  private static let materialStride = 26
  private static let materialMaps = 7
  private static let videoStride = 4
  private static let fogStride = 16
  private static let precipitationStride = 12
  private static let skyStride = 34

  init?(arguments: [String: Any]) {
    guard let keys = (arguments["objectKeys"] as? FlutterStandardTypedData)?.int64s,
          let transforms = (arguments["transforms"] as? FlutterStandardTypedData)?.floats,
          let colours = (arguments["colours"] as? FlutterStandardTypedData)?.floats,
          let meshes = (arguments["meshes"] as? FlutterStandardTypedData)?.int32s,
          let flags = (arguments["objectFlags"] as? FlutterStandardTypedData)?.int32s,
          let paths = arguments["meshPaths"] as? [String],
          let lightKeys = (arguments["lightKeys"] as? FlutterStandardTypedData)?.int64s,
          let lightKinds = (arguments["lightKinds"] as? FlutterStandardTypedData)?.int32s,
          let lightFlags = (arguments["lightFlags"] as? FlutterStandardTypedData)?.int32s,
          let lightParams = (arguments["lightParams"] as? FlutterStandardTypedData)?.floats,
          let cameraPosition = (arguments["cameraPosition"] as? FlutterStandardTypedData)?.floats,
          let cameraTarget = (arguments["cameraTarget"] as? FlutterStandardTypedData)?.floats,
          let skyColour = (arguments["skyColour"] as? FlutterStandardTypedData)?.floats,
          let fogParams = (arguments["fogParams"] as? FlutterStandardTypedData)?.floats,
          let precipitationParams =
            (arguments["precipitationParams"] as? FlutterStandardTypedData)?.floats,
          let precipitationEnabled = arguments["precipitationEnabled"] as? Bool,
          let skyParams =
            (arguments["skyParams"] as? FlutterStandardTypedData)?.floats,
          let skyEnabled = arguments["skyEnabled"] as? Bool,
          let fogEnabled = arguments["fogEnabled"] as? Bool,
          let showBody = arguments["showBody"] as? Bool,
          let ambient = arguments["ambient"] as? Double,
          let aperture = arguments["aperture"] as? Double,
          let shutterSpeed = arguments["shutterSpeed"] as? Double,
          let sensitivity = arguments["sensitivity"] as? Double,
          let fieldOfView = arguments["fieldOfView"] as? Double,
          let at = arguments["at"] as? Double,
          let orthographic = arguments["orthographic"] as? Bool,
          let viewHeight = arguments["viewHeight"] as? Double else { return nil }

    // Every one of these lengths is a pointer the renderer will walk. A short
    // array here is a read past the end there, so they are checked rather than
    // trusted.
    let count = transforms.count / 16
    let lightCount = lightKeys.count
    guard transforms.count == count * 16, colours.count == count * 3,
          meshes.count == count, keys.count == count, flags.count == count,
          // Every index is used to subscript `paths` in C++. One out of range
          // is a read past the end there rather than a missing model here.
          meshes.allSatisfy({ $0 < Int32(paths.count) }),
          lightKinds.count == lightCount, lightFlags.count == lightCount,
          lightParams.count == lightCount * Scene.lightStride,
          // A kind the renderer does not know would select a light type by
          // falling through, which is a silent wrong answer.
          lightKinds.allSatisfy({ $0 >= 0 && $0 <= 2 }),
          fogParams.count == Scene.fogStride,
          precipitationParams.count == Scene.precipitationStride,
          skyParams.count == Scene.skyStride,
          skyColour.count == 3,
          cameraPosition.count == 3, cameraTarget.count == 3 else { return nil }

    // Not in the guard above: a scene without it is a scene with the
    // defaults, not a scene that fails to arrive.
    self.postParams =
      (arguments["postParams"] as? FlutterStandardTypedData)?.floats ?? []
    self.pipelineParams =
      (arguments["pipelineParams"] as? FlutterStandardTypedData)?.floats ?? []

    // An environment is optional, and a short params array is a read past the
    // end in C++ rather than a dimmer scene here.
    let environmentParams =
      (arguments["environmentParams"] as? FlutterStandardTypedData)?.floats ?? []
    if environmentParams.count == Scene.environmentStride {
      self.environmentRadiance = arguments["environmentRadiance"] as? String ?? ""
      self.environmentSkybox = arguments["environmentSkybox"] as? String ?? ""
      self.environmentParams = environmentParams
    } else {
      self.environmentRadiance = ""
      self.environmentSkybox = ""
      self.environmentParams = [30000, 0, 1, 0]
    }

    // The graph is optional in exactly the same way. What does have to hold
    // is that the rows are whole and that every target index a pass names is
    // one that exists: both are subscripts in C++, and a short row or a stray
    // index is a read past the end there rather than a wrong picture here.
    let passes =
      (arguments["graphPasses"] as? FlutterStandardTypedData)?.floats ?? []
    let targets =
      (arguments["graphTargets"] as? FlutterStandardTypedData)?.floats ?? []
    let targetNames = arguments["graphTargetNames"] as? [String] ?? []
    let targetCount = targets.count / Scene.targetStride
    let passCount = passes.count / Scene.passStride
    if passes.count == passCount * Scene.passStride,
       targets.count == targetCount * Scene.targetStride,
       targetNames.count == targetCount,
       (0..<passCount).allSatisfy({
         Int(passes[$0 * Scene.passStride + 1]) < targetCount
       }) {
      self.graphPasses = passes
      self.graphTargets = targets
      self.graphTargetNames = targetNames
    } else {
      // A graph that does not add up is no graph: the ordinary frame, which
      // is what a host gets before it has said anything about passes at all.
      self.graphPasses = []
      self.graphTargets = []
      self.graphTargetNames = []
    }

    // Materials are optional the same way, so a host that never names one
    // sends nothing rather than an empty array of everything. What arrives
    // still has to agree with itself: every length below is walked as a
    // pointer in C++, and every index is used to subscript.
    let materialKeys =
      (arguments["materialKeys"] as? FlutterStandardTypedData)?.int64s ?? []
    let materialFlags =
      (arguments["materialFlags"] as? FlutterStandardTypedData)?.int32s ?? []
    let materialParams =
      (arguments["materialParams"] as? FlutterStandardTypedData)?.floats ?? []
    let materialMaps =
      (arguments["materialMaps"] as? FlutterStandardTypedData)?.int32s ?? []
    let texturePaths = arguments["texturePaths"] as? [String] ?? []
    let textureSrgb =
      (arguments["textureSrgb"] as? FlutterStandardTypedData)?.int32s ?? []
    // Shapes per object, and every shape's weight end to end behind it. The
    // two have to agree or the renderer walks off the end of the weights, so
    // the sum is checked here rather than trusted there.
    let objectMorphCounts =
      (arguments["objectMorphCounts"] as? FlutterStandardTypedData)?.int32s
      ?? [Int32](repeating: 0, count: count)
    let objectMorphWeights =
      (arguments["objectMorphWeights"] as? FlutterStandardTypedData)?.floats
      ?? [Float(0)]
    guard objectMorphCounts.count == count,
          objectMorphCounts.allSatisfy({ $0 >= 0 }),
          objectMorphCounts.reduce(0, { $0 + Int($1) }) <= objectMorphWeights.count
    else {
      return nil
    }

    let objectMaterials =
      (arguments["objectMaterials"] as? FlutterStandardTypedData)?.int32s
        ?? [Int32](repeating: -1, count: count)

    let materialCount = materialKeys.count
    guard materialFlags.count == materialCount,
          materialParams.count == materialCount * Scene.materialStride,
          materialMaps.count == materialCount * Scene.materialMaps,
          textureSrgb.count == texturePaths.count,
          materialMaps.allSatisfy({ $0 < Int32(texturePaths.count) }),
          objectMaterials.count == count,
          objectMaterials.allSatisfy({ $0 < Int32(materialCount) })
    else { return nil }

    let videoKeys =
      (arguments["videoKeys"] as? FlutterStandardTypedData)?.int64s ?? []
    let videoFlags =
      (arguments["videoFlags"] as? FlutterStandardTypedData)?.int32s ?? []
    let videoParams =
      (arguments["videoParams"] as? FlutterStandardTypedData)?.floats ?? []
    let videoPaths = arguments["videoPaths"] as? [String] ?? []
    let materialVideos =
      (arguments["materialVideos"] as? FlutterStandardTypedData)?.int32s
        ?? [Int32](repeating: -1, count: materialCount)

    guard videoFlags.count == videoKeys.count,
          videoPaths.count == videoKeys.count,
          videoParams.count == videoKeys.count * Scene.videoStride,
          materialVideos.count == materialCount,
          materialVideos.allSatisfy({ $0 < Int32(videoKeys.count) })
    else { return nil }

    self.materialVideos = materialVideos
    self.videoKeys = videoKeys
    self.videoFlags = videoFlags
    self.videoParams = videoParams
    self.videoPaths = videoPaths

    self.objectMaterials = objectMaterials
    self.objectMorphCounts = objectMorphCounts
    self.objectMorphWeights = objectMorphWeights
    self.materialKeys = materialKeys
    self.materialFlags = materialFlags
    self.materialParams = materialParams
    self.materialMaps = materialMaps
    self.texturePaths = texturePaths
    self.textureSrgb = textureSrgb

    self.count = count
    self.keys = keys
    self.transforms = transforms
    self.colours = colours
    self.meshes = meshes
    self.flags = flags
    self.paths = paths
    self.lightCount = lightCount
    self.lightKeys = lightKeys
    self.lightKinds = lightKinds
    self.lightFlags = lightFlags
    self.lightParams = lightParams
    self.cameraPosition = cameraPosition
    self.cameraTarget = cameraTarget
    self.fieldOfView = Float(fieldOfView)
    self.aperture = Float(aperture)
    self.shutterSpeed = Float(shutterSpeed)
    self.sensitivity = Float(sensitivity)
    self.skyColour = skyColour
    self.ambient = Float(ambient)
    self.showBody = showBody
    self.fogEnabled = fogEnabled
    self.fogParams = fogParams
    self.precipitationEnabled = precipitationEnabled
    self.precipitationParams = precipitationParams
    self.skyEnabled = skyEnabled
    self.at = at
    self.orthographic = orthographic
    self.viewHeight = Float(viewHeight)
    self.skyParams = skyParams

    // Absent when a scene has none, which is every scene that never uses
    // them — so this stays optional rather than being required of everybody.
    let populationKeys =
      (arguments["populationKeys"] as? FlutterStandardTypedData)?.int32s ?? []
    let populationCounts =
      (arguments["populationCounts"] as? FlutterStandardTypedData)?.int32s ?? []
    let populationMeshes =
      (arguments["populationMeshes"] as? FlutterStandardTypedData)?.int32s ?? []
    let populationFlags =
      (arguments["populationFlags"] as? FlutterStandardTypedData)?.int32s ?? []
    let populationRevisions =
      (arguments["populationRevisions"] as? FlutterStandardTypedData)?.int32s ?? []
    let populationRanges =
      (arguments["populationRanges"] as? FlutterStandardTypedData)?.floats ?? []
    let populationBounds =
      (arguments["populationBounds"] as? FlutterStandardTypedData)?.floats ?? []
    let populationChanged =
      (arguments["populationChanged"] as? FlutterStandardTypedData)?.int32s ?? []
    let populationTransforms =
      (arguments["populationTransforms"] as? FlutterStandardTypedData)?.floats ?? []
    let populationColours =
      (arguments["populationColours"] as? FlutterStandardTypedData)?.floats ?? []
    let populationPaths = arguments["populationPaths"] as? [String] ?? []

    // Every one of these is walked in C++ against a length taken from
    // somewhere else, so the lengths are checked here rather than trusted.
    // A hundred thousand transforms read one element past the end is not a
    // wrong picture, it is a crash on somebody's machine.
    let members = populationChanged.reduce(0) { total, key in
      guard let at = populationKeys.firstIndex(of: key) else { return total }
      return total + Int(populationCounts[at])
    }
    guard populationCounts.count == populationKeys.count,
          populationMeshes.count == populationKeys.count,
          populationFlags.count == populationKeys.count,
          populationRevisions.count == populationKeys.count,
          populationRanges.count == populationKeys.count,
          populationBounds.count == populationKeys.count * 6,
          populationMeshes.allSatisfy({ $0 < Int32(populationPaths.count) }),
          populationCounts.allSatisfy({ $0 >= 0 }),
          populationChanged.allSatisfy({ populationKeys.contains($0) }),
          populationTransforms.count == members * 16,
          populationColours.count == members * 3 else { return nil }

    self.populationKeys = populationKeys
    self.populationCounts = populationCounts
    self.populationMeshes = populationMeshes
    self.populationFlags = populationFlags
    self.populationRevisions = populationRevisions
    self.populationRanges = populationRanges
    self.populationBounds = populationBounds
    self.populationPaths = populationPaths
    self.populationChanged = populationChanged
    self.populationTransforms = populationTransforms
    self.populationColours = populationColours
  }
}

extension FlutterStandardTypedData {
  fileprivate var floats: [Float]? {
    guard type == .float32 else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  fileprivate var int32s: [Int32]? {
    guard type == .int32 else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
  }

  fileprivate var int64s: [Int64]? {
    guard type == .int64 else { return nil }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Int64.self)) }
  }
}

public class OrbisFilamentPlugin: NSObject, FlutterPlugin {
  private let registry: FlutterTextureRegistry
  private var viewports: [Int64: Viewport] = [:]

  /// One thread for every viewport in the process.
  ///
  /// Shared rather than one each, because Filament adopts the thread that
  /// creates an engine and a second engine created on a different thread
  /// would be a second set of rules to keep. An editor with four viewports
  /// draws them one after another on this thread, which is what it did on the
  /// main thread anyway — the difference is which thread is not free while it
  /// happens.
  private let engineThread = EngineThread()

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      // Methods on iOS, properties on macOS. The same two things, reached
      // two ways, and the only reason this registration is not shared.
      let messenger = registrar.messenger()
      let textures = registrar.textures()
    #else
      let messenger = registrar.messenger
      let textures = registrar.textures
    #endif
    let channel = FlutterMethodChannel(
      name: "orbis_filament", binaryMessenger: messenger)
    let instance = OrbisFilamentPlugin(registry: textures)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "create":
      guard let args = call.arguments as? [String: Any],
            let width = args["width"] as? Int,
            let height = args["height"] as? Int else {
        result(FlutterError(code: "bad-args",
                            message: "create needs width and height",
                            details: nil))
        return
      }
      // On the engine's thread, because Filament adopts whichever thread
      // creates it and every call after this has to come from the same one.
      let made = engineThread.sync {
        OrbisRenderer(width: UInt32(width), height: UInt32(height))
      }
      guard let renderer = made else {
        result(FlutterError(code: "no-renderer",
                            message: "Filament could not start. Metal may be unavailable.",
                            details: nil))
        return
      }
      let texture = OrbisTexture(renderer: renderer)
      let textureId = registry.register(texture)
      let viewport = Viewport(textureId: textureId, renderer: renderer,
                              registry: registry, engine: engineThread)
      viewports[textureId] = viewport
      viewport.start()
      result(textureId)

    case "resize":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int,
            let width = args["width"] as? Int,
            let height = args["height"] as? Int else {
        result(FlutterError(code: "bad-args", message: "resize needs textureId, width, height", details: nil))
        return
      }
      viewports[Int64(textureId)]?.resize(width: UInt32(width), height: UInt32(height))
      result(nil)

    case "setScene":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int else {
        result(FlutterError(code: "bad-args", message: "setScene needs a textureId", details: nil))
        return
      }
      guard let scene = Scene(arguments: args) else {
        result(FlutterError(code: "bad-scene",
                            message: "setScene needs keys, float32 transforms (16 each), colours (3 each), flags, lights (16 floats each), fog (10 floats) and a camera.",
                            details: nil))
        return
      }
      guard let viewport = viewports[Int64(textureId)] else {
        result(nil)
        return
      }
      // Returned rather than logged: an editor can name the asset it could not
      // load, or the light it had to drop, instead of drawing something quietly
      // wrong and leaving somebody guessing.
      //
      // Answered when the scene is in rather than when it is asked for. Dart
      // is waiting on this call, but the platform thread is not, which is the
      // whole point: a model that takes half a second to read no longer takes
      // the application with it.
      viewport.apply(scene: scene) { notes in result(notes) }

    case "stats":
      guard let arguments = call.arguments as? [String: Any],
            let textureId = arguments["textureId"] as? Int64,
            let viewport = viewports[textureId] else {
        result(nil)
        return
      }
      // What each pass cost as well as what the whole frame did. Two numbers
      // per pass in the order they ran; the names stay on the other side,
      // where they already are.
      result([
        "gpuMilliseconds": viewport.gpuMilliseconds,
        "passTimings": viewport.passTimings,
      ])

    case "dispose":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int else {
        result(FlutterError(code: "bad-args", message: "dispose needs textureId", details: nil))
        return
      }
      let id = Int64(textureId)
      viewports.removeValue(forKey: id)?.dispose()
      registry.unregisterTexture(id)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
