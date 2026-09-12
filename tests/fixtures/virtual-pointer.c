// Minimal wlr-virtual-pointer-v1 client for clicks on a private test compositor.
// Wire definitions: wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

static const struct wl_interface pointer_interface;
static const struct wl_interface *create_types[] = {&wl_seat_interface, &pointer_interface};
static const struct wl_message manager_methods[] = {
    {"create_virtual_pointer", "?on", create_types}, {"destroy", "", NULL}
};
static const struct wl_interface manager_interface = {
    "zwlr_virtual_pointer_manager_v1", 1, 2, manager_methods, 0, NULL
};
static const struct wl_message pointer_methods[] = {
    {"motion", "uff", NULL}, {"motion_absolute", "uuuuu", NULL},
    {"button", "uuu", NULL}, {"axis", "uuf", NULL}, {"frame", "", NULL},
    {"axis_source", "u", NULL}, {"axis_stop", "uu", NULL},
    {"axis_discrete", "uufi", NULL}, {"destroy", "", NULL}
};
static const struct wl_interface pointer_interface = {
    "zwlr_virtual_pointer_v1", 1, 9, pointer_methods, 0, NULL
};
static struct wl_proxy *manager;
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, manager_interface.name))
        manager = wl_registry_bind(registry, name, &manager_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 3;
    struct wl_registry *registry = wl_display_get_registry(display);
    const struct wl_registry_listener listener = {global, removed};
    wl_registry_add_listener(registry, &listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !manager) return 4;
    struct wl_proxy *pointer = wl_proxy_marshal_flags(manager, 0, &pointer_interface,
        1, 0, NULL, NULL);
    wl_proxy_marshal_flags(pointer, 1, NULL, 1, 0,
        0u, (uint32_t)atoi(argv[1]), (uint32_t)atoi(argv[2]), 1280u, 720u);
    wl_proxy_marshal_flags(pointer, 4, NULL, 1, 0);
    if (wl_display_roundtrip(display) < 0) return 5;
    if (!strcmp(argv[3], "click")) {
        wl_proxy_marshal_flags(pointer, 2, NULL, 1, 0, 1u, 272u, 1u);
        wl_proxy_marshal_flags(pointer, 4, NULL, 1, 0);
        wl_proxy_marshal_flags(pointer, 2, NULL, 1, 0, 2u, 272u, 0u);
        wl_proxy_marshal_flags(pointer, 4, NULL, 1, 0);
    }
    int result = wl_display_roundtrip(display) < 0;
    wl_display_disconnect(display);
    return result;
}
