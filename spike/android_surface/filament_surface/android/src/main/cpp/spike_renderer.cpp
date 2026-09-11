// Orbis spike: prove Filament draws into a Flutter texture on Android.
//
// The Apple path was proved by spike/cube_to_pixelbuffer.mm: Filament renders
// into a CVPixelBuffer and Flutter's texture registry takes it. Android has no
// equivalent CPU-side handoff. What it has instead is a producer/consumer
// Surface: Flutter's TextureRegistry.createSurfaceProducer() hands out an
// android.view.Surface backed by a SurfaceTexture the Flutter compositor
// samples. Anything that can write to a Surface can feed a Flutter texture.
//
// So the whole bridge is three lines of the file:
//
//     ANativeWindow* w = ANativeWindow_fromSurface(env, surface);
//     SwapChain* sc    = engine->createSwapChain(w);
//     renderer->beginFrame(sc) / render(view) / endFrame();
//
// Filament's Android backends (PlatformEGL for OpenGL ES, PlatformVkAndroid
// for Vulkan) both accept an ANativeWindow* as the opaque nativeWindow of
// createSwapChain, so the same handle serves either backend. Everything else
// here exists to make that survive Android's surface lifecycle and to report
// what the device can actually do.
//
// Threading: every entry point below runs on the Android main (== Flutter
// platform) thread. Filament's Engine is not thread safe and the Surface
// lifecycle callbacks arrive on the main thread, so keeping all of it on one
// thread removes a whole class of bug from the spike. It costs little: by
// default the Engine owns a driver thread, so render()/endFrame() only record
// and hand off commands.

#include <jni.h>

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <backend/DriverEnums.h>
#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/SwapChain.h>
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <math/mat4.h>
#include <math/vec3.h>
#include <utils/Entity.h>
#include <utils/EntityManager.h>

#include "generated/unlit_colour.filamat.h"

#include <algorithm>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <string>

using namespace filament;
using namespace filament::math;
using utils::Entity;
using utils::EntityManager;

#define TAG "OrbisSpike"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace {

// ---------------------------------------------------------------------------
// Geometry: a cube, four vertices per face so every face carries one flat
// colour. Six colours means a rotation is unmistakable in a screenshot: which
// faces you can see says which way round it is, so two captures a second apart
// prove animation rather than a static image that happens to be colourful.
// ---------------------------------------------------------------------------

struct Vertex {
    float3 position;
    uint32_t colour;  // little-endian ABGR, i.e. bytes R,G,B,A -- matches UBYTE4
};

constexpr uint32_t kRed = 0xff0000ffu;
constexpr uint32_t kGreen = 0xff00ff00u;
constexpr uint32_t kBlue = 0xffff0000u;
constexpr uint32_t kYellow = 0xff00ffffu;
constexpr uint32_t kMagenta = 0xffff00ffu;
constexpr uint32_t kCyan = 0xffffff00u;

const Vertex kVertices[24] = {
        // +Z red
        {{-1, -1, 1}, kRed}, {{1, -1, 1}, kRed}, {{1, 1, 1}, kRed}, {{-1, 1, 1}, kRed},
        // -Z green
        {{1, -1, -1}, kGreen}, {{-1, -1, -1}, kGreen}, {{-1, 1, -1}, kGreen}, {{1, 1, -1}, kGreen},
        // +X blue
        {{1, -1, 1}, kBlue}, {{1, -1, -1}, kBlue}, {{1, 1, -1}, kBlue}, {{1, 1, 1}, kBlue},
        // -X yellow
        {{-1, -1, -1}, kYellow}, {{-1, -1, 1}, kYellow}, {{-1, 1, 1}, kYellow}, {{-1, 1, -1}, kYellow},
        // +Y magenta
        {{-1, 1, 1}, kMagenta}, {{1, 1, 1}, kMagenta}, {{1, 1, -1}, kMagenta}, {{-1, 1, -1}, kMagenta},
        // -Y cyan
        {{-1, -1, -1}, kCyan}, {{1, -1, -1}, kCyan}, {{1, -1, 1}, kCyan}, {{-1, -1, 1}, kCyan},
};

const uint16_t kIndices[36] = {
        0, 1, 2, 2, 3, 0,        //
        4, 5, 6, 6, 7, 4,        //
        8, 9, 10, 10, 11, 8,     //
        12, 13, 14, 14, 15, 12,  //
        16, 17, 18, 18, 19, 16,  //
        20, 21, 22, 22, 23, 20,  //
};

const char* backendName(Engine::Backend b) {
    switch (b) {
        case Engine::Backend::OPENGL: return "OpenGL";
        case Engine::Backend::VULKAN: return "Vulkan";
        case Engine::Backend::METAL: return "Metal";
        case Engine::Backend::WEBGPU: return "WebGPU";
        case Engine::Backend::NOOP: return "Noop";
        default: return "Default";
    }
}

// ---------------------------------------------------------------------------
// The renderer.
//
// The split that matters for Android: the Engine and every GPU resource it owns
// (material, buffers, renderable, scene, view, camera) live for the whole
// session. Only the SwapChain -- and the ANativeWindow it wraps -- are tied to
// the Surface, and those are created and destroyed as Flutter's SurfaceProducer
// hands the Surface out and takes it back. Losing the surface must not cost the
// scene, or every app backgrounding would rebuild the world.
// ---------------------------------------------------------------------------

class SpikeRenderer {
public:
    // requestFeatureLevel3 exists only to answer one question this spike was
    // built to answer: is a reported ceiling one Orbis's standard lit surface
    // (feature level 3, twelve samplers) could actually reach, or only a
    // number? Left false -- the default -- the engine settles at its own
    // default level and getSupportedFeatureLevel() reports the honest device
    // ceiling: asking for a level the device cannot serve makes build()
    // return nullptr, which would tell us nothing about how far short it
    // fell. Set true, it asks Filament for level 3 outright; if the backend
    // was only ever going to grant level 1 or 2, build() returning nullptr
    // here *is* the answer, logged before it happens so it is still visible.
    static SpikeRenderer* create(Engine::Backend backend, bool requestFeatureLevel3 = false) {
        Engine::Builder builder;
        builder.backend(backend);
        if (requestFeatureLevel3) {
            LOGI("requesting feature level 3 outright for backend %s", backendName(backend));
            builder.featureLevel(Engine::FeatureLevel::FEATURE_LEVEL_3);
        }

        Engine* engine = builder.build();
        if (engine == nullptr) {
            LOGE("Engine::build() returned nullptr for backend %s%s", backendName(backend),
                    requestFeatureLevel3 ? " at requested feature level 3" : "");
            return nullptr;
        }

        auto* self = new SpikeRenderer(engine);
        self->buildScene();
        LOGI("engine up: backend=%s activeFeatureLevel=%d supportedFeatureLevel=%d",
                backendName(engine->getBackend()),
                static_cast<int>(engine->getActiveFeatureLevel()),
                static_cast<int>(engine->getSupportedFeatureLevel()));
        return self;
    }

    ~SpikeRenderer() {
        detachSurface();

        mEngine->destroy(mRenderable);
        mEngine->destroy(mMaterialInstance);
        mEngine->destroy(mMaterial);
        mEngine->destroy(mIndexBuffer);
        mEngine->destroy(mVertexBuffer);
        mEngine->destroy(mSkybox);
        mEngine->destroy(mView);
        mEngine->destroy(mScene);
        mEngine->destroyCameraComponent(mCameraEntity);
        mEngine->destroy(mRenderer);
        EntityManager::get().destroy(mRenderable);
        EntityManager::get().destroy(mCameraEntity);
        Engine::destroy(mEngine);
        LOGI("engine torn down");
    }

    // Called on first attach and again every time Flutter hands back a Surface
    // after destroying one. Idempotent: attaching over a live swap chain drops
    // the old one first.
    bool attachSurface(JNIEnv* env, jobject surface, uint32_t width, uint32_t height) {
        detachSurface();

        mWindow = ANativeWindow_fromSurface(env, surface);
        if (mWindow == nullptr) {
            LOGE("ANativeWindow_fromSurface returned null");
            return false;
        }

        // Trust the producer's reported size over the window's own: Flutter has
        // just called setSize() and the window may not have caught up.
        mWidth = width > 0 ? width : static_cast<uint32_t>(ANativeWindow_getWidth(mWindow));
        mHeight = height > 0 ? height : static_cast<uint32_t>(ANativeWindow_getHeight(mWindow));

        mSwapChain = mEngine->createSwapChain(mWindow);
        if (mSwapChain == nullptr) {
            LOGE("createSwapChain returned null");
            ANativeWindow_release(mWindow);
            mWindow = nullptr;
            return false;
        }

        applyViewport();
        mSurfaceGeneration++;
        LOGI("surface attached: generation=%d %ux%u window=%p swapChain=%p", mSurfaceGeneration,
                mWidth, mHeight, static_cast<void*>(mWindow), static_cast<void*>(mSwapChain));
        return true;
    }

    void detachSurface() {
        if (mSwapChain == nullptr) {
            return;
        }
        mEngine->destroy(mSwapChain);
        mSwapChain = nullptr;

        // The ordering that bites you. Engine::destroy() only *queues* the
        // destruction onto the driver thread; the driver still holds the
        // ANativeWindow until it drains. Releasing the window before that
        // drains is a use-after-free that shows up as an eglDestroySurface
        // crash or a silently dead swap chain on the next attach. flushAndWait
        // blocks until the driver has actually let go.
        mEngine->flushAndWait();

        if (mWindow != nullptr) {
            ANativeWindow_release(mWindow);
            mWindow = nullptr;
        }
        LOGI("surface detached (swap chain destroyed, window released)");
    }

    void resize(uint32_t width, uint32_t height) {
        if (width == 0 || height == 0 || (width == mWidth && height == mHeight)) {
            return;
        }
        mWidth = width;
        mHeight = height;
        applyViewport();
        LOGI("resized to %ux%u", mWidth, mHeight);
    }

    bool hasSurface() const { return mSwapChain != nullptr; }

    // One frame. frameTimeNanos is Choreographer's vsync timestamp, passed
    // straight to beginFrame so Filament's frame pacing sees the real vsync
    // rather than whenever we happened to get scheduled.
    bool render(int64_t frameTimeNanos) {
        if (mSwapChain == nullptr) {
            return false;
        }

        if (mFirstFrameNanos == 0) {
            mFirstFrameNanos = frameTimeNanos;
        }
        const double seconds = static_cast<double>(frameTimeNanos - mFirstFrameNanos) * 1e-9;

        // Two axes at incommensurate rates so no two frames a second apart ever
        // look alike.
        auto& tcm = mEngine->getTransformManager();
        const mat4f transform = mat4f::rotation(seconds * 0.9, float3{0, 1, 0}) *
                                mat4f::rotation(seconds * 0.6, float3{1, 0, 0});
        tcm.setTransform(tcm.getInstance(mRenderable), transform);

        if (!mRenderer->beginFrame(mSwapChain, static_cast<uint64_t>(frameTimeNanos))) {
            // Filament declined the frame -- the backend wants us to skip to
            // keep pace. Counted, because a run where every frame is skipped
            // looks exactly like a run that never drew.
            mSkippedFrames++;
            return false;
        }
        mRenderer->render(mView);
        mRenderer->endFrame();

        mRenderedFrames++;
        if (mLastFrameNanos != 0) {
            const int64_t delta = frameTimeNanos - mLastFrameNanos;
            if (delta > 0) {
                mIntervalSumNanos += delta;
                mIntervalCount++;
                mWorstIntervalNanos = std::max(mWorstIntervalNanos, delta);
            }
        }
        mLastFrameNanos = frameTimeNanos;
        return true;
    }

    std::string describe() const {
        const auto active = static_cast<int>(mEngine->getActiveFeatureLevel());
        const auto supported = static_cast<int>(mEngine->getSupportedFeatureLevel());

        char buf[768];
        snprintf(buf, sizeof(buf),
                "backend=%s\n"
                "activeFeatureLevel=%d\n"
                "supportedFeatureLevel=%d\n"
                "featureLevel3Available=%s\n"
                "maxVertexSamplers=%zu\n"
                "maxFragmentSamplers=%zu\n"
                "size=%ux%u\n"
                "surfaceGeneration=%d\n",
                backendName(mEngine->getBackend()), active, supported,
                supported >= 3 ? "true" : "false",
                backend::FEATURE_LEVEL_CAPS[supported].MAX_VERTEX_SAMPLER_COUNT,
                backend::FEATURE_LEVEL_CAPS[supported].MAX_FRAGMENT_SAMPLER_COUNT, mWidth, mHeight,
                mSurfaceGeneration);
        return std::string(buf);
    }

    std::string stats() const {
        const double meanMs = mIntervalCount > 0
                ? static_cast<double>(mIntervalSumNanos) / static_cast<double>(mIntervalCount) * 1e-6
                : 0.0;
        char buf[384];
        snprintf(buf, sizeof(buf),
                "renderedFrames=%" PRId64 "\n"
                "skippedFrames=%" PRId64 "\n"
                "meanFrameIntervalMs=%.2f\n"
                "worstFrameIntervalMs=%.2f\n"
                "fps=%.1f\n",
                mRenderedFrames, mSkippedFrames, meanMs,
                static_cast<double>(mWorstIntervalNanos) * 1e-6, meanMs > 0 ? 1000.0 / meanMs : 0.0);
        return std::string(buf);
    }

private:
    explicit SpikeRenderer(Engine* engine) : mEngine(engine) {}

    void buildScene() {
        mRenderer = mEngine->createRenderer();
        mScene = mEngine->createScene();
        mView = mEngine->createView();

        mCameraEntity = EntityManager::get().create();
        mCamera = mEngine->createCamera(mCameraEntity);
        mCamera->lookAt({0.0f, 0.0f, 4.2f}, {0.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f});

        // A solid skybox, not a clear colour. It tells "Filament ran the whole
        // scene pipeline" apart from "something cleared the buffer": if the
        // capture is this teal, the render path works even when the cube is
        // missing, which narrows the fault to the geometry or the material.
        mSkybox = Skybox::Builder().color({0.05f, 0.16f, 0.20f, 1.0f}).build(*mEngine);
        mScene->setSkybox(mSkybox);

        mMaterial = Material::Builder()
                            .package(kUnlitColourFilamat, kUnlitColourFilamat_len)
                            .build(*mEngine);
        mMaterialInstance = mMaterial->createInstance();

        mVertexBuffer = VertexBuffer::Builder()
                                .vertexCount(24)
                                .bufferCount(1)
                                .attribute(VertexAttribute::POSITION, 0,
                                        VertexBuffer::AttributeType::FLOAT3, offsetof(Vertex, position),
                                        sizeof(Vertex))
                                .attribute(VertexAttribute::COLOR, 0,
                                        VertexBuffer::AttributeType::UBYTE4, offsetof(Vertex, colour),
                                        sizeof(Vertex))
                                .normalized(VertexAttribute::COLOR)
                                .build(*mEngine);
        mVertexBuffer->setBufferAt(*mEngine, 0,
                VertexBuffer::BufferDescriptor(kVertices, sizeof(kVertices), nullptr));

        mIndexBuffer = IndexBuffer::Builder()
                               .indexCount(36)
                               .bufferType(IndexBuffer::IndexType::USHORT)
                               .build(*mEngine);
        mIndexBuffer->setBuffer(
                *mEngine, IndexBuffer::BufferDescriptor(kIndices, sizeof(kIndices), nullptr));

        mRenderable = EntityManager::get().create();
        RenderableManager::Builder(1)
                .boundingBox({{-1, -1, -1}, {1, 1, 1}})
                .material(0, mMaterialInstance)
                .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, mVertexBuffer,
                        mIndexBuffer, 0, 36)
                .culling(true)
                .castShadows(false)
                .receiveShadows(false)
                .build(*mEngine, mRenderable);
        mScene->addEntity(mRenderable);

        mView->setScene(mScene);
        mView->setCamera(mCamera);

        // Post-processing off. The spike is proving presentation, and the
        // post-processing chain adds an offscreen render target plus a blit
        // between the scene and the swap chain -- exactly the layer that would
        // hide a broken swap chain behind a working-looking render. With it off
        // Filament draws into the swap chain directly, so a correct capture
        // means the swap chain itself is correct. It also means no tonemapping,
        // which is why the cube's colours come out fully saturated.
        mView->setPostProcessingEnabled(false);
    }

    void applyViewport() {
        mView->setViewport({0, 0, mWidth, mHeight});
        const double aspect = static_cast<double>(mWidth) / static_cast<double>(mHeight);
        mCamera->setProjection(50.0, aspect, 0.1, 100.0, Camera::Fov::VERTICAL);
    }

    Engine* mEngine = nullptr;
    Renderer* mRenderer = nullptr;
    Scene* mScene = nullptr;
    View* mView = nullptr;
    Camera* mCamera = nullptr;
    Skybox* mSkybox = nullptr;
    Material* mMaterial = nullptr;
    MaterialInstance* mMaterialInstance = nullptr;
    VertexBuffer* mVertexBuffer = nullptr;
    IndexBuffer* mIndexBuffer = nullptr;
    Entity mCameraEntity;
    Entity mRenderable;

    // Surface-scoped. Null between onSurfaceDestroyed and the next attach.
    SwapChain* mSwapChain = nullptr;
    ANativeWindow* mWindow = nullptr;

    uint32_t mWidth = 1;
    uint32_t mHeight = 1;
    int mSurfaceGeneration = 0;

    int64_t mFirstFrameNanos = 0;
    int64_t mLastFrameNanos = 0;
    int64_t mIntervalSumNanos = 0;
    int64_t mIntervalCount = 0;
    int64_t mWorstIntervalNanos = 0;
    int64_t mRenderedFrames = 0;
    int64_t mSkippedFrames = 0;
};

SpikeRenderer* fromHandle(jlong handle) {
    return reinterpret_cast<SpikeRenderer*>(handle);
}

jstring toJString(JNIEnv* env, const std::string& s) {
    return env->NewStringUTF(s.c_str());
}

}  // namespace

// ---------------------------------------------------------------------------
// JNI. Names are the mangled form for dev.orbis.spike.filament_surface.
// SpikeRenderer -- note filament_surface becomes filament_1surface, because JNI
// escapes an underscore in a package name as _1.
// ---------------------------------------------------------------------------

extern "C" {

JNIEXPORT jlong JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeCreate(
        JNIEnv*, jclass, jint backendOrdinal, jboolean requestFeatureLevel3) {
    // 0 = OpenGL ES, 1 = Vulkan. Kept as an int so the Dart side can ask for a
    // backend by name without the Kotlin layer knowing Filament's enum.
    const auto backend =
            backendOrdinal == 1 ? Engine::Backend::VULKAN : Engine::Backend::OPENGL;
    LOGI("nativeCreate backend=%s requestFeatureLevel3=%d", backendName(backend),
            static_cast<int>(requestFeatureLevel3));
    return reinterpret_cast<jlong>(SpikeRenderer::create(backend, requestFeatureLevel3));
}

JNIEXPORT jboolean JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeAttachSurface(
        JNIEnv* env, jclass, jlong handle, jobject surface, jint width, jint height) {
    auto* r = fromHandle(handle);
    if (r == nullptr || surface == nullptr) {
        return JNI_FALSE;
    }
    return r->attachSurface(env, surface, static_cast<uint32_t>(width),
                   static_cast<uint32_t>(height))
            ? JNI_TRUE
            : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeDetachSurface(
        JNIEnv*, jclass, jlong handle) {
    if (auto* r = fromHandle(handle); r != nullptr) {
        r->detachSurface();
    }
}

JNIEXPORT void JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeResize(
        JNIEnv*, jclass, jlong handle, jint width, jint height) {
    if (auto* r = fromHandle(handle); r != nullptr) {
        r->resize(static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    }
}

JNIEXPORT jboolean JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeRender(
        JNIEnv*, jclass, jlong handle, jlong frameTimeNanos) {
    auto* r = fromHandle(handle);
    return (r != nullptr && r->render(frameTimeNanos)) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeHasSurface(
        JNIEnv*, jclass, jlong handle) {
    auto* r = fromHandle(handle);
    return (r != nullptr && r->hasSurface()) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeDescribe(
        JNIEnv* env, jclass, jlong handle) {
    auto* r = fromHandle(handle);
    return toJString(env, r != nullptr ? r->describe() : std::string("error=no renderer\n"));
}

JNIEXPORT jstring JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeStats(
        JNIEnv* env, jclass, jlong handle) {
    auto* r = fromHandle(handle);
    return toJString(env, r != nullptr ? r->stats() : std::string("error=no renderer\n"));
}

JNIEXPORT void JNICALL
Java_dev_orbis_spike_filament_1surface_SpikeRenderer_nativeDestroy(
        JNIEnv*, jclass, jlong handle) {
    delete fromHandle(handle);
}

}  // extern "C"
