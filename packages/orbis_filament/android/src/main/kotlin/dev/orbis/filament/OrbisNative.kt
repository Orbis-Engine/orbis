package dev.orbis.filament

import android.view.Surface

/**
 * The JNI surface of liborbis_filament_native.so, and nothing else.
 *
 * A Kotlin `object`, so every declaration below is an instance method on the
 * singleton and the C++ side (orbis_jni.cpp) receives a `jobject`/`jclass` it
 * ignores -- see that file's own header comment for why this is safe despite
 * looking like a mismatch. `handle` is the C++ OrbisHandle*, carried as a
 * jlong; zero means none, matching the android-spike's SpikeRenderer.kt.
 *
 * One object shared by every viewport, the same as the ABI it wraps: each
 * external fun's first argument is which renderer it is about, exactly as
 * orbis_renderer.h's own C functions all take the orbis_renderer* they act
 * on rather than there being one instance per renderer.
 *
 * Every `Int` return here is an `orbis_result` (orbis_renderer.h): 0 is
 * ORBIS_OK, negative is a specific refusal. OrbisFilamentPlugin does not
 * branch on which negative value it got -- the ABI's contract is that a
 * refused call already logged why, and there is nothing a Flutter host can
 * do about "the renderer stopped" beyond disposing it, which it will
 * eventually be told to do anyway.
 */
internal object OrbisNative {
    init {
        System.loadLibrary("orbis_filament_native")
    }

    // ---- Lifetime -----------------------------------------------------

    /**
     * [backendOrdinal] matches OrbisBackend in orbis_renderer.h exactly: 0
     * default, 1 Metal, 2 Vulkan, 3 OpenGL, 4 WebGPU -- Metal is refused at
     * the backend-candidates level on Android, so only 0, 2 and 3 are real
     * choices here. [surface] may be null for a headless renderer. Returns
     * 0 if Filament would not start.
     */
    external fun nativeCreate(backendOrdinal: Int, surface: Surface?, width: Int, height: Int): Long

    external fun nativeDestroy(handle: Long)

    external fun nativeBackend(handle: Long): Int

    external fun nativeResize(handle: Long, width: Int, height: Int): Int

    /**
     * Replaces the presentation surface after construction -- see
     * orbis_renderer_attach_surface's own comment for why this exists and
     * what a false return does and does not mean (the renderer is not
     * marked failed the way a scene call's refusal would).
     */
    external fun nativeAttachSurface(handle: Long, surface: Surface?, width: Int, height: Int): Boolean

    external fun nativeDetachSurface(handle: Long): Int

    external fun nativeDraw(handle: Long, seconds: Double): Int

    // ---- The scene ------------------------------------------------------
    //
    // One per orbis_renderer_apply_*/set_* call, in the ABI's own order.
    // Every array may be empty (Kotlin `FloatArray(0)` etc.) for "this part
    // of the scene has nothing to say", which borrows as a null pointer on
    // the C++ side -- see orbis_jni.cpp's Floats/Ints/etc. Never null itself:
    // OrbisScene.kt fills in the same empty-array defaults
    // OrbisFilamentPlugin.swift's Scene.init does, so every call below
    // always has something to pass.

    external fun nativeApplyObjects(
        handle: Long,
        keys: LongArray,
        transforms: FloatArray,
        colours: FloatArray,
        meshes: IntArray,
        flags: IntArray,
        materials: IntArray,
        morphCounts: IntArray,
        morphWeights: FloatArray,
        paths: Array<String>,
    ): Int

    external fun nativeSetBatching(handle: Long, enabled: Boolean): Int

    external fun nativeSetDepthPrepass(handle: Long, enabled: Boolean): Int

    external fun nativeApplyMaterials(
        handle: Long,
        keys: LongArray,
        flags: IntArray,
        params: FloatArray,
        maps: IntArray,
        texturePaths: Array<String>,
        textureSrgb: IntArray,
        videos: IntArray,
    ): Int

    external fun nativeSetPipeline(handle: Long, params: FloatArray): Int

    external fun nativeApplyVideos(
        handle: Long,
        keys: LongArray,
        flags: IntArray,
        params: FloatArray,
        paths: Array<String>,
    ): Int

    external fun nativeApplyLights(
        handle: Long,
        keys: LongArray,
        kinds: IntArray,
        flags: IntArray,
        params: FloatArray,
    ): Int

    external fun nativeApplyDecals(
        handle: Long,
        params: FloatArray,
        images: IntArray,
        paths: Array<String>,
    ): Int

    external fun nativeSetFog(handle: Long, enabled: Boolean, params: FloatArray): Int

    external fun nativeSetPostProcess(handle: Long, params: FloatArray): Int

    external fun nativeApplyProbes(handle: Long, keys: LongArray, params: FloatArray): Int

    external fun nativeApplyField(handle: Long, params: FloatArray, from: String): Int

    external fun nativeSetEnvironment(
        handle: Long,
        radiance: String,
        skybox: String,
        params: FloatArray,
    ): Int

    external fun nativeSetRenderGraph(
        handle: Long,
        passes: FloatArray,
        targets: FloatArray,
        names: Array<String>,
    ): Int

    external fun nativeSetGodRays(handle: Long, godRays: FloatArray, distortions: FloatArray): Int

    external fun nativeApplyPopulations(
        handle: Long,
        keys: IntArray,
        counts: IntArray,
        meshes: IntArray,
        flags: IntArray,
        revisions: IntArray,
        ranges: FloatArray,
        bounds: FloatArray,
        paths: Array<String>,
        changed: IntArray,
        transforms: FloatArray,
        colours: FloatArray,
    ): Int

    external fun nativeApplySplats(
        handle: Long,
        keys: IntArray,
        flags: IntArray,
        revisions: IntArray,
        params: FloatArray,
        paths: Array<String>,
        changed: IntArray,
        changedCounts: IntArray,
        data: ByteArray,
    ): Int

    external fun nativeSetSky(handle: Long, enabled: Boolean, params: FloatArray): Int

    external fun nativeSetPrecipitation(handle: Long, enabled: Boolean, params: FloatArray): Int

    external fun nativeSetSkyColour(
        handle: Long,
        colour: FloatArray,
        ambient: Float,
        showBody: Boolean,
    ): Int

    external fun nativeSetCamera(
        handle: Long,
        position: FloatArray,
        target: FloatArray,
        fieldOfView: Float,
        orthographic: Boolean,
        viewHeight: Float,
        at: Double,
    ): Int

    external fun nativeSetExposure(handle: Long, aperture: Float, shutter: Float, sensitivity: Float): Int

    external fun nativeSetOutline(handle: Long, keys: LongArray, params: FloatArray): Int

    // ---- What it drew, and what it cost --------------------------------

    external fun nativeGpuMilliseconds(handle: Long): Double

    /** [batchedObjects, batchGroups]. */
    external fun nativeBatching(handle: Long): IntArray

    /** Interleaved [ms0, drawn0, ms1, drawn1, ...], one pair per pass. */
    external fun nativePassTimings(handle: Long): DoubleArray

    // ---- What it could not do -------------------------------------------

    /** Flattened [about0, saying0, about1, saying1, ...]. */
    external fun nativeNotes(handle: Long): Array<String>
}
