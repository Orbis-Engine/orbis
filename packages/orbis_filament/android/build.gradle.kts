group = "dev.orbis.filament"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// Fetches the Filament Android release and compiles this package's materials
// -- setup.sh, the Android-shaped counterpart to ../darwin/setup.sh, which
// runs from the podspec's prepare_command on Apple. Swift Package Manager and
// CocoaPods both have a hook for "run this before building"; Gradle's is a
// task dependency rather than a lifecycle callback, wired up below so every
// build (an IDE sync included) runs it. It is idempotent and, once the
// symlink and the materials exist, fast -- a few stat calls and matc skipping
// everything whose source has not changed -- so paying the cost on every
// invocation is cheaper than a manual step somebody forgets.
val orbisFilamentSetup =
    tasks.register<Exec>("orbisFilamentSetup") {
        workingDir = projectDir
        commandLine("bash", "setup.sh")
        // Always run: setup.sh's own staleness checks (mtimes, and the matc
        // flags stamp) are what decide whether there is any real work to do,
        // not Gradle's up-to-date tracking -- which cannot see a change to a
        // .mat file two directories up in darwin/materials/ without being
        // told every such input by hand.
        outputs.upToDateWhen { false }
    }

android {
    namespace = "dev.orbis.filament"

    compileSdk = 36

    // Pinned, not inherited. The Filament 1.76 Android release is built with
    // a recent NDK and its static archives carry LLVM bitcode-era metadata
    // the r27 linker reads differently; 28.2.13676358 is also Flutter
    // 3.47's own default, so the app and this plugin agree and Gradle does
    // not fetch a second NDK. Proven in the android-spike.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // 24 because that is Flutter's floor and Filament's Vulkan backend
        // wants API 24+ for the surface extensions it uses (the android-spike's
        // finding); the OpenGL ES backend would run lower.
        minSdk = 24

        externalNativeBuild {
            cmake {
                // c++_static, not c++_shared: this plugin links exactly one
                // native library (Filament and the renderer core together,
                // as the spike does), so there is nothing to share
                // libc++_shared.so with, and static avoids shipping it plus
                // the class of bug where two libraries disagree about which
                // libc++ they linked. Revisit if a second native .so ever
                // joins this one in the same APK and the two pass C++ types
                // across the boundary between them -- two static libc++
                // copies in one process is undefined behaviour for that.
                arguments += listOf("-DANDROID_STL=c++_static")
            }
        }

        // arm64-v8a only, matching the android-spike: it is this emulator's
        // ABI and every device worth profiling. The Filament release carries
        // armeabi-v7a, x86 and x86_64 too, and CMakeLists already picks the
        // lib directory by ${ANDROID_ABI}, so adding them back is one line.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// The CMake/NDK build's own tasks are created by AGP per variant and per ABI,
// late and by name rather than by a reference this file can hold directly --
// so this reaches them the same way: by matching the names AGP is documented
// to use, which cover both the configure and the build step of every variant.
afterEvaluate {
    tasks
        .matching { task ->
            task.name.startsWith("configureCMake") ||
                task.name.startsWith("buildCMake") ||
                task.name.startsWith("externalNativeBuild")
        }
        .configureEach { dependsOn(orbisFilamentSetup) }
}
