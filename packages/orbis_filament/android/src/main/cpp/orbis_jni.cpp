// The JNI bridge: dev.orbis.filament.OrbisNative (Kotlin) <-> orbis_renderer.h
// (C ABI) <-> orbis::Renderer (the portable core).
//
// Every function here does what OrbisRendererC.cpp's own comment says of
// itself, one layer up: turn Kotlin's types into the ABI's, call through, and
// make sure nothing thrown inside Filament unwinds into a JNI caller that
// cannot catch it (a C++ exception crossing back into the JVM is undefined
// behaviour). Nothing is decided here that the core or the ABI already
// decide -- nulls, short arrays and a stopped renderer are still the ABI's
// ORBIS_ERROR_* to report, translated to a Kotlin Int a Kotlin `orbis_result`
// alias reads the same way.
//
// Naming: dev.orbis.filament.OrbisNative, an `object`, so every external fun
// is (per Kotlin's own codegen for a plain object method) an instance method
// on the singleton -- JNI's real second parameter is the instance, not the
// class. Declared as `jclass` below and left unnamed, matching the
// android-spike's SpikeRenderer.kt/spike_renderer.cpp exactly: `jclass` and
// `jobject` are the same typedef in jni.h, so this is harmless as long as
// (as here) the parameter is never read.

#include <jni.h>

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "orbis_renderer.h"

#define TAG "OrbisFilament"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

// One of these per Kotlin-side viewport, tracked as a jlong handle. Owns the
// ANativeWindow the currently-attached surface (if any) was built from --
// OrbisSurface (inside the core) only borrows the pointer it is given
// (orbis_surface_desc.window), so releasing it is this layer's job, exactly
// as it is SpikeRenderer's in the android-spike. Not owned: the orbis_renderer
// itself is destroyed through the ABI, which also destroys the OrbisSurface
// wrapper Renderer::attachSurface/detachSurface manage -- but never the
// ANativeWindow underneath it, on either side of that boundary.
struct OrbisHandle {
  orbis_renderer *renderer = nullptr;
  ANativeWindow *window = nullptr;
};

OrbisHandle *fromHandle(jlong handle) {
  return reinterpret_cast<OrbisHandle *>(handle);
}

// ---- Borrowing Kotlin arrays without copying, released on scope exit -----
//
// GetXArrayElements may or may not copy depending on the JVM; ReleaseXArrayElements
// with JNI_ABORT tells it nothing was written back, so a copy (if there was
// one) is simply freed rather than written back for nothing -- every call
// here only reads. A null Kotlin array (which Dart sends for "this is
// empty", per orbis_view.dart's own comment on non-nullable pointers) borrows
// as a null pointer and zero length, which is exactly what the ABI's
// `holds()`/`present()` checks expect for an empty, optional field.

struct Floats {
  JNIEnv *env;
  jfloatArray array;
  jfloat *data = nullptr;
  jsize length = 0;
  Floats(JNIEnv *e, jfloatArray a) : env(e), array(a) {
    if (array != nullptr) {
      length = env->GetArrayLength(array);
      data = env->GetFloatArrayElements(array, nullptr);
    }
  }
  ~Floats() {
    if (data != nullptr) env->ReleaseFloatArrayElements(array, data, JNI_ABORT);
  }
  Floats(const Floats &) = delete;
  const float *ptr() const { return data; }
  size_t count() const { return size_t(length); }
};

struct Ints {
  JNIEnv *env;
  jintArray array;
  jint *data = nullptr;
  jsize length = 0;
  Ints(JNIEnv *e, jintArray a) : env(e), array(a) {
    if (array != nullptr) {
      length = env->GetArrayLength(array);
      data = env->GetIntArrayElements(array, nullptr);
    }
  }
  ~Ints() {
    if (data != nullptr) env->ReleaseIntArrayElements(array, data, JNI_ABORT);
  }
  Ints(const Ints &) = delete;
  // jint is int32_t on every ABI Android supports; the reinterpret is a
  // formality the standard requires, not a real conversion.
  const int32_t *ptr() const { return reinterpret_cast<const int32_t *>(data); }
  uint32_t count() const { return uint32_t(length); }
};

struct Longs {
  JNIEnv *env;
  jlongArray array;
  jlong *data = nullptr;
  jsize length = 0;
  Longs(JNIEnv *e, jlongArray a) : env(e), array(a) {
    if (array != nullptr) {
      length = env->GetArrayLength(array);
      data = env->GetLongArrayElements(array, nullptr);
    }
  }
  ~Longs() {
    if (data != nullptr) env->ReleaseLongArrayElements(array, data, JNI_ABORT);
  }
  Longs(const Longs &) = delete;
  const int64_t *ptr() const { return reinterpret_cast<const int64_t *>(data); }
  uint32_t count() const { return uint32_t(length); }
};

struct Bytes {
  JNIEnv *env;
  jbyteArray array;
  jbyte *data = nullptr;
  jsize length = 0;
  Bytes(JNIEnv *e, jbyteArray a) : env(e), array(a) {
    if (array != nullptr) {
      length = env->GetArrayLength(array);
      data = env->GetByteArrayElements(array, nullptr);
    }
  }
  ~Bytes() {
    if (data != nullptr) env->ReleaseByteArrayElements(array, data, JNI_ABORT);
  }
  Bytes(const Bytes &) = delete;
  const uint8_t *ptr() const { return reinterpret_cast<const uint8_t *>(data); }
  size_t count() const { return size_t(length); }
};

// jstring[] -> both a std::string owner (so the char* stays valid) and the
// const char* const* the ABI reads. Built together because the ABI wants the
// pointer array, and nothing else here needs to hold Kotlin string objects.
struct Strings {
  std::vector<std::string> owned;
  std::vector<const char *> pointers;
  Strings(JNIEnv *env, jobjectArray array) {
    if (array == nullptr) return;
    const jsize n = env->GetArrayLength(array);
    owned.reserve(size_t(n));
    for (jsize i = 0; i < n; i++) {
      auto *element = static_cast<jstring>(env->GetObjectArrayElement(array, i));
      if (element == nullptr) {
        owned.emplace_back();
      } else {
        const char *chars = env->GetStringUTFChars(element, nullptr);
        owned.emplace_back(chars != nullptr ? chars : "");
        if (chars != nullptr) env->ReleaseStringUTFChars(element, chars);
        env->DeleteLocalRef(element);
      }
    }
    pointers.reserve(owned.size());
    for (const std::string &s : owned) pointers.push_back(s.c_str());
  }
  const char *const *ptr() const { return pointers.empty() ? nullptr : pointers.data(); }
  uint32_t count() const { return uint32_t(owned.size()); }
};

std::string toStdString(JNIEnv *env, jstring s) {
  if (s == nullptr) return {};
  const char *chars = env->GetStringUTFChars(s, nullptr);
  std::string out(chars != nullptr ? chars : "");
  if (chars != nullptr) env->ReleaseStringUTFChars(s, chars);
  return out;
}

jstring toJString(JNIEnv *env, const std::string &s) { return env->NewStringUTF(s.c_str()); }

}  // namespace

extern "C" {

// ---- Lifetime --------------------------------------------------------

JNIEXPORT jlong JNICALL
Java_dev_orbis_filament_OrbisNative_nativeCreate(JNIEnv *env, jclass, jint backendOrdinal,
        jobject surface, jint width, jint height) {
  ANativeWindow *window = nullptr;
  if (surface != nullptr) {
    window = ANativeWindow_fromSurface(env, surface);
    if (window == nullptr) {
      LOGE("nativeCreate: ANativeWindow_fromSurface returned null");
      return 0;
    }
  }

  orbis_surface_desc desc{};
  desc.kind = window != nullptr ? ORBIS_SURFACE_WINDOW : ORBIS_SURFACE_HEADLESS;
  desc.window = window;

  orbis_renderer *renderer = orbis_renderer_create(
      static_cast<OrbisBackend>(backendOrdinal), &desc, uint32_t(width), uint32_t(height));
  if (renderer == nullptr) {
    if (window != nullptr) ANativeWindow_release(window);
    LOGE("nativeCreate: orbis_renderer_create refused (backend=%d)", int(backendOrdinal));
    return 0;
  }

  auto *handle = new OrbisHandle{renderer, window};
  return reinterpret_cast<jlong>(handle);
}

JNIEXPORT void JNICALL
Java_dev_orbis_filament_OrbisNative_nativeDestroy(JNIEnv *, jclass, jlong handleValue) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return;
  orbis_renderer_destroy(handle->renderer);
  // Whatever the last attached window was, released only now: the core has
  // already destroyed its swap chain and flushed (inside orbis_renderer_destroy
  // -> ~Renderer -> dispose/detach), so it has let the window go by this point.
  if (handle->window != nullptr) ANativeWindow_release(handle->window);
  delete handle;
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeBackend(JNIEnv *, jclass, jlong handleValue) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_BACKEND_DEFAULT;
  return orbis_renderer_backend(handle->renderer);
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeResize(JNIEnv *, jclass, jlong handleValue, jint width,
        jint height) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  return orbis_renderer_resize(handle->renderer, uint32_t(width), uint32_t(height));
}

// Surface can be null (a HEADLESS attach -- draws nothing anywhere visible,
// used to give a detached renderer somewhere legal to draw while there is no
// Android Surface, if a caller ever wants that; the plugin itself always
// passes a real one or calls nativeDetachSurface instead).
JNIEXPORT jboolean JNICALL
Java_dev_orbis_filament_OrbisNative_nativeAttachSurface(JNIEnv *env, jclass, jlong handleValue,
        jobject surface, jint width, jint height) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return JNI_FALSE;

  ANativeWindow *window = nullptr;
  if (surface != nullptr) {
    window = ANativeWindow_fromSurface(env, surface);
    if (window == nullptr) {
      LOGE("nativeAttachSurface: ANativeWindow_fromSurface returned null");
      return JNI_FALSE;
    }
  }

  orbis_surface_desc desc{};
  desc.kind = window != nullptr ? ORBIS_SURFACE_WINDOW : ORBIS_SURFACE_HEADLESS;
  desc.window = window;

  const int result =
      orbis_renderer_attach_surface(handle->renderer, &desc, uint32_t(width), uint32_t(height));

  // attachSurface (core side) has already destroyed the previous swap chain
  // and flushAndWait()ed by the time this returns, whatever it returns -- see
  // its comment in OrbisRendererCore.cpp. Only now is it safe to let the
  // previous window go.
  ANativeWindow *previous = handle->window;
  handle->window = window;
  if (previous != nullptr) ANativeWindow_release(previous);

  return result == ORBIS_OK ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeDetachSurface(JNIEnv *, jclass, jlong handleValue) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  const int result = orbis_renderer_detach_surface(handle->renderer);
  if (handle->window != nullptr) {
    ANativeWindow_release(handle->window);
    handle->window = nullptr;
  }
  return result;
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeDraw(JNIEnv *, jclass, jlong handleValue,
        jdouble seconds) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  return orbis_renderer_draw(handle->renderer, seconds);
}

// ---- The scene ---------------------------------------------------------
//
// One JNI function per orbis_renderer_* scene call, in the ABI's own order,
// each a direct translation of its arguments -- the shape OrbisRendererC.cpp
// itself already is one layer down. Counts are derived from array lengths
// the same way OrbisFilamentPlugin.swift's Scene.init does (transforms.count
// / 16, and so on), not sent separately, since that is what the wire format
// already is.

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyObjects(JNIEnv *env, jclass, jlong handleValue,
        jlongArray keys, jfloatArray transforms, jfloatArray colours, jintArray meshes,
        jintArray flags, jintArray materials, jintArray morphCounts, jfloatArray morphWeights,
        jobjectArray paths) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Longs k(env, keys);
  Floats t(env, transforms);
  Floats c(env, colours);
  Ints m(env, meshes);
  Ints f(env, flags);
  Ints mat(env, materials);
  Ints mc(env, morphCounts);
  Floats mw(env, morphWeights);
  Strings p(env, paths);
  const uint32_t count = k.count();
  return orbis_renderer_apply_objects(handle->renderer, count, k.ptr(), t.ptr(), t.count(),
      c.ptr(), c.count(), m.ptr(), f.ptr(), mat.ptr(), mc.ptr(), mw.ptr(), mw.count(), p.ptr(),
      p.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetBatching(JNIEnv *, jclass, jlong handleValue,
        jboolean enabled) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  return orbis_renderer_set_batching(handle->renderer, enabled == JNI_TRUE ? 1 : 0);
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyMaterials(JNIEnv *env, jclass, jlong handleValue,
        jlongArray keys, jintArray flags, jfloatArray params, jintArray maps,
        jobjectArray texturePaths, jintArray textureSrgb, jintArray videos) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Longs k(env, keys);
  Ints f(env, flags);
  Floats pr(env, params);
  Ints mp(env, maps);
  Strings tp(env, texturePaths);
  Ints srgb(env, textureSrgb);
  Ints vid(env, videos);
  return orbis_renderer_apply_materials(handle->renderer, k.count(), k.ptr(), f.ptr(), pr.ptr(),
      pr.count(), mp.ptr(), mp.count(), tp.ptr(), srgb.ptr(), tp.count(), vid.ptr());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetPipeline(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats pr(env, params);
  return orbis_renderer_set_pipeline(handle->renderer, pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyVideos(JNIEnv *env, jclass, jlong handleValue,
        jlongArray keys, jintArray flags, jfloatArray params, jobjectArray paths) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Longs k(env, keys);
  Ints f(env, flags);
  Floats pr(env, params);
  Strings p(env, paths);
  return orbis_renderer_apply_videos(
      handle->renderer, k.count(), k.ptr(), f.ptr(), pr.ptr(), pr.count(), p.ptr(), p.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyLights(JNIEnv *env, jclass, jlong handleValue,
        jlongArray keys, jintArray kinds, jintArray flags, jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Longs k(env, keys);
  Ints kd(env, kinds);
  Ints f(env, flags);
  Floats pr(env, params);
  return orbis_renderer_apply_lights(
      handle->renderer, k.count(), k.ptr(), kd.ptr(), f.ptr(), pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyDecals(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray params, jintArray images, jobjectArray paths) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats pr(env, params);
  Ints im(env, images);
  Strings p(env, paths);
  return orbis_renderer_apply_decals(
      handle->renderer, im.count(), pr.ptr(), pr.count(), im.ptr(), p.ptr(), p.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetFog(JNIEnv *env, jclass, jlong handleValue,
        jboolean enabled, jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats pr(env, params);
  return orbis_renderer_set_fog(handle->renderer, enabled == JNI_TRUE ? 1 : 0, pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetPostProcess(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats pr(env, params);
  return orbis_renderer_set_post_process(handle->renderer, pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyProbes(JNIEnv *env, jclass, jlong handleValue,
        jlongArray keys, jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Longs k(env, keys);
  Floats pr(env, params);
  return orbis_renderer_apply_probes(handle->renderer, k.count(), k.ptr(), pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyField(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray params, jstring from) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats pr(env, params);
  const std::string source = toStdString(env, from);
  return orbis_renderer_apply_field(handle->renderer, pr.ptr(), pr.count(), source.c_str());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetEnvironment(JNIEnv *env, jclass, jlong handleValue,
        jstring radiance, jstring skybox, jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  const std::string r = toStdString(env, radiance);
  const std::string s = toStdString(env, skybox);
  Floats pr(env, params);
  return orbis_renderer_set_environment(handle->renderer, r.c_str(), s.c_str(), pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetRenderGraph(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray passes, jfloatArray targets, jobjectArray names) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats ps(env, passes);
  Floats ts(env, targets);
  Strings nm(env, names);
  // Strides are the ABI's own (orbis_renderer_stride), matching
  // Scene.passStride/targetStride on the Swift side and OrbisRenderGraph on
  // the Dart one -- see orbis_renderer.h's ORBIS_STRIDE_PASS/TARGET.
  const uint32_t passStride = orbis_renderer_stride(ORBIS_STRIDE_PASS);
  const uint32_t targetStride = orbis_renderer_stride(ORBIS_STRIDE_TARGET);
  const uint32_t passCount = passStride > 0 ? uint32_t(ps.count()) / passStride : 0;
  const uint32_t targetCount = targetStride > 0 ? uint32_t(ts.count()) / targetStride : 0;
  return orbis_renderer_set_render_graph(handle->renderer, passCount, ps.ptr(), ps.count(),
      targetCount, ts.ptr(), ts.count(), nm.ptr(), nm.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetGodRays(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray godRays, jfloatArray distortions) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats gr(env, godRays);
  Floats di(env, distortions);
  return orbis_renderer_set_god_rays(handle->renderer, gr.ptr(), gr.count(), di.ptr(), di.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplyPopulations(JNIEnv *env, jclass, jlong handleValue,
        jintArray keys, jintArray counts, jintArray meshes, jintArray flags, jintArray revisions,
        jfloatArray ranges, jfloatArray bounds, jobjectArray paths, jintArray changed,
        jfloatArray transforms, jfloatArray colours) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Ints k(env, keys);
  Ints c(env, counts);
  Ints m(env, meshes);
  Ints f(env, flags);
  Ints rev(env, revisions);
  Floats rg(env, ranges);
  Floats bd(env, bounds);
  Strings p(env, paths);
  Ints ch(env, changed);
  Floats tr(env, transforms);
  Floats co(env, colours);
  return orbis_renderer_apply_populations(handle->renderer, k.count(), k.ptr(), c.ptr(), m.ptr(),
      f.ptr(), rev.ptr(), rg.ptr(), bd.ptr(), bd.count(), p.ptr(), p.count(), ch.ptr(), ch.count(),
      tr.ptr(), tr.count(), co.ptr(), co.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeApplySplats(JNIEnv *env, jclass, jlong handleValue,
        jintArray keys, jintArray flags, jintArray revisions, jfloatArray params,
        jobjectArray paths, jintArray changed, jintArray changedCounts, jbyteArray data) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Ints k(env, keys);
  Ints f(env, flags);
  Ints rev(env, revisions);
  Floats pr(env, params);
  Strings p(env, paths);
  Ints ch(env, changed);
  Ints cc(env, changedCounts);
  Bytes by(env, data);
  return orbis_renderer_apply_splats(handle->renderer, k.count(), k.ptr(), f.ptr(), rev.ptr(),
      pr.ptr(), pr.count(), p.ptr(), p.count(), ch.ptr(), cc.ptr(), ch.count(), by.ptr(),
      by.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetSky(JNIEnv *env, jclass, jlong handleValue,
        jboolean enabled, jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats pr(env, params);
  return orbis_renderer_set_sky(handle->renderer, enabled == JNI_TRUE ? 1 : 0, pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetPrecipitation(JNIEnv *env, jclass, jlong handleValue,
        jboolean enabled, jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats pr(env, params);
  return orbis_renderer_set_precipitation(
      handle->renderer, enabled == JNI_TRUE ? 1 : 0, pr.ptr(), pr.count());
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetSkyColour(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray colour, jfloat ambient, jboolean showBody) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats c(env, colour);
  if (c.count() < 3) return ORBIS_ERROR_NULL;
  return orbis_renderer_set_sky_colour(
      handle->renderer, c.ptr(), ambient, showBody == JNI_TRUE ? 1 : 0);
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetCamera(JNIEnv *env, jclass, jlong handleValue,
        jfloatArray position, jfloatArray target, jfloat fieldOfView, jboolean orthographic,
        jfloat viewHeight, jdouble at) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Floats p(env, position);
  Floats t(env, target);
  if (p.count() < 3 || t.count() < 3) return ORBIS_ERROR_NULL;
  return orbis_renderer_set_camera(handle->renderer, p.ptr(), t.ptr(), fieldOfView,
      orthographic == JNI_TRUE ? 1 : 0, viewHeight, at);
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetExposure(JNIEnv *, jclass, jlong handleValue,
        jfloat aperture, jfloat shutter, jfloat sensitivity) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  return orbis_renderer_set_exposure(handle->renderer, aperture, shutter, sensitivity);
}

JNIEXPORT jint JNICALL
Java_dev_orbis_filament_OrbisNative_nativeSetOutline(JNIEnv *env, jclass, jlong handleValue,
        jlongArray keys, jfloatArray params) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return ORBIS_ERROR_NULL;
  Longs k(env, keys);
  Floats pr(env, params);
  return orbis_renderer_set_outline(handle->renderer, k.ptr(), k.count(), pr.ptr(), pr.count());
}

// ---- What it drew, and what it cost ------------------------------------

JNIEXPORT jdouble JNICALL
Java_dev_orbis_filament_OrbisNative_nativeGpuMilliseconds(JNIEnv *, jclass, jlong handleValue) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return 0.0;
  orbis_stats stats{};
  if (orbis_renderer_stats(handle->renderer, &stats) != ORBIS_OK) return 0.0;
  return stats.gpu_milliseconds;
}

// [batchedObjects, batchGroups].
JNIEXPORT jintArray JNICALL
Java_dev_orbis_filament_OrbisNative_nativeBatching(JNIEnv *env, jclass, jlong handleValue) {
  jintArray out = env->NewIntArray(2);
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return out;
  orbis_stats stats{};
  if (orbis_renderer_stats(handle->renderer, &stats) != ORBIS_OK) return out;
  jint values[2] = {jint(stats.batched_objects), jint(stats.batch_groups)};
  env->SetIntArrayRegion(out, 0, 2, values);
  return out;
}

// Interleaved [ms0, drawn0, ms1, drawn1, ...], one pair per pass, in the
// order the passes ran -- matching Viewport.passTimings on the Swift side,
// which OrbisView.capture() (orbis_view.dart) already knows how to read.
JNIEXPORT jdoubleArray JNICALL
Java_dev_orbis_filament_OrbisNative_nativePassTimings(JNIEnv *env, jclass, jlong handleValue) {
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return env->NewDoubleArray(0);
  const uint32_t count = orbis_renderer_pass_timings(handle->renderer, nullptr, nullptr, 0);
  std::vector<double> milliseconds(count);
  std::vector<int32_t> drawn(count);
  orbis_renderer_pass_timings(handle->renderer, milliseconds.data(), drawn.data(), count);
  jdoubleArray out = env->NewDoubleArray(jsize(count) * 2);
  if (count > 0) {
    std::vector<jdouble> interleaved(size_t(count) * 2);
    for (uint32_t i = 0; i < count; i++) {
      interleaved[i * 2] = milliseconds[i];
      interleaved[i * 2 + 1] = double(drawn[i]);
    }
    env->SetDoubleArrayRegion(out, 0, jsize(interleaved.size()), interleaved.data());
  }
  return out;
}

// ---- What it could not do -----------------------------------------------

// Flattened [about0, saying0, about1, saying1, ...], the ABI's snapshot-then-
// index shape read out in one call so Kotlin does not need to call back into
// JNI once per note.
JNIEXPORT jobjectArray JNICALL
Java_dev_orbis_filament_OrbisNative_nativeNotes(JNIEnv *env, jclass, jlong handleValue) {
  jclass stringClass = env->FindClass("java/lang/String");
  auto *handle = fromHandle(handleValue);
  if (handle == nullptr) return env->NewObjectArray(0, stringClass, nullptr);
  const uint32_t count = orbis_renderer_notes(handle->renderer);
  jobjectArray out = env->NewObjectArray(jsize(count) * 2, stringClass, nullptr);
  for (uint32_t i = 0; i < count; i++) {
    const char *about = nullptr;
    const char *saying = nullptr;
    if (orbis_renderer_note(handle->renderer, i, &about, &saying) != ORBIS_OK) continue;
    env->SetObjectArrayElement(out, jsize(i * 2), toJString(env, about != nullptr ? about : ""));
    env->SetObjectArrayElement(
        out, jsize(i * 2 + 1), toJString(env, saying != nullptr ? saying : ""));
  }
  return out;
}

}  // extern "C"
