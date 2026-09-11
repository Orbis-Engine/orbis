package dev.orbis.filament

import android.util.Log
import android.view.Choreographer
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * One Filament engine drawing into one Flutter texture -- the real renderer's
 * counterpart to the android-spike's `FilamentSurfaceSession`, which this
 * follows closely for the presentation path and the surface lifecycle (see
 * that spike's README for why each piece of this is shaped the way it is)
 * while speaking the full `orbis_filament` protocol instead of a hardcoded
 * cube.
 *
 * ## Threading
 *
 * Everything here runs on the Android main thread: plugin method calls,
 * `SurfaceProducer` lifecycle callbacks and `Choreographer` frame callbacks
 * all arrive there, and keeping this on the one thread they already share
 * removes a whole class of bug, exactly as the spike found. This is a real
 * difference from the Apple plugin, which gives Filament a dedicated engine
 * thread specifically so a slow scene load -- reading a glTF model off disk
 * can be half a second -- does not freeze the app; see the top-level report
 * for why that trade was made here and what it costs.
 *
 * ## Frame timing
 *
 * `orbis_renderer_draw`'s `seconds` only drives the placeholder cube's idle
 * spin before a host has sent a scene (`drawAtTime` in the core) and
 * whatever frame-to-frame deltas internal effects derive from consecutive
 * calls; a scene's own animation is carried by the camera's `at` timestamp
 * in `setScene`, aligned to the host's clock rather than this one. Seconds
 * since this viewport started, from Choreographer's vsync clock -- the same
 * quantity CFAbsoluteTimeGetCurrent() - startedAt is on the Apple side.
 */
internal class OrbisViewport(
    private val textureRegistry: TextureRegistry,
) : TextureRegistry.SurfaceProducer.Callback,
    Choreographer.FrameCallback {

    private var producer: TextureRegistry.SurfaceProducer? = null
    private var handle: Long = 0L
    private var running = false
    private var firstFrameNanos: Long = 0L

    /** Identity, not equality -- see the spike's session for why. */
    private var attachedSurface: Surface? = null

    val textureId: Long
        get() = producer?.id() ?: -1L

    /** Starts the engine and the frame loop. Throws if Filament refused to start. */
    fun start(width: Int, height: Int): Long {
        check(handle == 0L) { "viewport already started" }

        val p = textureRegistry.createSurfaceProducer()
        p.setSize(width, height)
        p.setCallback(this)
        producer = p

        // Whatever Surface the producer already has, if it is valid yet --
        // it usually is, but attach()/onSurfaceAvailable below still handles
        // the case where it is not ready until a callback says so. ORBIS_
        // BACKEND_DEFAULT (0): the platform's own choice (orbis::
        // backendCandidates prefers Vulkan then OpenGL ES off Apple), or
        // whatever ORBIS_BACKEND names, set as a real process environment
        // variable by MainActivity from an adb/intent extra before the
        // engine starts -- see MainActivity's own comment for why that
        // reaches Platform.environment on the Dart side too, for free.
        val initial = p.surface?.takeIf { it.isValid }
        handle = OrbisNative.nativeCreate(ORBIS_BACKEND_DEFAULT, initial, width, height)
        if (handle == 0L) {
            p.setCallback(null)
            p.release()
            producer = null
            throw IllegalStateException(
                "Filament could not start. No backend (Vulkan, then OpenGL ES) was available.")
        }
        attachedSurface = initial
        Log.i(TAG, "viewport started: textureId=${p.id()} size=${p.width}x${p.height}")

        running = true
        Choreographer.getInstance().postFrameCallback(this)
        return textureId
    }

    fun resize(width: Int, height: Int) {
        val p = producer ?: return
        if (width <= 0 || height <= 0) return
        if (p.width == width && p.height == height) return
        p.setSize(width, height)
        OrbisNative.nativeResize(handle, width, height)

        // setSize may or may not hand out a new Surface depending on how the
        // producer chose to resize its buffer queue; rebuild the swap chain
        // only if it actually did, exactly as the spike's session does.
        val current = p.surface
        if (current !== attachedSurface) attach("resize")
    }

    /**
     * Applies a scene, then reports what it could not do. [answered] runs on
     * the main thread with the notes -- unlike the Apple plugin there is no
     * separate engine thread to hop off of here, but the shape matches so a
     * future move to one changes nothing above this call.
     */
    fun applyScene(scene: OrbisScene, answered: (Map<String, String>) -> Unit) {
        if (handle == 0L) {
            answered(emptyMap())
            return
        }
        scene.applyTo(handle)
        val notes = OrbisNative.nativeNotes(handle)
        val out = LinkedHashMap<String, String>(notes.size / 2)
        var i = 0
        while (i + 1 < notes.size) {
            out[notes[i]] = notes[i + 1]
            i += 2
        }
        answered(out)
    }

    fun stats(): Map<String, Any?> {
        if (handle == 0L) return emptyMap()
        return mapOf(
            "gpuMilliseconds" to OrbisNative.nativeGpuMilliseconds(handle),
            "passTimings" to OrbisNative.nativePassTimings(handle),
            "batching" to OrbisNative.nativeBatching(handle),
        )
    }

    fun dispose() {
        running = false
        Choreographer.getInstance().removeFrameCallback(this)

        producer?.let {
            it.setCallback(null)
            it.release()
        }
        producer = null
        attachedSurface = null

        if (handle != 0L) {
            OrbisNative.nativeDestroy(handle)
            handle = 0L
        }
        Log.i(TAG, "viewport disposed")
    }

    // ---- SurfaceProducer.Callback -----------------------------------------
    //
    // Both spellings implemented and forwarded to one place, as the spike's
    // session does, so this behaves the same whichever pair the running
    // Flutter engine calls.

    override fun onSurfaceAvailable() {
        Log.i(TAG, "onSurfaceAvailable")
        attach("onSurfaceAvailable")
        if (running) {
            Choreographer.getInstance().removeFrameCallback(this)
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    override fun onSurfaceCleanup() {
        Log.i(TAG, "onSurfaceCleanup")
        if (handle != 0L) OrbisNative.nativeDetachSurface(handle)
        attachedSurface = null
    }

    @Deprecated("Flutter's older spelling", ReplaceWith("onSurfaceAvailable()"))
    override fun onSurfaceCreated() {
        onSurfaceAvailable()
    }

    @Deprecated("Flutter's older spelling", ReplaceWith("onSurfaceCleanup()"))
    override fun onSurfaceDestroyed() {
        onSurfaceCleanup()
    }

    // ---- Choreographer ------------------------------------------------

    override fun doFrame(frameTimeNanos: Long) {
        if (!running || handle == 0L) return
        // Re-post first: if draw throws, the next frame still comes rather
        // than the app freezing on a half-drawn texture.
        Choreographer.getInstance().postFrameCallback(this)

        if (attachedSurface == null) return
        if (firstFrameNanos == 0L) firstFrameNanos = frameTimeNanos
        val seconds = (frameTimeNanos - firstFrameNanos) / 1_000_000_000.0
        if (OrbisNative.nativeDraw(handle, seconds) == 0) {
            producer?.scheduleFrame()
        }
    }

    // ---- internals ------------------------------------------------------

    private fun attach(reason: String): Boolean {
        val p = producer ?: return false
        if (handle == 0L) return false
        val surface = p.surface
        if (surface == null || !surface.isValid) {
            Log.w(TAG, "attach($reason): no valid Surface yet")
            return false
        }
        if (surface === attachedSurface) return true

        val ok = OrbisNative.nativeAttachSurface(handle, surface, p.width, p.height)
        attachedSurface = if (ok) surface else null
        Log.i(TAG, "attach($reason): ${if (ok) "swap chain up" else "FAILED"} at ${p.width}x${p.height}")
        return ok
    }

    private companion object {
        const val TAG = "OrbisFilament"

        // Matches OrbisBackend in orbis_renderer.h.
        const val ORBIS_BACKEND_DEFAULT = 0
    }
}
