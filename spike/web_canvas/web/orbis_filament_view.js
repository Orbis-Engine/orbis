// The JavaScript half of the Orbis web spike.
//
// It owns everything Filament for one canvas (engine, swap chain, renderer,
// scene, view, camera, the cube and its material) and the
// requestAnimationFrame loop that draws it. Dart never calls Filament itself:
// it sends the scene as bytes through apply(), the one door in. That keeps the
// boundary the shape the native renderer already has, where Dart hands C++ a
// scene message over the C ABI, and it is the boundary either web route in
// README.md would keep.
//
// Loaded by a plain <script> tag in index.html after filament.js, so the
// global `Filament` that Emscripten defines is already there.
'use strict';

(() => {
  // Everything Filament.init downloads before it reports ready. The material
  // is compiled by tool/build.sh with matc for WebGL2 (opengl, mobile).
  const MATERIAL_URL = 'filament/spin.filamat';

  // Scene message opcodes, mirrored in lib/scene_message.dart.
  const OP_SET_BASE_COLOUR = 1; // r, g, b: sRGB, 0 to 1
  const OP_SET_SPIN = 2; // radians per second about Y

  // The one Orbis entity this spike knows. Ids are Orbis's, not Filament's;
  // the renderer keeps the table between them, as the native one does.
  const CUBE = 1;

  const BACKENDS = ['DEFAULT', 'OPENGL', 'VULKAN', 'METAL', 'WEBGPU', 'NOOP'];

  // A unit cube with four vertices a face, so each face keeps its own flat
  // normal: the mesh the Apple spike (spike/cube_to_pixelbuffer.mm) drew.
  const POSITIONS = new Float32Array([
    -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1, // +Z
    1, -1, -1, -1, -1, -1, -1, 1, -1, 1, 1, -1, // -Z
    1, -1, 1, 1, -1, -1, 1, 1, -1, 1, 1, 1, // +X
    -1, -1, -1, -1, -1, 1, -1, 1, 1, -1, 1, -1, // -X
    -1, 1, 1, 1, 1, 1, 1, 1, -1, -1, 1, -1, // +Y
    -1, -1, -1, 1, -1, -1, 1, -1, 1, -1, -1, 1, // -Y
  ]);
  const FACE_NORMALS = [[0, 0, 1], [0, 0, -1], [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0]];
  const INDICES = new Uint16Array([
    0, 1, 2, 2, 3, 0, 4, 5, 6, 6, 7, 4,
    8, 9, 10, 10, 11, 8, 12, 13, 14, 14, 15, 12,
    16, 17, 18, 18, 19, 16, 20, 21, 22, 22, 23, 20,
  ]);

  // A fixed tilt towards the camera, so three faces show and the shading
  // reads in a still frame.
  const TILT = 0.35;

  let filamentReady = null;

  // Filament.init compiles the wasm and fetches the listed assets, once a
  // page. It has no failure callback, so a timeout stands in for one rather
  // than leave Dart waiting for ever on a missing file.
  function initFilament() {
    if (!filamentReady) {
      filamentReady = new Promise((resolve, reject) => {
        if (typeof Filament === 'undefined') {
          reject(new Error('filament.js did not load: run tool/build.sh'));
          return;
        }
        const timeout = setTimeout(
          () => reject(new Error('Filament.init timed out: is ' + MATERIAL_URL + ' served?')),
          30000);
        Filament.init([MATERIAL_URL], () => {
          clearTimeout(timeout);
          resolve();
        });
      });
    }
    return filamentReady;
  }

  // Resolves once Flutter has put the canvas into the document and laid it
  // out. Filament finds its canvas again by id, through
  // document.querySelector, when it makes the swap chain; a platform view's
  // element is still detached when its factory runs, and would not be found.
  function whenLaidOut(canvas) {
    return new Promise((resolve) => {
      const poll = () => {
        if (canvas.isConnected && canvas.clientWidth > 0 && canvas.clientHeight > 0) {
          resolve();
        } else {
          requestAnimationFrame(poll);
        }
      };
      poll();
    });
  }

  // Column-major rotation about Y by `angle` after a tilt about X by `tilt`:
  // the flat array of sixteen that Filament's JS bindings take as a mat4.
  function spinTransform(angle, tilt) {
    const ca = Math.cos(angle), sa = Math.sin(angle);
    const c = Math.cos(tilt), s = Math.sin(tilt);
    return [
      ca, 0, -sa, 0,
      sa * s, c, ca * s, 0,
      sa * c, -s, ca * c, 0,
      0, 0, 0, 1,
    ];
  }

  class CanvasRenderer {
    constructor(canvas) {
      this.canvas = canvas;
      const engine = this.engine = Filament.Engine.create(canvas);
      this.swapChain = engine.createSwapChain();
      this.renderer = engine.createRenderer();
      this.scene = engine.createScene();
      this.view = engine.createView();
      this.cameraEntity = Filament.EntityManager.get().create();
      this.camera = engine.createCamera(this.cameraEntity);
      this.view.setCamera(this.camera);
      this.view.setScene(this.scene);
      this.camera.lookAt([3.2, 2.4, 3.2], [0, 0, 0], [0, 1, 0]);

      this.skybox = Filament.Skybox.Builder().color([0.10, 0.12, 0.16, 1.0]).build(engine);
      this.scene.setSkybox(this.skybox);

      // A constant ambient term (one band of spherical harmonics) so the faces
      // turned from the sun are dim rather than black.
      this.indirectLight = Filament.IndirectLight.Builder()
        .irradianceSh(1, [0.55, 0.58, 0.65])
        .intensity(25000)
        .build(engine);
      this.scene.setIndirectLight(this.indirectLight);

      this.sun = Filament.EntityManager.get().create();
      Filament.LightManager.Builder(Filament.LightManager$Type.SUN)
        .color([1.0, 0.96, 0.9])
        .intensity(110000)
        .direction([-0.6, -1.0, -0.8])
        .build(engine, this.sun);
      this.scene.addEntity(this.sun);

      this.buildCube();

      // Read once, for the stats Dart shows: which GL actually drew.
      const gl = engine.context;
      const info = gl.getExtension('WEBGL_debug_renderer_info');
      this.glVersion = String(gl.getParameter(gl.VERSION));
      this.glRenderer = String(gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER));

      this.width = 0;
      this.height = 0;
      this.angle = 0;
      this.last = null;
      this.frames = 0;
      this.messages = 0;
      this.destroyed = false;
      this.frame = this.frame.bind(this);
      requestAnimationFrame(this.frame);
    }

    buildCube() {
      const engine = this.engine;

      // Filament wants tangent frames as quaternions, so the flat normals go
      // through SurfaceOrientation, as they do natively.
      const normals = new Float32Array(24 * 3);
      FACE_NORMALS.forEach((n, face) => {
        for (let v = 0; v < 4; v++) normals.set(n, (face * 4 + v) * 3);
      });
      const orientationBuilder = new Filament.SurfaceOrientation$Builder();
      orientationBuilder.vertexCount(24);
      orientationBuilder.normals(normals, 0);
      const orientation = orientationBuilder.build();
      const tangents = orientation.getQuats(24);
      orientation.delete();
      orientationBuilder.delete();

      const VA = Filament.VertexAttribute;
      const AT = Filament.VertexBuffer$AttributeType;
      this.vertexBuffer = Filament.VertexBuffer.Builder()
        .vertexCount(24)
        .bufferCount(2)
        .attribute(VA.POSITION, 0, AT.FLOAT3, 0, 12)
        .attribute(VA.TANGENTS, 1, AT.SHORT4, 0, 8)
        .normalized(VA.TANGENTS)
        .build(engine);
      this.vertexBuffer.setBufferAt(engine, 0, POSITIONS);
      this.vertexBuffer.setBufferAt(engine, 1, tangents);

      this.indexBuffer = Filament.IndexBuffer.Builder()
        .indexCount(INDICES.length)
        .bufferType(Filament.IndexBuffer$IndexType.USHORT)
        .build(engine);
      this.indexBuffer.setBuffer(engine, INDICES);

      this.material = engine.createMaterial(MATERIAL_URL);
      const instance = this.material.createInstance();
      instance.setColor3Parameter('baseColor', Filament.RgbType.sRGB, [0.85, 0.28, 0.18]);
      instance.setFloatParameter('roughness', 0.35);
      instance.setFloatParameter('metallic', 0.0);

      const entity = Filament.EntityManager.get().create();
      Filament.RenderableManager.Builder(1)
        .boundingBox({center: [0, 0, 0], halfExtent: [1, 1, 1]})
        .material(0, instance)
        .geometry(0, Filament.RenderableManager$PrimitiveType.TRIANGLES,
          this.vertexBuffer, this.indexBuffer)
        .build(engine, entity);
      this.scene.addEntity(entity);

      this.entities = new Map([[CUBE, {entity, instance, spin: 0.8}]]);
    }

    // Matches the drawing buffer to the canvas's laid-out size, in device
    // pixels. Flutter resizes the platform view's box, never the canvas's
    // backing store, so the renderer has to notice for itself.
    fitToCanvas() {
      const dpr = window.devicePixelRatio || 1;
      const width = Math.max(1, Math.round(this.canvas.clientWidth * dpr));
      const height = Math.max(1, Math.round(this.canvas.clientHeight * dpr));
      if (width === this.width && height === this.height) return;
      this.width = this.canvas.width = width;
      this.height = this.canvas.height = height;
      this.view.setViewport([0, 0, width, height]);
      this.camera.setProjectionFov(40, width / height, 0.1, 100, Filament.Camera$Fov.VERTICAL);
    }

    frame(now) {
      if (this.destroyed) return;
      // Time from the requestAnimationFrame stamp rather than a count of
      // frames, so the angle follows the clock (virtual time too, in the
      // headless captures) whatever the frame rate.
      const dt = this.last === null ? 0 : (now - this.last) / 1000;
      this.last = now;
      this.fitToCanvas();

      const cube = this.entities.get(CUBE);
      this.angle += cube.spin * dt;
      const transforms = this.engine.getTransformManager();
      const transform = transforms.getInstance(cube.entity);
      transforms.setTransform(transform, spinTransform(this.angle, TILT));
      transform.delete();

      // beginFrame may decline a frame to keep pace; only drawn frames count.
      if (this.renderer.beginFrame(this.swapChain)) {
        this.renderer.renderView(this.view);
        this.renderer.endFrame();
        this.frames++;
      }
      requestAnimationFrame(this.frame);
    }

    // The one door in from Dart. `bytes` is a Uint8Array holding a run of
    // commands, little-endian: u32 opcode, u32 entity, u32 payload length in
    // floats, then the floats. The length lets an old reader step over a new
    // opcode, so either side can grow first.
    apply(bytes) {
      const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      let at = 0;
      while (at + 12 <= data.byteLength) {
        const op = data.getUint32(at, true);
        const id = data.getUint32(at + 4, true);
        const count = data.getUint32(at + 8, true);
        at += 12;
        const f = (i) => data.getFloat32(at + 4 * i, true);
        const target = this.entities.get(id);
        if (!target) {
          console.warn(`orbisWeb: no entity ${id}`);
        } else if (op === OP_SET_BASE_COLOUR && count === 3) {
          target.instance.setColor3Parameter('baseColor', Filament.RgbType.sRGB, [f(0), f(1), f(2)]);
        } else if (op === OP_SET_SPIN && count === 1) {
          target.spin = f(0);
        } else {
          console.warn(`orbisWeb: skipped opcode ${op} with ${count} floats`);
        }
        at += 4 * count;
      }
      this.messages++;
    }

    stats() {
      return {
        frames: this.frames,
        messages: this.messages,
        backend: BACKENDS[this.engine.getBackend().value] || 'unknown',
        activeFeatureLevel: this.engine.getActiveFeatureLevel().value,
        supportedFeatureLevel: this.engine.getSupportedFeatureLevel().value,
        glVersion: this.glVersion,
        glRenderer: this.glRenderer,
        width: this.width,
        height: this.height,
      };
    }

    // Filament asserts on anything still alive when the engine goes, so all
    // of it is torn down, in reverse order of making.
    destroy() {
      if (this.destroyed) return;
      this.destroyed = true;
      const engine = this.engine;
      for (const {entity, instance} of this.entities.values()) {
        this.scene.remove(entity);
        engine.destroyEntity(entity);
        engine.destroyMaterialInstance(instance);
      }
      this.scene.remove(this.sun);
      engine.destroyEntity(this.sun);
      engine.destroyMaterial(this.material);
      engine.destroyVertexBuffer(this.vertexBuffer);
      engine.destroyIndexBuffer(this.indexBuffer);
      engine.destroyIndirectLight(this.indirectLight);
      engine.destroySkybox(this.skybox);
      engine.destroyCameraComponent(this.cameraEntity);
      engine.destroyView(this.view);
      engine.destroyScene(this.scene);
      engine.destroyRenderer(this.renderer);
      engine.destroySwapChain(this.swapChain);
      Filament.Engine.destroy(engine);
    }
  }

  // Resolves to a renderer for `canvas` once Filament is loaded and the
  // canvas is in the page. Dart awaits this through dart:js_interop.
  async function mount(canvas) {
    await initFilament();
    await whenLaidOut(canvas);
    const renderer = new CanvasRenderer(canvas);
    console.log(`orbisWeb: mounted ${canvas.id}: ${JSON.stringify(renderer.stats())}`);
    return renderer;
  }

  window.orbisWeb = {mount};
})();
