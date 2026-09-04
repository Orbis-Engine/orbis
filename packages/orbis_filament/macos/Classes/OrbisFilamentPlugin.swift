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

  func dispose() {
    if let displayLink {
      CVDisplayLinkStop(displayLink)
      self.displayLink = nil
    }
    renderer.dispose()
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
