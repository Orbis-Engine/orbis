import CoreVideo
import FlutterMacOS
import Foundation

// Under CocoaPods the renderer is in this same module; under Swift Package
// Manager it is its own target, because a package target holds one language
// and the renderer is Objective-C++. The import is conditional so one source
// file serves both.
#if canImport(orbis_filament_native)
  import orbis_filament_native
#endif

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
  private var displayLink: CVDisplayLink?
  private let startedAt = CFAbsoluteTimeGetCurrent()
  private let frameLock = NSLock()
  private var framePending = false

  init(textureId: Int64, renderer: OrbisRenderer, registry: FlutterTextureRegistry) {
    self.textureId = textureId
    self.renderer = renderer
    self.registry = registry
  }

  /// What a frame usually costs this viewport's GPU, in milliseconds.
  var gpuMilliseconds: Double { renderer.gpuMilliseconds() }

  func start() {
    // CVDisplayLink is soft-deprecated on recent macOS in favour of the
    // NSView-attached variant, but that needs a view we do not own — Flutter
    // owns the hierarchy and hands us only a texture id.
    var link: CVDisplayLink?
    guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
          let link else { return }

    CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
      guard let context else { return kCVReturnSuccess }
      Unmanaged<Viewport>.fromOpaque(context).takeUnretainedValue().tick()
      return kCVReturnSuccess
    }, Unmanaged.passUnretained(self).toOpaque())

    CVDisplayLinkStart(link)
    displayLink = link
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
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.renderer.render(atTime: time)
      self.registry.textureFrameAvailable(self.textureId)
      self.frameLock.lock()
      self.framePending = false
      self.frameLock.unlock()
    }
  }

  func resize(width: UInt32, height: UInt32) {
    renderer.resize(toWidth: width, height: height)
  }

  /// Applies a scene sent from Dart.
  ///
  /// Safe to call straight from the channel handler: channel calls and the
  /// frame both run on the main thread, so a scene can never be swapped out
  /// from under a render in progress.
  func apply(scene: Scene) {
    // An empty Swift array's base address is nil, and the renderer's pointers
    // are not nullable. Nothing is read through them when the count is zero,
    // so an empty scene borrows a valid address it will not touch.
    let keys = scene.count == 0 ? [Int64(0)] : scene.keys
    let transforms = scene.count == 0 ? [Float(0)] : scene.transforms
    let colours = scene.count == 0 ? [Float(0)] : scene.colours
    let meshes = scene.count == 0 ? [Int32(-1)] : scene.meshes
    let flags = scene.count == 0 ? [Int32(0)] : scene.flags
    let objectMaterials = scene.count == 0 ? [Int32(-1)] : scene.objectMaterials

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
                renderer.applyObjects(keyPointer.baseAddress!,
                                      transforms: transformPointer.baseAddress!,
                                      colours: colourPointer.baseAddress!,
                                      meshes: meshPointer.baseAddress!,
                                      flags: flagPointer.baseAddress!,
                                      materials: materialPointer.baseAddress!,
                                      paths: scene.paths,
                                      count: UInt32(scene.count))
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
  var notes: [String: String] { renderer.notes }

  func dispose() {
    if let displayLink {
      CVDisplayLinkStop(displayLink)
      self.displayLink = nil
    }
    renderer.dispose()
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
  private static let materialStride = 18
  private static let materialMaps = 5
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

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "orbis_filament", binaryMessenger: registrar.messenger)
    let instance = OrbisFilamentPlugin(registry: registrar.textures)
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
      guard let renderer = OrbisRenderer(width: UInt32(width), height: UInt32(height)) else {
        result(FlutterError(code: "no-renderer",
                            message: "Filament could not start. Metal may be unavailable.",
                            details: nil))
        return
      }
      let texture = OrbisTexture(renderer: renderer)
      let textureId = registry.register(texture)
      let viewport = Viewport(textureId: textureId, renderer: renderer, registry: registry)
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
      viewport.apply(scene: scene)
      // Returned rather than logged: an editor can name the asset it could not
      // load, or the light it had to drop, instead of drawing something quietly
      // wrong and leaving somebody guessing.
      result(viewport.notes)

    case "stats":
      guard let arguments = call.arguments as? [String: Any],
            let textureId = arguments["textureId"] as? Int64,
            let viewport = viewports[textureId] else {
        result(nil)
        return
      }
      result(["gpuMilliseconds": viewport.gpuMilliseconds])

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
