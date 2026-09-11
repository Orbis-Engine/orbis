package dev.orbis.orbis_gallery

import android.os.Bundle
import android.system.Os
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

/**
 * Routes `adb shell am start --es KEY VALUE` intent extras into the process
 * environment, so lib/main.dart's `Platform.environment[...]` switches --
 * `ORBIS_EXAMPLE`, `ORBIS_YAW`, and the rest of the dozens main.dart's own
 * header comment lists -- and the native core's own `getenv()` reads
 * (`ORBIS_DUMP_FRAME`, `ORBIS_BACKEND`, `ORBIS_PACE`) work on Android exactly
 * as they do launching a macOS .app or an iOS simulator with real environment
 * variables set. Neither of those exists on Android: `adb shell` does not
 * pass its own environment to an app process forked from Zygote long before
 * that command ran, and `am start` has no equivalent of `env KEY=VALUE`.
 * What it does have is intent extras, so this bridges the two.
 *
 * `Os.setenv` (android.system.Os, a thin JNI wrapper the Bionic C library
 * backs) is a real `setenv(3)` in this process -- not a Java-only map -- so
 * it is visible to `getenv()` calls made from the native .so this plugin
 * loads, and to `dart:io`'s `Platform.environment`, both because they read
 * the same process-wide table. The ordering that matters: this runs before
 * `super.onCreate()`, which is what starts the Flutter engine and, with it,
 * the Dart isolate `main.dart` runs in -- so every variable set here is
 * already in the environment before anything downstream has a chance to
 * read it, on either side of the JNI boundary.
 *
 * Example: `adb shell am start -n dev.orbis.orbis_gallery/.MainActivity
 * --es ORBIS_EXAMPLE Decals --es ORBIS_DUMP_FRAME 30`.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        intent?.extras?.let { extras ->
            for (key in extras.keySet()) {
                val value = extras.get(key)?.toString() ?: continue
                try {
                    Os.setenv(key, value, true)
                } catch (e: Exception) {
                    // A key Android itself put in the extras (this activity
                    // was not launched with --es at all, say) is not
                    // necessarily a valid environment variable name; skipped
                    // rather than crashing the launch over it.
                    Log.w(TAG, "could not forward extra '$key' to the environment", e)
                }
            }
        }
        super.onCreate(savedInstanceState)
    }

    private companion object {
        const val TAG = "OrbisGallery"
    }
}
