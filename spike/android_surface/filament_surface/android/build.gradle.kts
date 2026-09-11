group = "dev.orbis.spike.filament_surface"
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

android {
    namespace = "dev.orbis.spike.filament_surface"

    compileSdk = 36

    // Pinned, not inherited. The Filament 1.76 Android release is built with a
    // recent NDK and its static archives carry LLVM bitcode-era metadata the
    // r27 linker reads differently; 28.2.13676358 is also Flutter 3.47's own
    // default, so app and plugin agree and Gradle does not fetch a second NDK.
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
        // wants API 24+ for the surface extensions it uses. The OpenGL ES
        // backend would run lower.
        minSdk = 24

        externalNativeBuild {
            cmake {
                // c++_static, not c++_shared. One native library in this .apk
                // links libc++, so there is nothing to share it with, and
                // static avoids shipping libc++_shared.so and the class of bug
                // where two libraries disagree about which libc++ they got.
                // The real Orbis plugin, which will have orbis_native alongside
                // this, should switch to c++_shared -- two libraries each with
                // their own static libc++ passing std:: types between them is
                // undefined behaviour.
                arguments += listOf("-DANDROID_STL=c++_static")
            }
        }

        // arm64 only. The emulator on this machine is arm64 and so is every
        // Android device worth profiling; building four ABIs against Filament's
        // static libs quadruples a link that is already the slowest step. The
        // release ships armeabi-v7a, x86 and x86_64 too, and CMakeLists picks
        // the directory by ${ANDROID_ABI}, so adding them is one line here.
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

    // Filament's static libs are huge and the linker is the long pole; keeping
    // debug symbols out of the packaged .so takes it from ~90 MB to ~9 MB with
    // no effect on what the spike proves.
    packaging {
        jniLibs {
            keepDebugSymbols += "**/liborbis_spike.so"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
