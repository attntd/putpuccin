/* Load the test adapter explicitly: this probe never calls unwrapped pam_start. */
#include <dlfcn.h>
#include <security/pam_appl.h>
#include <stdio.h>

static int deny_conversation(int count, const struct pam_message **messages,
                             struct pam_response **responses, void *data) {
    (void)count;
    (void)messages;
    (void)responses;
    (void)data;
    return PAM_CONV_ERR;
}

int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "Cannot load isolation adapter: %s\n", dlerror());
        return 3;
    }
    typedef int (*start_fn)(const char *, const char *, const struct pam_conv *, pam_handle_t **);
    start_fn start = (start_fn)dlsym(library, "pam_start");
    if (!start)
        return 4;
    pam_handle_t *handle = NULL;
    struct pam_conv conversation = {.conv = deny_conversation, .appdata_ptr = NULL};
    int result = start("system-auth", "quickshell-isolated-test", &conversation, &handle);
    if (result != PAM_SUCCESS || !handle) {
        fprintf(stderr, "Private pam_start returned %d\n", result);
        return 5;
    }
    result = pam_authenticate(handle, 0);
    pam_end(handle, result);
    dlclose(library);
    if (result != PAM_AUTH_ERR) {
        fprintf(stderr, "Private pam_authenticate returned %d\n", result);
        return 6;
    }
    puts("ISOLATED_PAM_DENIED");
    return 0;
}
