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

/* How many times the graph below is replaced. Any number above one would
 * catch the fault; several make it plain that what leaked scaled with the
 * changes rather than being a single stray object. */
enum { kGraphChanges = 8 };

/* Sets a graph, changes it, and destroys the renderer.
 *
 * An effect pass builds the triangle it draws — a material instance, an
 * entity and a scene of its own — the first time it runs, and keeps them,
 * because the pass runs on every frame. They belong to the pass, so a graph
 * that replaces the pass has to give them back. While it did not, each change
 * orphaned one instance of the effect's material, and nothing said so until
 * the renderer went down: Filament will not destroy a material with an
 * instance of it still alive, and ends the process rather than the frame.
 *
 * So this is a test that has to *reach the end*, not one that reads a value
 * back. It is also the reason to write it here rather than beside it: while
 * teardown aborted, no runtime test could set a graph at all — whatever it
 * was really checking, it died on the way out. */
static void graph_changes_and_goes_down(void) {
  orbis_surface_desc headless = {ORBIS_SURFACE_HEADLESS, NULL};
  orbis_renderer *renderer =
      orbis_renderer_create(ORBIS_BACKEND_DEFAULT, &headless, 64, 48);
  /* Said once already by the caller; a host with no device is not a failure. */
  if (renderer == NULL) return;

  /* One target that follows the view — which is what a width and height of
   * nought mean — keeping colour, so that an effect can sample it. */
  const float target[6] = {0.0f, 0.0f, 1.0f, 0.0f, 1.0f, 0.0f};
  const char *const names[1] = {"scene"};

  for (int change = 0; change < kGraphChanges; change++) {
    /* Two passes: the scene into that target, then a sharpen reading it onto
     * the frame. */
    float passes[2 * 13] = {0};
    passes[0] = 0;    /* a scene pass */
    passes[1] = 0;    /* into target nought */
    passes[2] = 127;  /* every layer */
    passes[3] = 1;    /* clearing */
    passes[4] = passes[5] = passes[6] = passes[7] = -1; /* reading nothing */
    passes[12] = -1;  /* no effect */

    passes[13 + 0] = 2;    /* an effect pass */
    passes[13 + 1] = -1;   /* onto the frame */
    passes[13 + 2] = 127;
    passes[13 + 3] = 1;
    passes[13 + 4] = 0;    /* reading target nought */
    passes[13 + 5] = passes[13 + 6] = passes[13 + 7] = -1;
    /* The effect's one dial, moved every time round. A graph identical to the
     * one already set is ignored — deliberately, since a host sends one every
     * frame — so a loop that did not move something would set one graph and
     * test nothing. */
    passes[13 + 8] = 0.2f + 0.05f * (float)change;
    passes[13 + 12] = 0;   /* sharpen */

    expect(orbis_renderer_set_render_graph(renderer, 2, passes, 2 * 13, 1,
                                           target, 6, names, 1) == ORBIS_OK,
           "a scene pass and an effect are taken as a graph");
    /* Drawn, and not only set: a pass that never runs never builds the
     * triangle whose ownership this is about. */
    expect(orbis_renderer_draw(renderer, change / 60.0) == ORBIS_OK,
           "a frame of that graph draws");
  }

  /* The whole of the test. Filament ends the process inside here if anything
   * the graph built outlived the graph. */
  orbis_renderer_destroy(renderer);
  printf("a graph changed %d times and the renderer went down cleanly\n",
         kGraphChanges);
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

  /* Its own renderer, because what it checks is the teardown. */
  graph_changes_and_goes_down();

  if (failures == 0) printf("the C ABI refuses what it should and draws\n");
  return failures == 0 ? 0 : 1;
}
