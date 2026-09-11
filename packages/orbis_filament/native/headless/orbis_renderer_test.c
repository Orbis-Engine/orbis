/* The C ABI's own test.
 *
 * C99, and it includes one header: orbis_renderer.h. That is the first half of
 * what it checks — that a host written in plain C can be built against the
 * renderer at all, with nothing of C++, Objective-C or Filament leaking
 * through the header. The second half runs once it is linked: that the ABI
 * refuses what it should, and that a renderer made through it draws. */

#include "orbis_renderer.h"

#include <stdio.h>

static int failures = 0;

static void expect(int holds, const char *what) {
  if (!holds) {
    fprintf(stderr, "FAIL: %s\n", what);
    failures++;
  }
}

int main(void) {
  /* Nothing is a handle, and nothing crashes on being given nothing. */
  expect(orbis_renderer_draw(NULL, 0.0) == ORBIS_ERROR_NULL,
         "a null renderer is refused, not dereferenced");
  orbis_renderer_destroy(NULL);
  expect(orbis_renderer_notes(NULL) == 0, "a null renderer has no notes");

  /* The rows are the renderer's to say, so a host need not copy them. */
  expect(orbis_renderer_stride(ORBIS_STRIDE_LIGHT) == 22,
         "a light is twenty-two floats");
  expect(orbis_renderer_stride(ORBIS_STRIDE_MATERIAL) == 37,
         "a material is thirty-seven floats");
  expect(orbis_renderer_stride(ORBIS_STRIDE_PASS) == 13,
         "a graph pass is thirteen floats");

  orbis_surface_desc headless = {ORBIS_SURFACE_HEADLESS, NULL};
  orbis_renderer *renderer =
      orbis_renderer_create(ORBIS_BACKEND_DEFAULT, &headless, 64, 48);
  if (renderer == NULL) {
    printf("no renderer could start here; the ABI compiled and linked\n");
    return failures == 0 ? 0 : 1;
  }

  /* A short array is refused, and nothing is applied. */
  {
    const int64_t key = 1;
    const int32_t kind = 0;
    const int32_t flags = 1;
    const float sun[22] = {1.0f, 0.95f, 0.9f, 100000.0f, 0, 0, 0,
                           -0.5f, -1.0f, -0.3f, 0, 0, 0, 0.53f, 0.1f,
                           10.0f, 80.0f, 0, 0, 0, 0, 0};
    expect(orbis_renderer_apply_lights(renderer, 1, &key, &kind, &flags, sun,
                                       21) == ORBIS_ERROR_LENGTH,
           "a light one float short is refused");
    expect(orbis_renderer_apply_lights(renderer, 1, &key, &kind, &flags, sun,
                                       22) == ORBIS_OK,
           "a whole light is taken");
    expect(orbis_renderer_apply_lights(renderer, 1, NULL, &kind, &flags, sun,
                                       22) == ORBIS_ERROR_NULL,
           "a missing array is refused");
  }

  /* A graph that reads a target it does not have is refused by index. */
  {
    float pass[13] = {0};
    pass[1] = -1;           /* into the frame */
    pass[2] = 127;          /* every layer */
    pass[4] = 3;            /* reads target three, of none */
    pass[5] = pass[6] = pass[7] = -1;
    pass[12] = -1;
    expect(orbis_renderer_set_render_graph(renderer, 1, pass, 13, 0, NULL, 0,
                                           NULL, 0) == ORBIS_ERROR_RANGE,
           "a pass reading a target that is not there is refused");
  }

  /* It draws, and the frame comes back. */
  orbis_renderer_request_capture(renderer);
  for (int frame = 0; frame < 6; frame++) {
    expect(orbis_renderer_draw(renderer, frame / 60.0) == ORBIS_OK,
           "a frame draws");
  }
  {
    uint32_t width = 0;
    uint32_t height = 0;
    const size_t bytes =
        orbis_renderer_read_capture(renderer, NULL, 0, &width, &height);
    expect(bytes == 64u * 48u * 4u && width == 64 && height == 48,
           "a 64 by 48 frame comes back");
  }
  {
    orbis_stats stats;
    expect(orbis_renderer_stats(renderer, &stats) == ORBIS_OK,
           "stats are there to read");
  }

  orbis_renderer_destroy(renderer);
  if (failures == 0) printf("the C ABI refuses what it should and draws\n");
  return failures == 0 ? 0 : 1;
}
