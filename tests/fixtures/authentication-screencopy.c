/* Test-only recorder: private AUTH-A output, no production capture.
 * Buffer frames in memory and encode after the animation to avoid PNG stalls.
 */
#define _GNU_SOURCE
#include <wayland-client.h>
#include <png.h>
#include <sys/mman.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "screencopy-client.h"

struct output { struct wl_output *proxy; char name[64]; } outputs[8];
struct saved { unsigned char *pixels; uint32_t width, height, stride, flags; long long time; } saved[600];
static struct wl_display *display;
static struct wl_shm *shm;
static struct zwlr_screencopy_manager_v1 *manager;
static struct wl_output *target;
static struct wl_buffer *buffer;
static void *mapping;
static uint32_t width, height, stride, flags;
static int count, output_count, running = 1, failed;
static size_t bytes;
static long long deadline;

static long long now_ms(clockid_t clock) {
    struct timespec t;
    clock_gettime(clock, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void request_frame(void);
static void release_buffer(void) {
    if (buffer) wl_buffer_destroy(buffer);
    if (mapping && mapping != MAP_FAILED) munmap(mapping, bytes);
    buffer = NULL;
    mapping = NULL;
}
static void on_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame,
                      uint32_t format, uint32_t w, uint32_t h, uint32_t s) {
    if (format != WL_SHM_FORMAT_ARGB8888 && format != WL_SHM_FORMAT_XRGB8888) {
        failed = 1; running = 0; return;
    }
    width = w; height = h; stride = s; bytes = (size_t)s * h;
    int fd = memfd_create("auth-test-frame", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, bytes)) { failed = 1; running = 0; return; }
    mapping = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) { close(fd); failed = 1; running = 0; return; }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, bytes);
    buffer = wl_shm_pool_create_buffer(pool, 0, w, h, s, format);
    wl_shm_pool_destroy(pool);
    close(fd);
}
static void on_flags(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t value) { flags = value; }
static void on_ready(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t hi, uint32_t lo, uint32_t ns) {
    struct saved *s = &saved[count];
    s->pixels = malloc(bytes);
    if (!s->pixels) { failed = 1; running = 0; return; }
    memcpy(s->pixels, mapping, bytes);
    s->width = width; s->height = height; s->stride = stride; s->flags = flags;
    s->time = now_ms(CLOCK_REALTIME);
    ++count;
    zwlr_screencopy_frame_v1_destroy(frame);
    release_buffer();
    if (count >= 600 || now_ms(CLOCK_MONOTONIC) >= deadline) running = 0;
    else request_frame();
}
static void on_failed(void *data, struct zwlr_screencopy_frame_v1 *frame) {
    zwlr_screencopy_frame_v1_destroy(frame);
    failed = 1; running = 0;
}
static void on_damage(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {}
static void on_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *frame, uint32_t format, uint32_t w, uint32_t h) {}
static void on_buffer_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {
    if (buffer) zwlr_screencopy_frame_v1_copy(frame, buffer);
    else { failed = 1; running = 0; }
}
static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    .buffer = on_buffer, .flags = on_flags, .ready = on_ready, .failed = on_failed,
    .damage = on_damage, .linux_dmabuf = on_dmabuf, .buffer_done = on_buffer_done
};
static void request_frame(void) {
    flags = 0;
    struct zwlr_screencopy_frame_v1 *frame = zwlr_screencopy_manager_v1_capture_output_region(manager, 0, target, 360, 180, 560, 360);
    zwlr_screencopy_frame_v1_add_listener(frame, &frame_listener, NULL);
}
static void output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t w, int32_t h,
                            int32_t sub, const char *make, const char *model, int32_t transform) {}
static void output_mode(void *d, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {}
static void output_done(void *d, struct wl_output *o) {}
static void output_scale(void *d, struct wl_output *o, int32_t scale) {}
static void output_name(void *d, struct wl_output *o, const char *name) { snprintf(((struct output *)d)->name, 64, "%s", name); }
static void output_description(void *d, struct wl_output *o, const char *description) {}
static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done,
    .scale = output_scale, .name = output_name, .description = output_description
};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, "zwlr_screencopy_manager_v1") && version >= 3)
        manager = wl_registry_bind(registry, name, &zwlr_screencopy_manager_v1_interface, 3);
    else if (!strcmp(interface, "wl_output") && version >= 4 && output_count < 8) {
        struct output *o = &outputs[output_count++];
        o->proxy = wl_registry_bind(registry, name, &wl_output_interface, 4);
        wl_output_add_listener(o->proxy, &output_listener, o);
    }
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {.global = global, .global_remove = global_remove};

static int save_png(const char *directory, int index) {
    struct saved *s = &saved[index];
    char path[1024];
    snprintf(path, sizeof(path), "%s/frame-%d.png", directory, index);
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    png_infop info = png_create_info_struct(png);
    if (setjmp(png_jmpbuf(png))) return 0;
    png_init_io(png, f);
    png_set_compression_level(png, 1);
    png_set_IHDR(png, info, s->width, s->height, 8, PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);
    unsigned char *row = malloc(s->width * 3);
    for (uint32_t y = 0; y < s->height; ++y) {
        uint32_t sy = (s->flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) ? s->height - 1 - y : y;
        unsigned char *source = s->pixels + sy * s->stride;
        for (uint32_t x = 0; x < s->width; ++x) {
            row[x * 3] = source[x * 4 + 2]; row[x * 3 + 1] = source[x * 4 + 1]; row[x * 3 + 2] = source[x * 4];
        }
        png_write_row(png, row);
    }
    free(row);
    png_write_end(png, info);
    png_destroy_write_struct(&png, &info);
    fclose(f);
    return 1;
}
int main(int argc, char **argv) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (argc != 3 || !runtime || strncmp(runtime, "/tmp/qauth-", 11)) return 2;
    display = wl_display_connect(NULL);
    if (!display) return 3;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display); wl_display_roundtrip(display);
    for (int i = 0; i < output_count; ++i) if (!strcmp(outputs[i].name, "AUTH-A")) target = outputs[i].proxy;
    if (!target || !manager || !shm) return 4;
    deadline = now_ms(CLOCK_MONOTONIC) + atoi(argv[2]);
    puts("AUTH_RECORD_READY"); fflush(stdout);
    request_frame();
    while (running && now_ms(CLOCK_MONOTONIC) < deadline + 1000) {
        wl_display_dispatch_pending(display);
        wl_display_flush(display);
        struct pollfd p = {.fd = wl_display_get_fd(display), .events = POLLIN};
        if (poll(&p, 1, 100) > 0 && wl_display_dispatch(display) < 0) { failed = 1; break; }
    }
    release_buffer();
    for (int i = 0; i < count; ++i) {
        int ok = save_png(argv[1], i);
        printf("AUTH_RECORDED {\"index\":%d,\"time\":%lld,\"saved\":%s}\n", i, saved[i].time, ok ? "true" : "false");
        free(saved[i].pixels);
        if (!ok) failed = 1;
    }
    wl_display_disconnect(display);
    return failed ? 5 : 0;
}
