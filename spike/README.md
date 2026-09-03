# M0 — the renderer bridge

The question this answers: can Filament put a frame in front of Flutter without
a round trip through the CPU? Every other decision in the engine depends on the
answer, so it was worth settling before anything was built on top of it.

It can, and the path is short. Filament's `SwapChain` accepts a
`CVPixelBufferRef` directly under `CONFIG_APPLE_CVPIXELBUFFER`, and a
`CVPixelBuffer` is exactly what Flutter's macOS and iOS texture registry takes
back from `FlutterTexture.copyPixelBuffer`. Backed by an `IOSurface`, the same
memory is written by Filament and sampled by Flutter's compositor. No copy, no
readback, no format conversion.

## Running it

Fetch the Filament SDK once:

```sh
mkdir -p third_party && cd third_party
curl -L -o filament-mac.tgz \
  https://github.com/google/filament/releases/download/v1.76.0/filament-v1.76.0-mac.tgz
mkdir -p filament-mac && tar xzf filament-mac.tgz -C filament-mac
```

Then:

```sh
./spike/build.sh
```

It compiles `lit.mat` with `matc`, builds the harness, renders one frame and
writes `spike_output.png` — a lit cube on a dark ground, shaded per face.

## What it establishes

- Filament's Metal backend runs headless, with no window and no view hierarchy.
- A swap chain over a `CVPixelBuffer` renders correctly at the pixel level.
- Tone mapping and sRGB conversion happen inside Filament, so what lands in the
  buffer is display-ready and needs nothing from Flutter but compositing.
- Engine teardown is clean, which matters because the editor will create and
  destroy these per viewport.

## What it does not

The harness renders one frame and exits. It does not register a Flutter texture,
drive a render loop, or handle resize — that is M1, and it is plumbing rather
than risk now that the format handoff is settled.
