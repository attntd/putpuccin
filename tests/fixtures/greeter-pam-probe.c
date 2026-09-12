// Uses pam_start_confdir with an existing, fully private synthetic profile.
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int conversation(int count, const struct pam_message **messages,
                        struct pam_response **response, void *data) {
    (void)data;
    *response = calloc(count, sizeof(**response));
    if (!*response) return PAM_BUF_ERR;
    for (int i = 0; i < count; ++i) {
        if (messages[i]->msg_style != PAM_TEXT_INFO && messages[i]->msg_style != PAM_ERROR_MSG) {
            free(*response); *response = NULL; return PAM_CONV_ERR;
        }
        printf("MESSAGE %s\n", messages[i]->msg);
        const char *scenario = getenv("GREETER_PAM_TEST_CASE");
        if (scenario && !strncmp(scenario, "cancel_", 7)
                && !strcmp(messages[i]->msg, "GREETER_FINGERPRINT_DONE")) {
            free(*response); *response = NULL; return PAM_CONV_ERR;
        }
    }
    return PAM_SUCCESS;
}
int main(int argc, char **argv) {
    if (argc != 2 || strncmp(argv[1], "/tmp/qs-greeter-pam-test-", 25)) return 2;
    struct pam_conv conv = {conversation, NULL};
    pam_handle_t *handle = NULL;
    int result = pam_start_confdir("isolated-greeter", "synthetic-greeter-test-user", &conv, argv[1], &handle);
    if (result != PAM_SUCCESS) return 3;
    result = pam_authenticate(handle, 0);
    printf("AUTH_CODE %d\n", result);
    if (result == PAM_SUCCESS) {
        result = pam_acct_mgmt(handle, 0);
        printf("ACCOUNT_CODE %d\n", result);
    }
    printf("RESULT %s\n", result == PAM_SUCCESS ? "success" : "denied");
    pam_end(handle, result);
    return 0;
}
