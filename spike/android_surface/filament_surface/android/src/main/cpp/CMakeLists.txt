cmake_minimum_required(VERSION 3.22.1)
project(orbis_spike LANGUAGES CXX)

# Filament 1.76 headers are C++17 and its public API uses inline std::string_view
# and structured bindings; 17 is the floor, and anything newer changes no ABI
# because we link the release's own static libs, not rebuild them.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# third_party/filament is the symlink setup.sh makes to the unpacked Android
# release. Nothing is copied and nothing is downloaded during the Gradle build.
set(FILAMENT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../third_party/filament")
get_filename_component(FILAMENT_DIR "${FILAMENT_DIR}" ABSOLUTE)

if(NOT EXISTS "${FILAMENT_DIR}/include/filament/Engine.h")
    message(FATAL_ERROR
        "No Filament release at ${FILAMENT_DIR}. Run spike/android_surface/setup.sh first.")
endif()
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/generated/unlit_colour.filamat.h")
    message(FATAL_ERROR
        "No compiled material. Run spike/android_surface/setup.sh first.")
endif()

set(FILAMENT_LIB_DIR "${FILAMENT_DIR}/lib/${ANDROID_ABI}")
if(NOT EXISTS "${FILAMENT_LIB_DIR}")
    message(FATAL_ERROR "Filament release has no libs for ABI ${ANDROID_ABI}")
endif()

add_library(orbis_spike SHARED spike_renderer.cpp)

target_include_directories(orbis_spike PRIVATE
    "${FILAMENT_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}")

# Filament's public headers carry no guard against these and the NDK's default
# warning set is quiet enough that leaving them on costs nothing.
target_compile_options(orbis_spike PRIVATE -Wall -Wextra -Wno-unused-parameter)

# Filament ships as a set of static archives with circular dependencies between
# them: filament needs backend, backend needs filament's utils and filabridge,
# bluevk is pulled in from inside backend. A flat list makes the linker's single
# pass order-sensitive and produces undefined-symbol errors that move around as
# you reorder it. --start-group/--end-group makes ld rescan the set until it
# settles, so the list below can stay alphabetical and stay correct.
#
# Only the libraries a core render path touches are listed. The release also
# carries gltfio, ktxreader, draco, basis, meshoptimizer and the rest; none of
# them are on this path and each would add megabytes to the .so.
set(FILAMENT_STATIC_LIBS
    filament        # Engine, Renderer, View, Scene, materials
    backend         # the OpenGL ES and Vulkan drivers
    bluevk          # Vulkan entry-point loader; dlopens libvulkan.so at runtime
    filabridge      # shared types between matc's output and the runtime
    filaflat        # the .filamat reader
    geometry        # used by filament internals
    ibl-lite        # indirect-light maths filament links unconditionally
    smol-v          # SPIR-V decompression for the Vulkan shader variants
    utils           # filament's own JobSystem, Entity, allocators
)

set(FILAMENT_LINK_LINE "")
foreach(lib ${FILAMENT_STATIC_LIBS})
    list(APPEND FILAMENT_LINK_LINE "${FILAMENT_LIB_DIR}/lib${lib}.a")
endforeach()

target_link_libraries(orbis_spike
    PRIVATE
        -Wl,--start-group
        ${FILAMENT_LINK_LINE}
        -Wl,--end-group
        android      # ANativeWindow_fromSurface / _release
        log          # __android_log_print
        EGL          # PlatformEGLAndroid, the OpenGL ES backend's window system
        GLESv3       # the OpenGL ES backend itself
        dl           # bluevk's dlopen of libvulkan.so
        jnigraphics  # pulled in by the NDK's android lib on some setups
)

# --no-undefined turns "symbol missing from the .so" from a crash at
# System.loadLibrary time into a failure at build time. Worth it: a missing
# Filament archive otherwise links cleanly and then kills the app on launch with
# a dlopen error that names one symbol and not the library it came from.
#
# Deliberately *not* -ffunction-sections/-fdata-sections plus -Wl,--gc-sections,
# which an earlier version of this file carried. That pair buys a smaller .so,
# and a spike proving a pipeline works is never shipped or measured for size --
# there is no gain here to buy. What it risks is real: dead-code stripping
# across a --start-group/--end-group set of huge prebuilt archives, linked for
# Android for the first time in this codebase, is exactly the kind of change
# that can silently drop a section reached only indirectly (a vtable, a JNI
# export, bluevk's dlsym'd table) and turn into a crash with no visible
# connection back to the flag that caused it. Risk for little gain, so it
# stays off; the real plugin can measure and decide with a size budget that
# actually matters.
target_link_options(orbis_spike PRIVATE -Wl,--no-undefined)
