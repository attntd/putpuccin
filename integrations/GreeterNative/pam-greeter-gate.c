// A conversation boundary, never an authentication method. The PAM profile
// ignores success and stops on cancellation before entering the password stack.
#include <security/pam_modules.h>
#include <security/pam_ext.h>
#include <stddef.h>

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                  int argc, const char **argv) {
    (void)argc; (void)argv;
    if (flags & PAM_SILENT) return PAM_CONV_ERR;
    return pam_info(pamh, "%s", "GREETER_FINGERPRINT_DONE");
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                             int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_IGNORE;
}
