package dev.orbis.spike.filament_surface

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * The method channel, and nothing else.
 *
 * Deliberately thin. Everything the real Orbis plugin would need to forward
 * from Dart is here and it is a short list: which backend, what size, start,
 * stop, and read back what happened. No per-frame traffic crosses the channel
 * -- see FilamentSurfaceSession for why.
 */
class FilamentSurfacePlugin :
    FlutterPlugin,
    MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var session: FilamentSurfaceSession? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binding = flutterPluginBinding
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "filament_surface")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "start" -> {
                    session?.stop()
                    val registry = binding?.textureRegistry
                        ?: return result.error("no_registry", "No TextureRegistry", null)

                    val backend = when (call.argument<String>("backend")) {
                        "vulkan" -> 1
                        else -> 0
                    }
                    val width = call.argument<Int>("width") ?: 720
                    val height = call.argument<Int>("height") ?: 720

                    val s = FilamentSurfaceSession(registry)
                    session = s
                    result.success(s.start(backend, width, height))
                }

                "stop" -> {
                    session?.stop()
                    session = null
                    result.success(null)
                }

                "resize" -> {
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    session?.resize(width, height)
                    result.success(session?.describe() ?: emptyMap<String, Any>())
                }

                "recreateSurface" -> result.success(session?.recreateSurface() ?: emptyMap<String, Any>())

                "describe" -> result.success(session?.describe() ?: emptyMap<String, Any>())

                "stats" -> result.success(session?.stats() ?: emptyMap<String, Any>())

                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            // Including Error, not just Exception: an UnsatisfiedLinkError from
            // a mis-mangled JNI name or a missing .so is the single most likely
            // failure on a first Android build, and it is far more useful shown
            // in the app's own error text than buried in logcat.
            Log.e("OrbisSpike", "method ${call.method} failed", e)
            session = null
            result.error("spike_failed", "${e.javaClass.simpleName}: ${e.message}", null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        session?.stop()
        session = null
        channel.setMethodCallHandler(null)
        this.binding = null
    }
}
