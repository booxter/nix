#include <dlfcn.h>
#include <errno.h>
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *load_library(const char *path) {
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        exit(2);
    }
    return library;
}

static void *load_symbol(void *library, const char *name) {
    void *symbol = dlsym(library, name);
    if (symbol == NULL) {
        fprintf(stderr, "dlsym failed: %s\n", dlerror());
        exit(2);
    }
    return symbol;
}

static int refuse_prompt(int count, const struct pam_message **messages,
                        struct pam_response **responses, void *context) {
    return PAM_CONV_ERR;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: probe module auth_key_file allow|deny\n");
        return 2;
    }

    // Nix's SDK omits PAM. Use OpenPAM's public headers but explicitly load
    // Apple's implementation to catch incompatibilities with its handles.
    void *apple_pam = load_library("/usr/lib/libpam.2.dylib");
    int (*start)(const char *, const char *, const struct pam_conv *, pam_handle_t **) =
        load_symbol(apple_pam, "pam_start");
    int (*set_item)(pam_handle_t *, int, const void *) =
        load_symbol(apple_pam, "pam_set_item");
    int (*end)(pam_handle_t *, int) = load_symbol(apple_pam, "pam_end");
    const char *(*describe)(const pam_handle_t *, int) =
        load_symbol(apple_pam, "pam_strerror");

    struct pam_conv conversation = {refuse_prompt, NULL};
    pam_handle_t *handle = NULL;
    // "other" uses Apple's deny modules, independent of local sudo settings.
    // Only create a handle; call the module under test directly below.
    int result = start("other", "root", &conversation, &handle);
    if (result != PAM_SUCCESS) {
        fprintf(stderr, "pam_start failed: %d (%s)\n", result, strerror(errno));
        return 2;
    }

    result = set_item(handle, PAM_RUSER, "operator");
    if (result != PAM_SUCCESS) {
        fprintf(stderr, "pam_set_item failed: %d\n", result);
        end(handle, result);
        return 2;
    }

    void *module = load_library(argv[1]);
    int (*authenticate)(pam_handle_t *, int, int, const char **) =
        load_symbol(module, "pam_sm_authenticate");

    const char *options[] = {argv[2]};
    result = authenticate(handle, 0, 1, options);
    printf("Expected %s, module returned %d (%s)\n", argv[3], result,
           describe(handle, result));
    end(handle, result);

    // Error numbers differ between Linux-PAM and Apple PAM. Authentication
    // must still fail for every rejected key or unavailable credential source.
    int expect_success = strcmp(argv[3], "allow") == 0;
    return (result == PAM_SUCCESS) == expect_success ? 0 : 1;
}
