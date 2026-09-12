/* Test-only LD_PRELOAD adapter. Never build or install this into the shell. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char profile[] =
    "auth optional pam_faildelay.so delay=1000000\n"
    "auth required pam_deny.so\n"
    "account required pam_deny.so\n"
    "password required pam_deny.so\n"
    "session required pam_deny.so\n";

static void refuse(void) {
    static const char message[] = "Refusing test PAM: private isolation is missing or invalid.\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(125);
}

static int private_directory(const char *path) {
    if (!path || path[0] != '/')
        refuse();
    char resolved[PATH_MAX];
    if (!realpath(path, resolved) || strcmp(resolved, path))
        refuse();
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || info.st_uid != getuid() || (info.st_mode & 077))
        refuse();
    return fd;
}

static int validate(void) {
    if (getuid() != geteuid() || getgid() != getegid())
        refuse();
    const char *directory = getenv("QS_TEST_PAM_DIRECTORY");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    const char *display = getenv("WAYLAND_DISPLAY");
    if (!directory || !runtime || !display || strncmp(directory, "/tmp/qs-lfb-", 12))
        refuse();
    size_t directory_length = strlen(directory);
    size_t runtime_length = strlen(runtime);
    if (directory_length < 5 || strcmp(directory + directory_length - 4, "/pam")
        || runtime_length != directory_length - 2
        || strncmp(runtime, directory, directory_length - 4)
        || strcmp(runtime + directory_length - 4, "/r"))
        refuse();
    if (strncmp(display, runtime, runtime_length) || display[runtime_length] != '/')
        refuse();
    int runtime_fd = private_directory(runtime);
    close(runtime_fd);
    int directory_fd = private_directory(directory);
    int profile_fd = openat(directory_fd, "system-auth", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    char content[sizeof(profile)];
    if (profile_fd < 0 || fstat(profile_fd, &info) || !S_ISREG(info.st_mode)
        || info.st_uid != getuid() || info.st_nlink != 1 || (info.st_mode & 077)
        || info.st_size != sizeof(profile) - 1
        || read(profile_fd, content, sizeof(content)) != sizeof(profile) - 1
        || memcmp(content, profile, sizeof(profile) - 1))
        refuse();
    close(profile_fd);
    return directory_fd;
}

__attribute__((constructor)) static void initialize(void) {
    close(validate());
}

static int isolated_start(const char *service, const char *user,
                          const struct pam_conv *conversation, pam_handle_t **handle) {
    (void)user;
    if (!service || strcmp(service, "system-auth") || !conversation || !handle)
        refuse();
    int directory_fd = validate();
    typedef int (*start_fn)(const char *, const char *, const struct pam_conv *, const char *, pam_handle_t **);
    void *pam_library = dlopen("libpam.so.0", RTLD_NOW | RTLD_LOCAL);
    start_fn start = pam_library ? (start_fn)dlsym(pam_library, "pam_start_confdir") : NULL;
    if (!start)
        refuse();
    // This service contains no host include, account lookup or faillock module.
    // A synthetic user additionally keeps test handles separate from the user.
    int result = start("system-auth", "quickshell-isolated-test", conversation,
                       getenv("QS_TEST_PAM_DIRECTORY"), handle);
    dlclose(pam_library);
    int marker = openat(directory_fd, "hook-used", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (marker < 0 || fstat(marker, &info) || !S_ISREG(info.st_mode)
        || info.st_uid != getuid() || info.st_nlink != 1 || (info.st_mode & 077))
        refuse();
    if (dprintf(marker, "pam_start_confdir %ld %d\n", (long)getpid(), result) < 0)
        refuse();
    close(marker);
    close(directory_fd);
    return result;
}

int pam_start(const char *service, const char *user,
              const struct pam_conv *conversation, pam_handle_t **handle) {
    return isolated_start(service, user, conversation, handle);
}

int pam_start_confdir(const char *service, const char *user,
                      const struct pam_conv *conversation, const char *directory,
                      pam_handle_t **handle) {
    (void)directory;
    return isolated_start(service, user, conversation, handle);
}
