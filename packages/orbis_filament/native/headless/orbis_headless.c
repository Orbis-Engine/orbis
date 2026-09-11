/* A host for the renderer with no Flutter, no Objective-C and no window.
 *
 * It drives the C ABI and nothing else: makes a renderer on the backend it is
 * told to use, publishes a small scene — a ground, five blocks and a sun —
 * draws it offscreen, reads the frame back and writes it out as a PNG. What
 * it proves is that the renderer's core runs with nobody but a C program in
 * front of it, which is what a console host is. It is also where one starts.
 *
 *   orbis_headless [out.png] [metal|vulkan|opengl]
 */

#include "orbis_renderer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- A PNG, written without a library ----
 *
 * Deflate's stored blocks need no compressor, only a checksum each side, so
 * a PNG is sixty lines of C rather than a dependency. The file is as large as
 * the pixels, which for a proof is the right trade. */

static uint32_t crc_table[256];

static void crc_start(void) {
  for (uint32_t n = 0; n < 256; n++) {
    uint32_t c = n;
    for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    crc_table[n] = c;
  }
}

static uint32_t crc_of(const uint8_t *bytes, size_t length, uint32_t crc) {
  crc ^= 0xFFFFFFFFu;
  for (size_t i = 0; i < length; i++) {
    crc = crc_table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFFu;
}

static void put32(uint8_t *to, uint32_t value) {
  to[0] = (uint8_t)(value >> 24);
  to[1] = (uint8_t)(value >> 16);
  to[2] = (uint8_t)(value >> 8);
  to[3] = (uint8_t)value;
}

static int write_chunk(FILE *file, const char *type, const uint8_t *data,
                       size_t length) {
  uint8_t head[8];
  put32(head, (uint32_t)length);
  memcpy(head + 4, type, 4);
  uint32_t crc = crc_of(head + 4, 4, 0);
  crc = crc_of(data, length, crc);
  uint8_t tail[4];
  put32(tail, crc);
  return fwrite(head, 1, 8, file) == 8 &&
         (length == 0 || fwrite(data, 1, length, file) == length) &&
         fwrite(tail, 1, 4, file) == 4;
}

static int write_png(const char *path, const uint8_t *rgba, uint32_t width,
                     uint32_t height) {
  const size_t row = (size_t)width * 4 + 1;
  const size_t raw = row * height;
  const size_t blocks = (raw + 65534) / 65535;
  uint8_t *zlib = malloc(2 + raw + blocks * 5 + 4);
  if (zlib == NULL) return 0;

  /* The rows, each behind a filter byte of nought, then stored in blocks
   * of at most 65535 bytes with a running Adler-32 over the lot. */
  size_t at = 0;
  zlib[at++] = 0x78;
  zlib[at++] = 0x01;
  uint32_t a = 1;
  uint32_t b = 0;
  size_t done = 0;
  while (done < raw) {
    const size_t take = raw - done < 65535 ? raw - done : 65535;
    zlib[at++] = done + take == raw ? 1 : 0;
    zlib[at++] = (uint8_t)(take & 0xFF);
    zlib[at++] = (uint8_t)(take >> 8);
    zlib[at++] = (uint8_t)(~take & 0xFF);
    zlib[at++] = (uint8_t)((~take >> 8) & 0xFF);
    for (size_t i = 0; i < take; i++) {
      const size_t offset = done + i;
      const size_t column = offset % row;
      const uint8_t byte =
          column == 0 ? 0 : rgba[(offset / row) * width * 4 + column - 1];
      zlib[at++] = byte;
      a = (a + byte) % 65521;
      b = (b + a) % 65521;
    }
    done += take;
  }
  put32(zlib + at, (b << 16) | a);
  at += 4;

  uint8_t header[13];
  put32(header, width);
  put32(header + 4, height);
  header[8] = 8; /* bits per channel */
  header[9] = 6; /* RGBA */
  header[10] = header[11] = header[12] = 0;

  FILE *file = fopen(path, "wb");
  int ok = file != NULL;
  if (ok) {
    static const uint8_t signature[8] = {137, 'P', 'N', 'G', 13, 10, 26, 10};
    ok = fwrite(signature, 1, 8, file) == 8 &&
         write_chunk(file, "IHDR", header, sizeof header) &&
         write_chunk(file, "IDAT", zlib, at) &&
         write_chunk(file, "IEND", NULL, 0);
    ok = fclose(file) == 0 && ok;
  }
  free(zlib);
  return ok;
}

/* ---- The scene ---- */

static OrbisBackend backend_named(const char *name) {
  if (name == NULL) return ORBIS_BACKEND_DEFAULT;
  if (strcmp(name, "metal") == 0) return ORBIS_BACKEND_METAL;
  if (strcmp(name, "vulkan") == 0) return ORBIS_BACKEND_VULKAN;
  if (strcmp(name, "opengl") == 0) return ORBIS_BACKEND_OPENGL;
  if (strcmp(name, "webgpu") == 0) return ORBIS_BACKEND_WEBGPU;
  return ORBIS_BACKEND_DEFAULT;
}

static const char *backend_name(OrbisBackend backend) {
  switch (backend) {
    case ORBIS_BACKEND_METAL: return "Metal";
    case ORBIS_BACKEND_VULKAN: return "Vulkan";
    case ORBIS_BACKEND_OPENGL: return "OpenGL";
    case ORBIS_BACKEND_WEBGPU: return "WebGPU";
    default: return "default";
  }
}

/* A column-major transform: a box scaled about its middle and moved. */
static void place(float *m, float x, float y, float z, float sx, float sy,
                  float sz) {
  memset(m, 0, 16 * sizeof(float));
  m[0] = sx;
  m[5] = sy;
  m[10] = sz;
  m[12] = x;
  m[13] = y;
  m[14] = z;
  m[15] = 1.0f;
}

int main(int argc, char **argv) {
  const char *out = argc > 1 ? argv[1] : "orbis_headless.png";
  const OrbisBackend asked = backend_named(argc > 2 ? argv[2] : NULL);
  const uint32_t width = 960;
  const uint32_t height = 540;

  orbis_surface_desc surface = {ORBIS_SURFACE_HEADLESS, NULL};
  orbis_renderer *renderer =
      orbis_renderer_create(asked, &surface, width, height);
  if (renderer == NULL) {
    /* Not named here: ORBIS_BACKEND may have chosen for DEFAULT, and the
     * renderer's own log says which backend it tried and why it would not. */
    fprintf(stderr, "the renderer would not start; the log above says why\n");
    return 1;
  }
  printf("drawing with %s\n", backend_name(orbis_renderer_backend(renderer)));

  /* The sky it stands under, which is also what lights the shadows. */
  const float sky[3] = {0.30f, 0.45f, 0.70f};
  orbis_renderer_set_sky_colour(renderer, sky, 24000.0f, 1);

  /* A low sun, so the blocks throw shadows worth looking at. */
  const int64_t sun_key = 1;
  const int32_t sun_kind = 0;
  const int32_t sun_flags = 1;
  const float sun[22] = {1.0f, 0.95f, 0.88f, 100000.0f, 0, 0, 0,
                         -0.45f, -0.8f, -0.55f, 0, 0, 0, 0.53f, 0.1f,
                         10.0f, 80.0f, 0, 0, 0, 0, 0};
  orbis_renderer_apply_lights(renderer, 1, &sun_key, &sun_kind, &sun_flags,
                              sun, 22);

  /* A ground and five blocks, each its own colour. */
  enum { kObjects = 6 };
  int64_t keys[kObjects];
  float transforms[kObjects * 16];
  float colours[kObjects * 3];
  int32_t meshes[kObjects];
  int32_t flags[kObjects];
  int32_t materials[kObjects];
  int32_t shapes[kObjects];
  static const float blocks[5][4] = {
      {-1.8f, 0.0f, 0.2f, 0.5f}, {-0.6f, 0.25f, -1.0f, 0.75f},
      {0.7f, -0.1f, 0.6f, 0.4f}, {1.8f, 0.4f, -0.5f, 0.9f},
      {0.0f, -0.25f, 1.9f, 0.25f}};
  static const float tints[6][3] = {{0.55f, 0.55f, 0.5f}, {0.85f, 0.28f, 0.18f},
                                    {0.20f, 0.55f, 0.85f}, {0.95f, 0.75f, 0.2f},
                                    {0.35f, 0.75f, 0.35f}, {0.75f, 0.35f, 0.8f}};
  for (int i = 0; i < kObjects; i++) {
    keys[i] = 100 + i;
    meshes[i] = -1;   /* the built-in cube */
    flags[i] = 1 | 2 | 4; /* casts, receives, drawn */
    materials[i] = -1;
    shapes[i] = 0;
    memcpy(colours + i * 3, tints[i], sizeof tints[i]);
  }
  place(transforms, 0.0f, -0.55f, 0.0f, 6.0f, 0.05f, 6.0f);
  for (int i = 0; i < 5; i++) {
    const float *b = blocks[i];
    place(transforms + (i + 1) * 16, b[0], b[1] - 0.5f + b[3], b[2], b[3],
          b[3], b[3]);
  }
  if (orbis_renderer_apply_objects(renderer, kObjects, keys, transforms,
                                   sizeof transforms / sizeof(float), colours,
                                   sizeof colours / sizeof(float), meshes,
                                   flags, materials, shapes, NULL, 0, NULL,
                                   0) != ORBIS_OK) {
    fprintf(stderr, "the scene was refused\n");
    orbis_renderer_destroy(renderer);
    return 1;
  }

  const float eye[3] = {5.5f, 3.6f, 6.5f};
  const float look[3] = {0.0f, 0.0f, 0.0f};
  orbis_renderer_set_camera(renderer, eye, look, 42.0f, 0, 10.0f, 0.0);
  orbis_renderer_set_exposure(renderer, 16.0f, 1.0f / 125.0f, 100.0f);

  /* A few frames to settle, then one read back. */
  for (int frame = 0; frame < 4; frame++) {
    orbis_renderer_draw(renderer, frame / 60.0);
  }
  orbis_renderer_request_capture(renderer);
  size_t bytes = 0;
  uint32_t got_width = 0;
  uint32_t got_height = 0;
  for (int frame = 4; frame < 12 && bytes == 0; frame++) {
    orbis_renderer_draw(renderer, frame / 60.0);
    bytes = orbis_renderer_read_capture(renderer, NULL, 0, &got_width,
                                        &got_height);
  }
  if (bytes == 0) {
    fprintf(stderr, "no frame came back\n");
    orbis_renderer_destroy(renderer);
    return 1;
  }
  uint8_t *pixels = malloc(bytes);
  orbis_renderer_read_capture(renderer, pixels, bytes, &got_width,
                              &got_height);

  crc_start();
  const int wrote = write_png(out, pixels, got_width, got_height);
  free(pixels);

  orbis_stats stats;
  if (orbis_renderer_stats(renderer, &stats) == ORBIS_OK) {
    printf("%ux%u -> %s; cpu %.2f ms, gpu %.2f ms\n", got_width, got_height,
           wrote ? out : "(not written)", stats.cpu_milliseconds,
           stats.gpu_milliseconds);
  }
  const uint32_t notes = orbis_renderer_notes(renderer);
  for (uint32_t i = 0; i < notes; i++) {
    const char *about = NULL;
    const char *saying = NULL;
    if (orbis_renderer_note(renderer, i, &about, &saying) == ORBIS_OK) {
      printf("note: %s: %s\n", about, saying);
    }
  }
  orbis_renderer_destroy(renderer);
  return wrote ? 0 : 1;
}
