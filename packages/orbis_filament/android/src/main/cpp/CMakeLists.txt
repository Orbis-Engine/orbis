cmake_minimum_required(VERSION 3.22.1)
project(orbis_filament_native LANGUAGES CXX)

# Filament 1.76's headers are C++17 and its public API uses inline
# std::string_view and structured bindings; the renderer core matches it.
# Proven by the android-spike: 17 is the floor, and anything newer changes no
# ABI because this links the release's own prebuilt static archives rather
# than rebuilding them.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# third_party/filament is the symlink (or fetched copy) setup.sh makes onto
# Filament's unpacked Android release. Nothing is copied and nothing is
# downloaded during the Gradle build itself -- see ../../../setup.sh.
set(FILAMENT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/filament")
get_filename_component(FILAMENT_DIR "${FILAMENT_DIR}" ABSOLUTE)

if(NOT EXISTS "${FILAMENT_DIR}/include/filament/Engine.h")
    message(FATAL_ERROR
        "No Filament Android release at ${FILAMENT_DIR}. Run "
        "packages/orbis_filament/android/setup.sh first.")
endif()

set(FILAMENT_LIB_DIR "${FILAMENT_DIR}/lib/${ANDROID_ABI}")
if(NOT EXISTS "${FILAMENT_LIB_DIR}")
    message(FATAL_ERROR "Filament's Android release has no libs for ABI ${ANDROID_ABI}")
endif()

# The portable renderer core. Referenced from where it lives under darwin/ --
# not copied -- so the same source compiles for every platform and a change
# to one is a change for all of them. See this package's setup.sh for why the
# materials it #includes have to be compiled into the same directory darwin's
# setup.sh uses, and the top-level report for whether this pair of platform
# directories should eventually move out from under darwin/ into a shared
# native/ one now that there is a second platform reading it.
set(ORBIS_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../darwin/orbis_filament/Sources/orbis_filament_native")
get_filename_component(ORBIS_CORE_DIR "${ORBIS_CORE_DIR}" ABSOLUTE)

if(NOT EXISTS "${ORBIS_CORE_DIR}/generated/lit_opaque_material.h")
    message(FATAL_ERROR
        "No compiled materials at ${ORBIS_CORE_DIR}/generated. Run "
        "packages/orbis_filament/android/setup.sh first.")
endif()

add_library(orbis_filament_native SHARED
    # The JNI bridge: Android-only, lives beside this file.
    orbis_jni.cpp

    # The portable core, its C ABI, and every helper it composes with. Not
    # OrbisRenderer.mm, OrbisSurfaceApple.mm, OrbisPlatformApple.mm or
    # OrbisTexture.m -- those are Apple's Objective-C++ wrapper and are never
    # built here; see PORTING.md's "What is still Apple's, and why".
    "${ORBIS_CORE_DIR}/OrbisRendererCore.cpp"
    "${ORBIS_CORE_DIR}/OrbisRendererC.cpp"
    "${ORBIS_CORE_DIR}/OrbisBackend.cpp"
    "${ORBIS_CORE_DIR}/OrbisPlatform.cpp"
    "${ORBIS_CORE_DIR}/OrbisSurfaceHeadless.cpp"
    "${ORBIS_CORE_DIR}/OrbisDecals.cpp"
    "${ORBIS_CORE_DIR}/OrbisOutline.cpp"
    "${ORBIS_CORE_DIR}/OrbisShadows.cpp"
    "${ORBIS_CORE_DIR}/OrbisSplats.cpp"
    "${ORBIS_CORE_DIR}/OrbisSplatSet.cpp"
    "${ORBIS_CORE_DIR}/OrbisMotionBlur.cpp"
    "${ORBIS_CORE_DIR}/ScreenEffects.cpp"
)

target_include_directories(orbis_filament_native PRIVATE
    "${FILAMENT_DIR}/include"
    "${ORBIS_CORE_DIR}"
    "${ORBIS_CORE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}")

# ORBIS_PLATFORM_APPLE (OrbisPlatform.h) is already 0 here with no macro of
# ours needed: it is defined from __APPLE__, which this build never sets.
# ORBIS_PLATFORM_PORTABLE exists only to force that same 0 when compiling for
# Apple with the portable answers instead of the real ones (proving them on a
# Mac before they are needed somewhere that is not one) -- Android does not
# need to ask for what it already gets.
target_compile_options(orbis_filament_native PRIVATE -Wall -Wextra -Wno-unused-parameter)

# See ../../darwin/orbis_filament/Sources/orbis_filament_native's own CMake
# notes (this file's sibling logic in the android-spike) for why the archive
# list needs -Wl,--start-group/--end-group (Filament's static libraries have
# circular dependencies between them) and why -Wl,--no-undefined stays on
# (turns a missing archive into a link failure naming the exact symbol,
# rather than a dlopen crash on the device naming nothing useful at all).
#
# The list itself is darwin/setup.sh's own LIBS array -- what the renderer
# core actually reaches (gltfio's asset loader, Ktx1Reader, the IBL
# prefilter, and the rest) -- plus bluevk, which only Android and desktop
# need and which is Vulkan's entry-point loader: it dlopens libvulkan.so at
# runtime rather than linking it, so nothing here needs Vulkan development
# libraries beyond bluevk's own archive. bluegl has no Android build (the
# release carries no libbluegl.a for any Android ABI) and is not linked:
# Android's OpenGL ES backend talks to EGL/GLESv3 directly.
set(FILAMENT_STATIC_LIBS
    filament
    backend
    bluevk
    filabridge
    filaflat
    utils
    geometry
    smol-v
    ibl
    image
    abseil
    zstd
    filament-iblprefilter
    gltfio_core
    uberarchive
    uberzlib
    dracodec
    meshoptimizer
    ktxreader
    stb
    basis_transcoder
    mikktspace
)

set(FILAMENT_LINK_LINE "")
foreach(lib ${FILAMENT_STATIC_LIBS})
    list(APPEND FILAMENT_LINK_LINE "${FILAMENT_LIB_DIR}/lib${lib}.a")
endforeach()

target_link_libraries(orbis_filament_native
    PRIVATE
        -Wl,--start-group
        ${FILAMENT_LINK_LINE}
        -Wl,--end-group
        android       # ANativeWindow_fromSurface / _release
        log           # __android_log_print, orbis::log's Android half
        EGL           # the OpenGL ES backend's window system
        GLESv3        # the OpenGL ES backend itself
        dl            # bluevk's dlopen of libvulkan.so
        jnigraphics   # pulled in by the NDK's android lib on some setups
        mediandk      # AImage/AMediaCodec -- reserved for the video decoder
                      # PORTING.md says nothing implements yet; linked now so
                      # adding it later is not also a CMake change.
)

target_link_options(orbis_filament_native PRIVATE -Wl,--no-undefined)
