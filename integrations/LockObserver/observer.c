/* One-shot client of hyprland-lock-notify-v1. It never creates a surface or lock. */
#include <stdbool.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <wayland-client.h>
#include "hyprland-lock-notify-v1-client-protocol.h"

struct observer {
    struct hyprland_lock_notifier_v1 *manager;
    struct hyprland_lock_notification_v1 *notification;
    bool ready;
    bool locked;
};

static void locked(void *data, struct hyprland_lock_notification_v1 *notification) {
    (void)notification;
    struct observer *state = data;
    state->locked = true;
    if (state->ready)
        puts("locked");
}

static void unlocked(void *data, struct hyprland_lock_notification_v1 *notification) {
    (void)notification;
    struct observer *state = data;
    state->locked = false;
    if (state->ready)
        puts("unlocked");
}

static const struct hyprland_lock_notification_v1_listener notification_listener = {
    .locked = locked,
    .unlocked = unlocked,
};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)version;
    struct observer *state = data;
    if (strcmp(interface, "hyprland_lock_notifier_v1") != 0 || state->manager)
        return;
    state->manager = wl_registry_bind(registry, name, &hyprland_lock_notifier_v1_interface, 1);
    state->notification = hyprland_lock_notifier_v1_get_lock_notification(state->manager);
    hyprland_lock_notification_v1_add_listener(state->notification, &notification_listener, state);
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global,
    .global_remove = global_remove,
};

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("quickshell-lock-observer 1 (hyprland-lock-notify-v1)");
        return 0;
    }
    if (argc != 1)
        return 2;
    // The wrapper may be stopped or crash while waiting. This read-only helper
    // must not survive it as an idle process with an open Wayland connection.
    const pid_t parent = getppid();
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != parent)
        return 1;
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fputs("Cannot connect to Wayland.\n", stderr);
        return 1;
    }
    struct observer state = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &state);
    int result = 1;
    // The second barrier includes get_lock_notification's initial locked event.
    if (wl_display_roundtrip(display) < 0 || !state.manager
        || wl_display_roundtrip(display) < 0) {
        fputs("hyprland-lock-notify-v1 is unavailable.\n", stderr);
        goto done;
    }
    state.ready = true;
    puts(state.locked ? "ready locked" : "ready unlocked");
    while (wl_display_dispatch(display) >= 0) {}
done:
    if (state.notification)
        hyprland_lock_notification_v1_destroy(state.notification);
    if (state.manager)
        hyprland_lock_notifier_v1_destroy(state.manager);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
}
