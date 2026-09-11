package dev.orbis.spike.filament_surface

import android.util.Log
import android.view.Choreographer
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * One Filament engine drawing into one Flutter texture.
 *
 * This is the part of the spike that is genuinely Android-shaped. The Filament
 * side is the same everywhere; what is different here is that the thing being
 * drawn into can be taken away and given back at any moment, and that the
 * frame clock is the display's, not Flutter's.
 *
 * ## The presentation path
 *
 * 1. `TextureRegistry.createSurfaceProducer()` registers a texture with the
 *    Flutter engine and returns a handle with an `id()`. That id is what Dart's
 *    `Texture(textureId:)` widget names.
 * 2. `producer.getSurface()` gives an `android.view.Surface` -- the producer end
 *    of a buffer queue whose consumer is the Flutter compositor.
 * 3. JNI passes that Surface to `ANativeWindow_fromSurface`.
 * 4. Filament's `createSwapChain(ANativeWindow*)` builds an EGLSurface (OpenGL
 *    ES) or a VkSurfaceKHR (Vulkan) on it.
 * 5. Every `endFrame()` queues a buffer; `producer.scheduleFrame()` tells
 *    Flutter to composite.
 *
 * No pixel is read back and no copy is made. That is the whole point, and it is
 * why this is a different mechanism from Apple's CVPixelBuffer path rather than
 * a port of it.
 *
 * ## Why Choreographer and not Flutter's frame callbacks
 *
 * Filament is driven from `Choreographer.postFrameCallback`, the same vsync
 * signal the Android view system uses, for three reasons:
 *
 *  - `beginFrame()` wants a real vsync timestamp. Choreographer hands one
 *    straight to `doFrame`; Flutter's `SchedulerBinding.addPostFrameCallback`
 *    gives a Duration since engine start, which is not the same clock.
 *  - The texture is an independent producer. Flutter composites whatever the
 *    buffer queue last accepted, so the render loop does not have to be in
 *    lockstep with Flutter's build/paint, and coupling them would make a slow
 *    Dart frame stall the renderer for no reason.
 *  - Driving from Dart means a platform-channel hop per frame. At 60 Hz that is
 *    a message every 16 ms carrying nothing, to start work the native side
 *    could have started itself.
 *
 * The cost is that this loop must be stopped by hand when there is no surface,
 * which is what the callbacks below are for.
 *
 * ## Threading
 *
 * Everything here is on the Android main thread: that is where plugin method
 * calls arrive, where the SurfaceProducer callbacks arrive, and where
 * Choreographer posts. Filament's Engine is not thread safe, so one thread for
 * all of it is the cheap correct answer. It stays cheap because Filament owns a
 * driver thread of its own -- `render()` and `endFrame()` record commands and
 * hand them over rather than talking to the GPU here.
 */
internal class FilamentSurfaceSession(
    private val textureRegistry: TextureRegistry,
) : TextureRegistry.SurfaceProducer.Callback,
    Choreographer.FrameCallback {

    private var producer: TextureRegistry.SurfaceProducer? = null
    private var handle: Long = 0L
    private var running = false

    /**
     * The Surface currently behind the native swap chain, kept only to notice
     * when Flutter has handed out a different one. Identity, not equality:
     * Surface does not override equals and two Surfaces onto the same
     * SurfaceTexture are still two swap chains' worth of work.
     */
    private var attachedSurface: Surface? = null

    // Lifecycle evidence. Shown in the app so a screenshot proves the callbacks
    // fired, rather than only logcat proving it.
    private var availableCount = 0
    private var cleanupCount = 0
    private var reattachCount = 0
    private var lastLifecycleEvent = "none"

    val textureId: Long
        get() = producer?.id() ?: -1L

    fun start(
        backendOrdinal: Int,
        width: Int,
        height: Int,
        requestFeatureLevel3: Boolean = false,
    ): Map<String, Any> {
        check(handle == 0L) { "session already started" }

        handle = SpikeRenderer.nativeCreate(backendOrdinal, requestFeatureLevel3)
        if (handle == 0L) {
            // A null Engine is the honest failure for a backend the device
            // cannot serve -- no Vulkan driver, or an OpenGL ES below what
            // Filament needs. Reported up rather than swallowed, because "black
            // texture" and "no engine" want completely different next steps.
            throw IllegalStateException(
                "Filament refused to start on backend ordinal $backendOrdinal " +
                    "(0=OpenGL ES, 1=Vulkan)${if (requestFeatureLevel3) " at requested feature level 3" else ""}. " +
                    "See logcat tag Filament for the driver's reason.",
            )
        }

        val p = textureRegistry.createSurfaceProducer()
        p.setSize(width, height)
        p.setCallback(this)
        producer = p
        Log.i(TAG, "producer created: textureId=${p.id()} size=${p.width}x${p.height}")

        attach("start")

        running = true
        Choreographer.getInstance().postFrameCallback(this)

        return describe()
    }

    fun stop() {
        running = false
        Choreographer.getInstance().removeFrameCallback(this)

        producer?.let {
            it.setCallback(null)
            it.release()
        }
        producer = null
        attachedSurface = null

        if (handle != 0L) {
            SpikeRenderer.nativeDestroy(handle)
            handle = 0L
        }
        Log.i(TAG, "session stopped")
    }

    fun resize(width: Int, height: Int) {
        val p = producer ?: return
        if (width <= 0 || height <= 0) return
        if (p.width == width && p.height == height) return

        p.setSize(width, height)
        SpikeRenderer.nativeResize(handle, width, height)

        // setSize may or may not replace the underlying Surface depending on
        // how the engine chose to resize the buffer queue. Ask again and only
        // rebuild the swap chain if it actually changed -- rebuilding blindly
        // on every resize frame makes a drag-resize stutter badly.
        val current = p.surface
        if (current !== attachedSurface) {
            Log.i(TAG, "resize handed out a new Surface; rebuilding swap chain")
            attach("resize")
        }
        Log.i(TAG, "resized to ${width}x$height")
    }

    /**
     * Forces the surface-loss path on demand.
     *
     * `getForcedNewSurface()` is the engine's own "throw this one away and make
     * me another", which is exactly what happens on backgrounding -- so this
     * exercises the real code path rather than a mock of it, and does it from a
     * button instead of requiring the app to be backgrounded and resumed.
     */
    fun recreateSurface(): Map<String, Any> {
        val p = producer ?: return describe()

        Log.i(TAG, "forcing surface loss")
        SpikeRenderer.nativeDetachSurface(handle)
        attachedSurface = null

        val fresh = p.forcedNewSurface
        val ok = SpikeRenderer.nativeAttachSurface(handle, fresh, p.width, p.height)
        attachedSurface = if (ok) fresh else null
        reattachCount++
        lastLifecycleEvent = "forcedRecreate(ok=$ok)"
        Log.i(TAG, "forced surface recreate: attached=$ok")
        return describe()
    }

    // ---- SurfaceProducer.Callback ------------------------------------------
    //
    // Flutter 3.47 names these onSurfaceAvailable/onSurfaceCleanup and keeps
    // onSurfaceCreated/onSurfaceDestroyed as the older spelling. Both pairs are
    // implemented and forwarded to one place, so the spike behaves the same
    // whichever the running engine decides to call.

    override fun onSurfaceAvailable() {
        availableCount++
        lastLifecycleEvent = "onSurfaceAvailable#$availableCount"
        Log.i(TAG, "onSurfaceAvailable (#$availableCount)")
        attach("onSurfaceAvailable")
        // The loop stops itself while there is no surface; restart it.
        if (running) {
            Choreographer.getInstance().removeFrameCallback(this)
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onSurfaceCleanup() {
        cleanupCount++
        lastLifecycleEvent = "onSurfaceCleanup#$cleanupCount"
        Log.i(TAG, "onSurfaceCleanup (#$cleanupCount)")
        releaseSurface()
    }

    @Deprecated("Flutter's older spelling of onSurfaceAvailable", ReplaceWith("onSurfaceAvailable()"))
    override fun onSurfaceCreated() {
        onSurfaceAvailable()
    }

    @Deprecated("Flutter's older spelling of onSurfaceCleanup", ReplaceWith("onSurfaceCleanup()"))
    override fun onSurfaceDestroyed() {
        onSurfaceCleanup()
    }

    // ---- Choreographer -----------------------------------------------------

    override fun doFrame(frameTimeNanos: Long) {
        if (!running || handle == 0L) return

        // Re-post first. If render() throws, the next frame still comes and the
        // app keeps compositing rather than freezing on a half-drawn texture.
        Choreographer.getInstance().postFrameCallback(this)

        if (!SpikeRenderer.nativeHasSurface(handle)) return

        if (SpikeRenderer.nativeRender(handle, frameTimeNanos)) {
            // Tell Flutter there is something new in the buffer queue. Without
            // this the texture shows whatever it last composited and the cube
            // sits frozen even though Filament is drawing every vsync.
            producer?.scheduleFrame()
        }
    }

    // ---- internals ---------------------------------------------------------

    private fun attach(reason: String): Boolean {
        val p = producer ?: return false
        if (handle == 0L) return false

        val surface = p.surface
        if (surface == null || !surface.isValid) {
            Log.w(TAG, "attach($reason): no valid Surface yet")
            return false
        }
        if (surface === attachedSurface) {
            return true
        }

        val ok = SpikeRenderer.nativeAttachSurface(handle, surface, p.width, p.height)
        attachedSurface = if (ok) surface else null
        Log.i(TAG, "attach($reason): ${if (ok) "swap chain up" else "FAILED"} at ${p.width}x${p.height}")
        return ok
    }

    private fun releaseSurface() {
        if (handle == 0L) return
        // Native side destroys the swap chain, waits for the driver thread to
        // drain, then releases the ANativeWindow. It must complete before this
        // returns: Flutter destroys the Surface as soon as the callback does,
        // and a driver still holding it is a crash.
        SpikeRenderer.nativeDetachSurface(handle)
        attachedSurface = null
    }

    fun describe(): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        out["textureId"] = textureId
        if (handle != 0L) {
            out.putAll(parse(SpikeRenderer.nativeDescribe(handle)))
        }
        out["surfaceAvailableCount"] = availableCount
        out["surfaceCleanupCount"] = cleanupCount
        out["forcedReattachCount"] = reattachCount
        out["lastLifecycleEvent"] = lastLifecycleEvent
        out["hasSurface"] = handle != 0L && SpikeRenderer.nativeHasSurface(handle)
        return out
    }

    fun stats(): Map<String, Any> {
        if (handle == 0L) return emptyMap()
        return parse(SpikeRenderer.nativeStats(handle))
    }

    private fun parse(raw: String): Map<String, String> =
        raw.lineSequence()
            .filter { it.isNotBlank() }
            .mapNotNull { line ->
                val i = line.indexOf('=')
                if (i <= 0) null else line.substring(0, i) to line.substring(i + 1)
            }
            .toMap()

    private companion object {
        const val TAG = "OrbisSpike"
    }
}
