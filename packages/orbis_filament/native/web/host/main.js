// A host for the renderer in a browser tab: no Flutter, no native ABI
// binding, only Emscripten's ccall/cwrap over the same orbis_renderer.h
// every other host drives. Publishes the same scene
// native/headless/orbis_headless.c does -- a ground, five blocks and a sun
// -- so the two are a fair comparison of the same core on two platforms.
//
// Arrays cross into wasm memory by hand (Module._malloc + HEAPF32/HEAP32),
// because ccall marshals scalars and strings but not arrays: this is the
// same shape a Dart host's dart:js_interop crossing will need in stage two,
// done once here in plain JavaScript first.
(() => {
  'use strict';

  const ORBIS_OK = 0;
  const ORBIS_BACKEND_OPENGL = 3; // WebGL 2, the only backend this build's
                                   // materials were compiled for.
  const ORBIS_SURFACE_WINDOW = 1;

  const statusEl = document.getElementById('status');
  const log = (...args) => {
    console.log('orbisWeb:', ...args);
  };

  function setStatus(html, cls) {
    statusEl.innerHTML = html;
    statusEl.className = cls || '';
  }

  // ---- wasm memory helpers ----
  // Emscripten's malloc aligns to at least 8 bytes, which is enough for the
  // int64 pairs below; nothing here needs anything wider.

  function allocF32(Module, values) {
    const ptr = Module._malloc(Math.max(values.length, 1) * 4);
    Module.HEAPF32.set(values, ptr >> 2);
    return ptr;
  }

  function allocI32(Module, values) {
    const ptr = Module._malloc(Math.max(values.length, 1) * 4);
    Module.HEAP32.set(values, ptr >> 2);
    return ptr;
  }

  // int64_t as little-endian 32-bit low/high pairs -- every key this scene
  // uses is small and non-negative, so the high word is always nought.
  function allocI64(Module, values) {
    const ptr = Module._malloc(Math.max(values.length, 1) * 8);
    for (let i = 0; i < values.length; i++) {
      Module.HEAP32[(ptr >> 2) + i * 2] = values[i];
      Module.HEAP32[(ptr >> 2) + i * 2 + 1] = 0;
    }
    return ptr;
  }

  function freeAll(Module, ptrs) {
    for (const ptr of ptrs) Module._free(ptr);
  }

  // A column-major transform: a box scaled about its middle and moved --
  // orbis_headless.c's place(), the same sixteen floats in the same order.
  function place(x, y, z, sx, sy, sz) {
    const m = new Array(16).fill(0);
    m[0] = sx; m[5] = sy; m[10] = sz;
    m[12] = x; m[13] = y; m[14] = z;
    m[15] = 1;
    return m;
  }

  function backendName(value) {
    switch (value) {
      case 1: return 'Metal';
      case 2: return 'Vulkan';
      case 3: return 'OpenGL';
      case 4: return 'WebGPU';
      default: return 'default';
    }
  }

  function readNote(Module, renderer, index) {
    const outPtr = Module._malloc(8); // two char* out-params, side by side
    try {
      const ok = Module.ccall(
        'orbis_renderer_note', 'number',
        ['number', 'number', 'number', 'number'],
        [renderer, index, outPtr, outPtr + 4]);
      if (ok !== ORBIS_OK) return null;
      const aboutPtr = Module.HEAPU32[outPtr >> 2];
      const sayingPtr = Module.HEAPU32[(outPtr >> 2) + 1];
      return {
        about: Module.UTF8ToString(aboutPtr),
        saying: Module.UTF8ToString(sayingPtr),
      };
    } finally {
      Module._free(outPtr);
    }
  }

  // Emscripten's own active WebGL context, inspected only after the
  // renderer has already created it -- not a second context of our own.
  function glInfo(Module) {
    const gl = Module.GLctx ||
      (Module.GL && Module.GL.currentContext && Module.GL.currentContext.GLctx);
    if (!gl) return null;
    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    return {
      version: gl.getParameter(gl.VERSION),
      renderer: dbg
        ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)
        : gl.getParameter(gl.RENDERER),
    };
  }

  function publishScene(Module, renderer) {
    const toFree = [];
    const alloc = (fn, values) => {
      const ptr = fn(Module, values);
      toFree.push(ptr);
      return ptr;
    };

    // The sky it stands under, which is also what lights the shadows.
    const skyPtr = alloc(allocF32, [0.30, 0.45, 0.70]);
    Module.ccall('orbis_renderer_set_sky_colour', 'number',
      ['number', 'number', 'number', 'number'],
      [renderer, skyPtr, 24000.0, 1]);

    // A low sun, so the blocks throw shadows worth looking at.
    const sunKeyPtr = alloc(allocI64, [1]);
    const sunKindPtr = alloc(allocI32, [0]);
    const sunFlagsPtr = alloc(allocI32, [1]);
    const sunParams = [
      1.0, 0.95, 0.88, 100000.0, 0, 0, 0,
      -0.45, -0.8, -0.55, 0, 0, 0, 0.53, 0.1,
      10.0, 80.0, 0, 0, 0, 0, 0,
    ];
    const sunParamsPtr = alloc(allocF32, sunParams);
    Module.ccall('orbis_renderer_apply_lights', 'number',
      ['number', 'number', 'number', 'number', 'number', 'number', 'number'],
      [renderer, 1, sunKeyPtr, sunKindPtr, sunFlagsPtr, sunParamsPtr, sunParams.length]);

    // A ground and five blocks, each its own colour -- the same table
    // orbis_headless.c's kObjects loop builds.
    const blocks = [
      [-1.8, 0.0, 0.2, 0.5],
      [-0.6, 0.25, -1.0, 0.75],
      [0.7, -0.1, 0.6, 0.4],
      [1.8, 0.4, -0.5, 0.9],
      [0.0, -0.25, 1.9, 0.25],
    ];
    const tints = [
      [0.55, 0.55, 0.5], [0.85, 0.28, 0.18], [0.20, 0.55, 0.85],
      [0.95, 0.75, 0.2], [0.35, 0.75, 0.35], [0.75, 0.35, 0.8],
    ];
    const kObjects = 6;
    const keys = [100, 101, 102, 103, 104, 105];
    const meshes = new Array(kObjects).fill(-1); // the built-in cube
    const flags = new Array(kObjects).fill(1 | 2 | 4); // casts, receives, drawn
    const materials = new Array(kObjects).fill(-1);
    const morphCounts = new Array(kObjects).fill(0); // no morphing

    let transforms = place(0.0, -0.55, 0.0, 6.0, 0.05, 6.0);
    for (const b of blocks) {
      transforms = transforms.concat(place(b[0], b[1] - 0.5 + b[3], b[2], b[3], b[3], b[3]));
    }
    const colours = [].concat(...tints);

    const keysPtr = alloc(allocI64, keys);
    const transformsPtr = alloc(allocF32, transforms);
    const coloursPtr = alloc(allocF32, colours);
    const meshesPtr = alloc(allocI32, meshes);
    const flagsPtr = alloc(allocI32, flags);
    const materialsPtr = alloc(allocI32, materials);
    const morphCountsPtr = alloc(allocI32, morphCounts);

    const objectsOk = Module.ccall('orbis_renderer_apply_objects', 'number', [
      'number', 'number', 'number', 'number', 'number', 'number', 'number',
      'number', 'number', 'number', 'number', 'number', 'number', 'number', 'number',
    ], [
      renderer, kObjects, keysPtr, transformsPtr, transforms.length,
      coloursPtr, colours.length, meshesPtr, flagsPtr, materialsPtr,
      morphCountsPtr, 0, 0, 0, 0,
    ]);

    const eyePtr = alloc(allocF32, [5.5, 3.6, 6.5]);
    const lookPtr = alloc(allocF32, [0.0, 0.0, 0.0]);
    Module.ccall('orbis_renderer_set_camera', 'number',
      ['number', 'number', 'number', 'number', 'number', 'number', 'number'],
      [renderer, eyePtr, lookPtr, 42.0, 0, 10.0, 0.0]);

    Module.ccall('orbis_renderer_set_exposure', 'number',
      ['number', 'number', 'number', 'number'],
      [renderer, 16.0, 1.0 / 125.0, 100.0]);

    freeAll(Module, toFree);
    return objectsOk === ORBIS_OK;
  }

  async function main() {
    const canvas = document.getElementById('canvas');
    let Module;
    try {
      Module = await OrbisRendererModule({ canvas });
    } catch (err) {
      setStatus('the module failed to load: ' + err, 'bad');
      throw err;
    }
    log('module ready');

    const renderer = Module.ccall(
      'orbis_web_create_on_canvas', 'number',
      ['number', 'string', 'number', 'number'],
      [ORBIS_BACKEND_OPENGL, '#canvas', canvas.width, canvas.height]);

    if (renderer === 0) {
      setStatus(
        'the renderer would not start on this canvas -- see the console ' +
        'for what Filament refused and why.', 'bad');
      log('orbis_renderer_create failed (see the [orbis] lines above)');
      return;
    }
    log('renderer created', renderer);

    if (!publishScene(Module, renderer)) {
      setStatus('the scene was refused -- see the console.', 'bad');
      log('apply_objects refused the scene');
      return;
    }
    log('scene published: ground, five blocks, one sun, camera, exposure');

    // What the ABI says about itself, read back through the same calls a
    // Dart or Kotlin host would use -- not a side channel into Filament.
    const backend = Module.ccall('orbis_renderer_backend', 'number', ['number'], [renderer]);
    const noteCount = Module.ccall('orbis_renderer_notes', 'number', ['number'], [renderer]);
    const notes = [];
    for (let i = 0; i < noteCount; i++) {
      const note = readNote(Module, renderer, i);
      if (note) notes.push(note);
    }
    for (const note of notes) log(`note[${note.about}]: ${note.saying}`);

    // A bonus, one-shot check, not load-bearing for this page's own
    // on-screen verification: orbis_renderer_request_capture/read_capture
    // go through filament::Renderer::readPixels against whatever the swap
    // chain's default render target is. ORBIS_SURFACE_HEADLESS cannot
    // allocate on this backend (see OrbisSurfaceWeb.cpp), but this is a
    // ORBIS_SURFACE_WINDOW canvas chain, which is a different question --
    // asked once rather than every frame, because polling read_capture
    // repeatedly forces a glReadPixels each time, which stalls the GPU
    // badly enough under headless Chrome's --virtual-time-budget that its
    // own --screenshot never got taken the first time this ran that way.
    let captureChecked = false;
    let frames = 0;
    const draw = (nowMs) => {
      Module.ccall('orbis_renderer_draw', 'number', ['number', 'number'],
        [renderer, nowMs / 1000.0]);
      frames++;
      if (frames === 3) {
        Module.ccall('orbis_renderer_request_capture', 'number', ['number'], [renderer]);
      }
      if (!captureChecked && frames === 6) {
        captureChecked = true;
        const outPtr = Module._malloc(8);
        const bytes = Module.ccall('orbis_renderer_read_capture', 'number',
          ['number', 'number', 'number', 'number', 'number'],
          [renderer, 0, 0, outPtr, outPtr + 4]);
        Module._free(outPtr);
        log(bytes > 0
          ? `read_capture: ${bytes} bytes came back on frame ${frames} (this backend's window surface can be read back)`
          : `read_capture: nothing came back by frame ${frames} (draw and screenshot the canvas instead, which is what this page verifies with)`);
      }
      requestAnimationFrame(draw);
    };
    requestAnimationFrame(draw);

    // One tick so the first real frame is on screen before the panel (and
    // any screenshot taken shortly after) reads the canvas.
    requestAnimationFrame(() => {
      const gl = glInfo(Module);
      const lines = [
        `backend: ${backendName(backend)} (orbis_renderer_backend)`,
        `surface: ORBIS_SURFACE_WINDOW onto canvas selector "#canvas" (OrbisSurfaceWeb.cpp)`,
        gl ? `GL: ${gl.version} / ${gl.renderer}` : 'GL: see the console -- Filament logs its own GL_VERSION/GL_RENDERER at startup, and GLctx is an internal Emscripten closure variable this build does not export',
        `notes: ${noteCount}`,
        ...notes.map((n) => `  [${n.about}] ${n.saying}`),
        notes.length === 0
          ? '  (none -- if this ever reaches feature level 3 the slim-surface note above would not fire)'
          : '',
      ].filter(Boolean);
      setStatus(lines.join('\n'), notes.some((n) => n.about === 'surface') ? 'warn' : 'ok');
      log('status', lines);
    });
  }

  main().catch((err) => {
    console.error('orbisWeb: fatal', err);
    setStatus('fatal error -- see the console: ' + err, 'bad');
  });
})();
