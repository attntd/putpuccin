// Synthetic PAM outcomes only. Never inspects a real account, password or device.
#include <security/pam_modules.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned fingerprints;
PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags;
    const char *scenario = getenv("GREETER_PAM_TEST_CASE");
    if (!scenario || argc < 1) return PAM_ABORT;
    printf("STEP %s\n", argv[0]);
    if (!strcmp(argv[0], "deny")) return PAM_AUTH_ERR;
    if (!strncmp(argv[0], "guard", 5))
        return !strcmp(argv[0], scenario) ? PAM_PERM_DENIED : PAM_SUCCESS;
    if (!strcmp(argv[0], "fingerprint")) {
        ++fingerprints;
        if (!strcmp(scenario, "fp_ok") || !strcmp(scenario, "account_denied")) return PAM_SUCCESS;
        if (!strcmp(scenario, "unavailable_then_ok") && fingerprints == 2) return PAM_SUCCESS;
        if (strstr(scenario, "mismatch")) return PAM_MAXTRIES;
        return PAM_AUTHINFO_UNAVAIL;
    }
    if (!strcmp(argv[0], "password")) return strstr(scenario, "password_ok") ? PAM_SUCCESS : PAM_AUTH_ERR;
    return PAM_ABORT;
}
PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_SUCCESS;
}
PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    puts("STEP account");
    const char *scenario = getenv("GREETER_PAM_TEST_CASE");
    return scenario && !strcmp(scenario, "account_denied") ? PAM_PERM_DENIED : PAM_SUCCESS;
}
