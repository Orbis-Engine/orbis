#import "OrbisRenderer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/LightManager.h>
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
#include <geometry/SurfaceOrientation.h>
#include <math/mat4.h>
#include <utils/EntityManager.h>

#include <vector>
#include <utils/Panic.h>

#include <exception>

#include "generated/lit_material.h"

using namespace filament;
using namespace filament::math;

namespace {

/// Two surfaces, alternated. Filament finishes writing one while Flutter's
/// raster thread samples the other, so a frame is never read while it is being
/// drawn. Each needs its own swap chain because a Filament swap chain is bound
/// to one CVPixelBuffer for its lifetime.
constexpr int kOrbisBufferCount = 2;

struct Vertex {
  float3 position;
  quatf tangents;
};

// A unit cube with four vertices per face, so every face keeps a flat normal
// and the lighting reads as six distinct planes rather than a smooth blob.
constexpr float3 kPositions[24] = {
    {-1, -1, 1},  {1, -1, 1},   {1, 1, 1},    {-1, 1, 1},    // +Z
    {1, -1, -1},  {-1, -1, -1}, {-1, 1, -1},  {1, 1, -1},    // -Z
    {1, -1, 1},   {1, -1, -1},  {1, 1, -1},   {1, 1, 1},     // +X
    {-1, -1, -1}, {-1, -1, 1},  {-1, 1, 1},   {-1, 1, -1},   // -X
    {-1, 1, 1},   {1, 1, 1},    {1, 1, -1},   {-1, 1, -1},   // +Y
    {-1, -1, -1}, {1, -1, -1},  {1, -1, 1},   {-1, -1, 1},   // -Y
};

constexpr float3 kNormals[24] = {
    {0, 0, 1},  {0, 0, 1},  {0, 0, 1},  {0, 0, 1},
    {0, 0, -1}, {0, 0, -1}, {0, 0, -1}, {0, 0, -1},
    {1, 0, 0},  {1, 0, 0},  {1, 0, 0},  {1, 0, 0},
    {-1, 0, 0}, {-1, 0, 0}, {-1, 0, 0}, {-1, 0, 0},
    {0, 1, 0},  {0, 1, 0},  {0, 1, 0},  {0, 1, 0},
    {0, -1, 0}, {0, -1, 0}, {0, -1, 0}, {0, -1, 0},
};

constexpr uint16_t kIndices[36] = {
    0,  1,  2,  2,  3,  0,  4,  5,  6,  6,  7,  4,
    8,  9,  10, 10, 11, 8,  12, 13, 14, 14, 15, 12,
    16, 17, 18, 18, 19, 16, 20, 21, 22, 22, 23, 20,
};

/// An IOSurface-backed BGRA buffer — the format Filament's Apple swap chain
/// requires and the one Flutter's compositor can adopt without a readback.
CVPixelBufferRef CreatePixelBuffer(uint32_t width, uint32_t height) {
  NSDictionary *attributes = @{
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferRef buffer = nullptr;
  CVReturn result = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      (__bridge CFDictionaryRef)attributes, &buffer);
  return result == kCVReturnSuccess ? buffer : nullptr;
}

}  // namespace

@interface OrbisRenderer ()
- (void)startWithWidth:(uint32_t)width height:(uint32_t)height;
- (void)drawAtTime:(double)time;
@end

@implementation OrbisRenderer {
  Engine *_engine;
  Renderer *_renderer;
  Scene *_scene;
  View *_view;
  Camera *_camera;
  utils::Entity _cameraEntity;
  std::vector<utils::Entity> _objects;
  std::vector<MaterialInstance *> _instances;
  utils::Entity _light;
  bool _sceneIsOwnedByHost;
  Skybox *_skybox;
  Material *_material;
  VertexBuffer *_vertexBuffer;
  IndexBuffer *_indexBuffer;

  CVPixelBufferRef _buffers[kOrbisBufferCount];
  SwapChain *_swapChains[kOrbisBufferCount];
  NSInteger _backIndex;
  NSInteger _presentedIndex;

  uint32_t _width;
  uint32_t _height;
  uint32_t _pendingWidth;
  uint32_t _pendingHeight;
  float _fieldOfView;

  NSLock *_presentLock;
  BOOL _disposed;
  int _frameCount;
}

- (nullable instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height {
  if (!(self = [super init])) return nil;

  // Filament reports misuse by throwing, and an uncaught throw here would take
  // the whole application down rather than the one viewport that failed. The
  // message is worth keeping: it names the precondition, which is most of the
  // diagnosis.
  try {
    [self startWithWidth:width height:height];
  } catch (const std::exception &error) {
    NSLog(@"[orbis] Filament refused to start: %s", error.what());
    return nil;
  } catch (...) {
    NSLog(@"[orbis] Filament refused to start for an unknown reason.");
    return nil;
  }
  return self;
}

- (void)startWithWidth:(uint32_t)width height:(uint32_t)height {
  _width = MAX(width, 1u);
  _height = MAX(height, 1u);
  _pendingWidth = _width;
  _pendingHeight = _height;
  _presentedIndex = -1;
  _presentLock = [[NSLock alloc] init];

  _engine = Engine::create(Engine::Backend::METAL);
  ASSERT_PRECONDITION(_engine != nullptr, "Metal is unavailable.");

  _renderer = _engine->createRenderer();
  _scene = _engine->createScene();
  _view = _engine->createView();

  _cameraEntity = utils::EntityManager::get().create();
  _camera = _engine->createCamera(_cameraEntity);
  _camera->lookAt({3.2, 2.4, 3.2}, {0, 0, 0}, {0, 1, 0});

  _view->setCamera(_camera);
  _view->setScene(_scene);

  _skybox = Skybox::Builder().color({0.10f, 0.12f, 0.16f, 1.0f}).build(*_engine);
  _scene->setSkybox(_skybox);

  [self buildGeometry];
  [self allocateBuffers];
  [self applyViewportSize];

  // Something to look at until a host sends a scene, so an empty viewport is
  // recognisably working rather than indistinguishable from a broken one.
  const float identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  const float colour[3] = {0.85f, 0.28f, 0.18f};
  [self setObjects:identity colours:colour count:1];
}

- (void)buildGeometry {
  // Filament wants tangent frames as quaternions, so the flat face normals are
  // converted rather than handed over directly.
  quatf quats[24];
  auto *orientation = geometry::SurfaceOrientation::Builder()
                          .vertexCount(24)
                          .normals(kNormals)
                          .build();
  orientation->getQuats(quats, 24);
  delete orientation;

  // Heap, not stack, and freed by the descriptor's callback. Filament does not
  // copy vertex data — it holds the pointer until its driver thread performs
  // the upload, which happens after this method has returned. A stack array
  // here is read back as whatever later occupied the frame: the cube arrives
  // with garbage positions and garbage tangent frames, so it renders as an
  // unlit wedge rather than a lit cube.
  auto *vertices = new Vertex[24];
  for (int i = 0; i < 24; i++) vertices[i] = {kPositions[i], quats[i]};

  _vertexBuffer =
      VertexBuffer::Builder()
          .vertexCount(24)
          .bufferCount(1)
          .attribute(VertexAttribute::POSITION, 0,
                     VertexBuffer::AttributeType::FLOAT3,
                     offsetof(Vertex, position), sizeof(Vertex))
          .attribute(VertexAttribute::TANGENTS, 0,
                     VertexBuffer::AttributeType::FLOAT4,
                     offsetof(Vertex, tangents), sizeof(Vertex))
          .build(*_engine);
  _vertexBuffer->setBufferAt(
      *_engine, 0,
      VertexBuffer::BufferDescriptor(
          vertices, sizeof(Vertex) * 24,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<Vertex *>(buffer);
          }));

  _indexBuffer = IndexBuffer::Builder()
                     .indexCount(36)
                     .bufferType(IndexBuffer::IndexType::USHORT)
                     .build(*_engine);
  // kIndices is a namespace-scope constant, so it outlives the upload without
  // a callback — unlike the vertices above.
  _indexBuffer->setBuffer(
      *_engine,
      IndexBuffer::BufferDescriptor(kIndices, sizeof(kIndices), nullptr));

  _material = Material::Builder()
                  .package(klitMaterial, klitMaterial_len)
                  .build(*_engine);

  _light = utils::EntityManager::get().create();
  LightManager::Builder(LightManager::Type::SUN)
      .color({1.0f, 0.96f, 0.9f})
      .intensity(110000.0f)
      .direction({-0.6f, -1.0f, -0.8f})
      .castShadows(true)
      .build(*_engine, _light);
  _scene->addEntity(_light);
}

- (void)clearObjects {
  auto &entities = utils::EntityManager::get();
  for (utils::Entity object : _objects) {
    _scene->remove(object);
    _engine->destroy(object);
    entities.destroy(object);
  }
  for (MaterialInstance *instance : _instances) {
    _engine->destroy(instance);
  }
  _objects.clear();
  _instances.clear();
}

- (void)setObjects:(const float *)transforms
           colours:(const float *)colours
             count:(uint32_t)count {
  if (_disposed) return;
  [self clearObjects];

  auto &transformManager = _engine->getTransformManager();

  for (uint32_t i = 0; i < count; i++) {
    // One instance per object, because the colour is a material parameter and
    // sharing an instance would make every object the last one's colour.
    MaterialInstance *instance = _material->createInstance();
    instance->setParameter(
        "baseColor",
        float3{colours[i * 3], colours[i * 3 + 1], colours[i * 3 + 2]});
    instance->setParameter("roughness", 0.4f);
    instance->setParameter("metallic", 0.0f);
    _instances.push_back(instance);

    utils::Entity object = utils::EntityManager::get().create();
    RenderableManager::Builder(1)
        .boundingBox({{-1, -1, -1}, {1, 1, 1}})
        .material(0, instance)
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, _vertexBuffer,
                  _indexBuffer, 0, 36)
        .receiveShadows(true)
        .castShadows(true)
        .build(*_engine, object);

    mat4f matrix;
    std::memcpy(&matrix, transforms + i * 16, sizeof(float) * 16);
    transformManager.setTransform(transformManager.getInstance(object), matrix);

    _scene->addEntity(object);
    _objects.push_back(object);
  }

  _sceneIsOwnedByHost = true;
}

- (void)setSunDirection:(const float *)direction
                 colour:(const float *)colour
            illuminance:(float)illuminance {
  if (_disposed) return;

  auto &lights = _engine->getLightManager();
  auto instance = lights.getInstance(_light);
  if (!instance) return;

  lights.setDirection(instance,
                      float3{direction[0], direction[1], direction[2]});
  lights.setColor(instance, LinearColor{colour[0], colour[1], colour[2]});
  lights.setIntensity(instance, illuminance);
}

- (void)setCameraPosition:(const float *)position
                   target:(const float *)target
              fieldOfView:(float)fieldOfView {
  if (_disposed) return;

  _camera->lookAt({position[0], position[1], position[2]},
                  {target[0], target[1], target[2]}, {0, 1, 0});
  _camera->setProjection(fieldOfView, double(_width) / double(_height), 0.1,
                         1000.0);
  _fieldOfView = fieldOfView;
}

- (void)allocateBuffers {
  for (int i = 0; i < kOrbisBufferCount; i++) {
    _buffers[i] = CreatePixelBuffer(_width, _height);
    _swapChains[i] =
        _buffers[i] ? _engine->createSwapChain(
                          (void *)_buffers[i],
                          SwapChain::CONFIG_APPLE_CVPIXELBUFFER)
                    : nullptr;
  }
  _backIndex = 0;
  _presentedIndex = -1;
}

- (void)releaseBuffers {
  for (int i = 0; i < kOrbisBufferCount; i++) {
    if (_swapChains[i]) {
      _engine->destroy(_swapChains[i]);
      _swapChains[i] = nullptr;
    }
    if (_buffers[i]) {
      CVPixelBufferRelease(_buffers[i]);
      _buffers[i] = nullptr;
    }
  }
}

- (void)applyViewportSize {
  _view->setViewport({0, 0, _width, _height});
  _camera->setProjection(_fieldOfView > 0 ? _fieldOfView : 50.0,
                         double(_width) / double(_height), 0.1, 1000.0);
}

- (void)resizeToWidth:(uint32_t)width height:(uint32_t)height {
  [_presentLock lock];
  _pendingWidth = MAX(width, 1u);
  _pendingHeight = MAX(height, 1u);
  [_presentLock unlock];
}

- (void)renderAtTime:(double)time {
  if (_disposed) return;
  try {
    [self drawAtTime:time];
  } catch (const std::exception &error) {
    NSLog(@"[orbis] render failed, stopping this viewport: %s", error.what());
    _disposed = YES;
  } catch (...) {
    NSLog(@"[orbis] render failed for an unknown reason.");
    _disposed = YES;
  }
}

- (void)drawAtTime:(double)time {

  // Resizing reallocates swap chains, which only the engine's own thread may
  // do, so a request from the UI thread is applied here instead of there.
  [_presentLock lock];
  BOOL needsResize = (_pendingWidth != _width || _pendingHeight != _height);
  uint32_t newWidth = _pendingWidth;
  uint32_t newHeight = _pendingHeight;
  [_presentLock unlock];

  if (needsResize) {
    [_presentLock lock];
    _presentedIndex = -1;  // nothing valid at the new size yet
    [_presentLock unlock];
    [self releaseBuffers];
    _width = newWidth;
    _height = newHeight;
    [self allocateBuffers];
    [self applyViewportSize];
  }

  SwapChain *target = _swapChains[_backIndex];
  if (!target) return;

  // The placeholder turns so an unconfigured viewport is visibly alive. A
  // scene sent by a host is left exactly where the host put it — a renderer
  // that quietly animates somebody's content is worse than a still one.
  if (!_sceneIsOwnedByHost && !_objects.empty()) {
    auto &transforms = _engine->getTransformManager();
    transforms.setTransform(
        transforms.getInstance(_objects.front()),
        mat4f::rotation(time * 0.7, float3{0, 1, 0}) *
            mat4f::rotation(time * 0.35, float3{1, 0, 0}));
  }

  if (!_renderer->beginFrame(target)) return;
  _renderer->render(_view);
  _renderer->endFrame();

  // Flutter may sample the moment this returns, so the frame has to be on the
  // surface before it is advertised as presented.
  _engine->flushAndWait();

  [_presentLock lock];
  _presentedIndex = _backIndex;
  _backIndex = (_backIndex + 1) % kOrbisBufferCount;
  [_presentLock unlock];

  // Debug aid: dumps exactly the buffer Flutter samples, which separates a
  // rendering fault from a handoff fault. Enabled by an environment variable
  // so it costs nothing when unset.
  if (++_frameCount == 60 && getenv("ORBIS_DUMP_FRAME")) {
    // The app is sandboxed, so this goes to the container's temporary
    // directory rather than anywhere the caller might name.
    NSString *path =
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"orbis_frame.png"];
    [self writeBuffer:_buffers[_presentedIndex] toPath:path.UTF8String];
  }
}

- (void)writeBuffer:(CVPixelBufferRef)buffer toPath:(const char *)path {
  if (!buffer) return;
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetWidth(buffer),
      CVPixelBufferGetHeight(buffer), 8, CVPixelBufferGetBytesPerRow(buffer),
      space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGImageRef image = CGBitmapContextCreateImage(context);
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      nullptr, (const UInt8 *)path, strlen(path), false);
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
  CGImageDestinationAddImage(destination, image, nullptr);
  BOOL wrote = CGImageDestinationFinalize(destination);
  NSLog(@"[orbis] frame %d (%zux%zu) -> %s : %@", _frameCount,
        CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), path,
        wrote ? @"written" : @"REFUSED");
  CFRelease(destination);
  CFRelease(url);
  CGImageRelease(image);
  CGContextRelease(context);
  CGColorSpaceRelease(space);
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}

- (nullable CVPixelBufferRef)copyPresentedBuffer {
  [_presentLock lock];
  CVPixelBufferRef buffer =
      _presentedIndex >= 0 ? _buffers[_presentedIndex] : nullptr;
  if (buffer) CVPixelBufferRetain(buffer);
  [_presentLock unlock];
  return buffer;
}

- (void)dispose {
  if (_disposed) return;
  _disposed = YES;

  // Filament asserts on anything still alive when the engine goes down, so the
  // teardown mirrors construction in reverse.
  [self clearObjects];

  auto &entities = utils::EntityManager::get();
  _scene->remove(_light);
  _engine->destroy(_light);
  entities.destroy(_light);
  _engine->destroyCameraComponent(_cameraEntity);
  entities.destroy(_cameraEntity);
  _engine->destroy(_skybox);
  _engine->destroy(_material);
  _engine->destroy(_vertexBuffer);
  _engine->destroy(_indexBuffer);
  [self releaseBuffers];
  _engine->destroy(_view);
  _engine->destroy(_scene);
  _engine->destroy(_renderer);
  Engine::destroy(&_engine);
  _engine = nullptr;
}

- (void)dealloc {
  [self dispose];
}

@end
