import CoreVideo
import FlutterMacOS
import Foundation

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

    keys.withUnsafeBufferPointer { keyPointer in
      transforms.withUnsafeBufferPointer { transformPointer in
        colours.withUnsafeBufferPointer { colourPointer in
          meshes.withUnsafeBufferPointer { meshPointer in
            flags.withUnsafeBufferPointer { flagPointer in
              renderer.applyObjects(keyPointer.baseAddress!,
                                    transforms: transformPointer.baseAddress!,
                                    colours: colourPointer.baseAddress!,
                                    meshes: meshPointer.baseAddress!,
                                    flags: flagPointer.baseAddress!,
                                    paths: scene.paths,
                                    count: UInt32(scene.count))
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
    renderer.setCameraPosition(scene.cameraPosition,
                               target: scene.cameraTarget,
                               fieldOfView: scene.fieldOfView)
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

  /// How many floats one light occupies, and how many the fog does. Both
  /// match the packing on the Dart side; a mismatch is caught here as a
  /// refused message rather than there as a wrong-looking scene.
  private static let lightStride = 18
  private static let fogStride = 16

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
          let fogEnabled = arguments["fogEnabled"] as? Bool,
          let showBody = arguments["showBody"] as? Bool,
          let ambient = arguments["ambient"] as? Double,
          let aperture = arguments["aperture"] as? Double,
          let shutterSpeed = arguments["shutterSpeed"] as? Double,
          let sensitivity = arguments["sensitivity"] as? Double,
          let fieldOfView = arguments["fieldOfView"] as? Double else { return nil }

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
          skyColour.count == 3,
          cameraPosition.count == 3, cameraTarget.count == 3 else { return nil }

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
