// Orbis spike: prove Filament renders straight into a CVPixelBuffer.
//
// The CVPixelBuffer is the handoff Flutter's macOS/iOS texture registry takes
// from FlutterTexture.copyPixelBuffer, so a swap chain built on one is the whole
// zero-copy bridge: Filament writes the frame, Flutter composites it, and no
// pixel ever travels through the CPU.

#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Foundation/Foundation.h>

#include <filament/Engine.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/View.h>
#include <filament/Camera.h>
#include <filament/SwapChain.h>
#include <filament/VertexBuffer.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderableManager.h>
#include <filament/TransformManager.h>
#include <filament/LightManager.h>
#include <filament/Skybox.h>
#include <filament/Viewport.h>
#include <utils/EntityManager.h>
#include <geometry/SurfaceOrientation.h>
#include <math/mat4.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace filament;
using namespace filament::math;

static constexpr uint32_t kWidth = 512;
static constexpr uint32_t kHeight = 512;

struct Vertex {
    float3 position;
    quatf tangents;
};

// A unit cube, four verts per face so each face keeps its own flat normal.
static const float3 kPositions[24] = {
    {-1,-1, 1},{ 1,-1, 1},{ 1, 1, 1},{-1, 1, 1}, // +Z
    { 1,-1,-1},{-1,-1,-1},{-1, 1,-1},{ 1, 1,-1}, // -Z
    { 1,-1, 1},{ 1,-1,-1},{ 1, 1,-1},{ 1, 1, 1}, // +X
    {-1,-1,-1},{-1,-1, 1},{-1, 1, 1},{-1, 1,-1}, // -X
    {-1, 1, 1},{ 1, 1, 1},{ 1, 1,-1},{-1, 1,-1}, // +Y
    {-1,-1,-1},{ 1,-1,-1},{ 1,-1, 1},{-1,-1, 1}, // -Y
};

static const float3 kNormals[24] = {
    {0,0,1},{0,0,1},{0,0,1},{0,0,1},
    {0,0,-1},{0,0,-1},{0,0,-1},{0,0,-1},
    {1,0,0},{1,0,0},{1,0,0},{1,0,0},
    {-1,0,0},{-1,0,0},{-1,0,0},{-1,0,0},
    {0,1,0},{0,1,0},{0,1,0},{0,1,0},
    {0,-1,0},{0,-1,0},{0,-1,0},{0,-1,0},
};

static const uint16_t kIndices[36] = {
     0, 1, 2,  2, 3, 0,   4, 5, 6,  6, 7, 4,
     8, 9,10, 10,11, 8,  12,13,14, 14,15,12,
    16,17,18, 18,19,16,  20,21,22, 22,23,20,
};

static std::vector<uint8_t> readFile(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "FATAL: cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> data(n);
    if (fread(data.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "FATAL: short read\n"); exit(1); }
    fclose(f);
    return data;
}

// Writes the rendered buffer out so the result can be eyeballed, not just
// trusted. BGRA is what the swap chain demands, so the bitmap context is told
// to read it back the same way.
static void writePNG(CVPixelBufferRef pb, const char* path) {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    void* base = CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        base, kWidth, kHeight, 8, stride, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        nullptr, (const UInt8*)path, strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(dest, img, nullptr);
    bool ok = CGImageDestinationFinalize(dest);

    CFRelease(dest); CFRelease(url); CGImageRelease(img);
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    printf("%s  wrote %s\n", ok ? "OK  " : "FAIL", path);
}

int main() {
    @autoreleasepool {
        // The IOSurface backing is what makes the buffer shareable with Flutter's
        // compositor without a readback; without it this would be plain host memory.
        NSDictionary* attrs = @{
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (NSString*)kCVPixelBufferMetalCompatibilityKey  : @YES,
        };
        CVPixelBufferRef pixelBuffer = nullptr;
        CVReturn cvr = CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                           kCVPixelFormatType_32BGRA,
                                           (__bridge CFDictionaryRef)attrs, &pixelBuffer);
        if (cvr != kCVReturnSuccess) { fprintf(stderr, "FATAL: CVPixelBufferCreate %d\n", cvr); return 1; }
        printf("OK    CVPixelBuffer %ux%u BGRA, IOSurface=%p\n",
               kWidth, kHeight, CVPixelBufferGetIOSurface(pixelBuffer));

        Engine* engine = Engine::create(Engine::Backend::METAL);
        if (!engine) { fprintf(stderr, "FATAL: no Metal engine\n"); return 1; }
        printf("OK    Filament engine, backend=METAL\n");

        SwapChain* swapChain = engine->createSwapChain(
            (void*)pixelBuffer, SwapChain::CONFIG_APPLE_CVPIXELBUFFER);
        printf("OK    SwapChain from CVPixelBuffer (zero-copy path)\n");

        Renderer* renderer = engine->createRenderer();
        Scene* scene = engine->createScene();
        View* view = engine->createView();

        utils::Entity cameraEntity = utils::EntityManager::get().create();
        Camera* camera = engine->createCamera(cameraEntity);
        camera->setProjection(50.0, double(kWidth) / double(kHeight), 0.1, 100.0);
        camera->lookAt({3.2, 2.4, 3.2}, {0, 0, 0}, {0, 1, 0});

        view->setCamera(camera);
        view->setScene(scene);
        view->setViewport({0, 0, kWidth, kHeight});

        scene->setSkybox(Skybox::Builder().color({0.10f, 0.12f, 0.16f, 1.0f}).build(*engine));

        // Tangent frames are quaternions in Filament, so the flat face normals get
        // converted rather than handed over directly.
        quatf quats[24];
        auto* orientation = geometry::SurfaceOrientation::Builder()
            .vertexCount(24).normals(kNormals).build();
        orientation->getQuats(quats, 24);
        delete orientation;

        Vertex vertices[24];
        for (int i = 0; i < 24; i++) { vertices[i] = { kPositions[i], quats[i] }; }

        VertexBuffer* vb = VertexBuffer::Builder()
            .vertexCount(24).bufferCount(1)
            .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3,
                       offsetof(Vertex, position), sizeof(Vertex))
            .attribute(VertexAttribute::TANGENTS, 0, VertexBuffer::AttributeType::FLOAT4,
                       offsetof(Vertex, tangents), sizeof(Vertex))
            .build(*engine);
        vb->setBufferAt(*engine, 0,
            VertexBuffer::BufferDescriptor(vertices, sizeof(vertices), nullptr));

        IndexBuffer* ib = IndexBuffer::Builder()
            .indexCount(36).bufferType(IndexBuffer::IndexType::USHORT).build(*engine);
        ib->setBuffer(*engine,
            IndexBuffer::BufferDescriptor(kIndices, sizeof(kIndices), nullptr));

        auto matData = readFile("lit.filamat");
        Material* material = Material::Builder()
            .package(matData.data(), matData.size()).build(*engine);
        MaterialInstance* mi = material->createInstance();
        mi->setParameter("baseColor", float3{0.85f, 0.28f, 0.18f});
        mi->setParameter("roughness", 0.35f);
        mi->setParameter("metallic", 0.0f);
        printf("OK    material orbisLit compiled and instanced\n");

        utils::Entity cube = utils::EntityManager::get().create();
        RenderableManager::Builder(1)
            .boundingBox({{-1,-1,-1}, {1,1,1}})
            .material(0, mi)
            .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, vb, ib, 0, 36)
            .receiveShadows(true).castShadows(true)
            .build(*engine, cube);
        scene->addEntity(cube);

        // A slight tilt so more than one face is lit, which is what makes the
        // shading visible in a still frame.
        auto& tm = engine->getTransformManager();
        tm.setTransform(tm.getInstance(cube),
            mat4f::rotation(0.6, float3{0, 1, 0}) * mat4f::rotation(0.3, float3{1, 0, 0}));

        utils::Entity light = utils::EntityManager::get().create();
        LightManager::Builder(LightManager::Type::SUN)
            .color({1.0f, 0.96f, 0.9f}).intensity(110000.0f)
            .direction({-0.6f, -1.0f, -0.8f})
            .castShadows(true)
            .build(*engine, light);
        scene->addEntity(light);
        printf("OK    scene: cube + sun + skybox\n");

        // Filament's frame skipper can reject early frames while the pipeline
        // fills, so the render loop keeps asking until one is accepted.
        int rendered = 0;
        for (int i = 0; i < 8 && rendered == 0; i++) {
            if (renderer->beginFrame(swapChain)) {
                renderer->render(view);
                renderer->endFrame();
                rendered++;
            }
        }
        engine->flushAndWait();
        printf("%s  rendered %d frame(s)\n", rendered ? "OK  " : "FAIL", rendered);
        if (!rendered) return 1;

        writePNG(pixelBuffer, "spike_output.png");

        // Filament asserts on any resource still alive when the engine goes down,
        // so everything created above is torn down in reverse order.
        auto& em = utils::EntityManager::get();
        scene->remove(cube);
        scene->remove(light);
        engine->destroy(cube);   em.destroy(cube);
        engine->destroy(light);  em.destroy(light);
        engine->destroyCameraComponent(cameraEntity); em.destroy(cameraEntity);
        engine->destroy(scene->getSkybox());
        engine->destroy(mi);
        engine->destroy(material);
        engine->destroy(vb);
        engine->destroy(ib);
        engine->destroy(view);
        engine->destroy(scene);
        engine->destroy(renderer);
        engine->destroy(swapChain);
        Engine::destroy(&engine);
        CVPixelBufferRelease(pixelBuffer);
        printf("OK    teardown clean\n");
        return 0;
    }
}
