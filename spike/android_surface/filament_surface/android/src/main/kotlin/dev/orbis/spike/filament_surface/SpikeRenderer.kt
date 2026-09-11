package dev.orbis.spike.filament_surface

/**
 * The JNI surface of liborbis_spike.so, and nothing else.
 *
 * A Kotlin `object`, so every declaration below is an instance method on the
 * singleton and the C++ counterpart receives a `jobject` it ignores. The names
 * on the C side are the mangled form of this exact package and object name --
 * `dev.orbis.spike.filament_surface.SpikeRenderer` becomes
 * `Java_dev_orbis_spike_filament_1surface_SpikeRenderer_`, because JNI escapes
 * the underscore in `filament_surface` as `_1`. Rename either half and the
 * library still loads, then throws UnsatisfiedLinkError on the first call.
 *
 * `handle` is the C++ SpikeRenderer*, carried as a jlong. Zero means none.
 */
internal object SpikeRenderer {
    init {
        System.loadLibrary("orbis_spike")
    }

    /** 0 = OpenGL ES, 1 = Vulkan. Returns 0 if the backend would not start. */
    external fun nativeCreate(backendOrdinal: Int): Long

    external fun nativeAttachSurface(handle: Long, surface: Any, width: Int, height: Int): Boolean

    external fun nativeDetachSurface(handle: Long)

    external fun nativeResize(handle: Long, width: Int, height: Int)

    external fun nativeRender(handle: Long, frameTimeNanos: Long): Boolean

    external fun nativeHasSurface(handle: Long): Boolean

    /** Newline-separated `key=value`. Backend, feature levels, size. */
    external fun nativeDescribe(handle: Long): String

    /** Newline-separated `key=value`. Frame counts and intervals. */
    external fun nativeStats(handle: Long): String

    external fun nativeDestroy(handle: Long)
}
