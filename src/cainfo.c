/* CA trust store discovery for the HTTP shim.
 *
 * The static libcurl in bin/lumen is configured without --with-ca-bundle, so it
 * falls back to whatever path was compiled in by the build container (Ubuntu
 * 22.04: /etc/ssl/certs/...). On Fedora, RHEL or openSUSE that path does not
 * exist and every TLS handshake fails. The behaviour is fail-closed rather than
 * insecure, but the natural "fix" a user reaches for is exporting SSL_CERT_FILE,
 * which hands the trust store to the environment — so the shim probes the
 * well-known locations itself instead.
 *
 * Note the deliberate difference from slsteam-moon's src/cainfo.hpp: that one
 * also honours CURL_CA_BUNDLE / SSL_CERT_FILE / SSL_CERT_DIR. Here the
 * environment is NOT consulted. Lumen is launched from Steam's own environment,
 * and letting an inherited variable redirect the trust store used for OAuth
 * tokens and update metadata is exactly what should not be possible.
 */
#include "cainfo.h"

#include <stddef.h>
#include <sys/stat.h>

/* Well-known bundle files, most common first. */
static const char *const kFiles[] = {
    "/etc/ssl/certs/ca-certificates.crt",               /* Debian/Ubuntu/Arch/SteamOS */
    "/etc/pki/tls/certs/ca-bundle.crt",                 /* Fedora/RHEL/CentOS */
    "/etc/ssl/ca-bundle.pem",                           /* openSUSE */
    "/etc/pki/tls/cacert.pem",                          /* older RHEL */
    "/etc/ssl/cert.pem",                                /* Alpine/BSD */
    "/etc/ca-certificates/extracted/tls-ca-bundle.pem", /* Arch/SteamOS */
    "/usr/local/share/certs/ca-root-nss.crt",           /* FreeBSD */
    NULL,
};

/* Hashed-certificate directories (CURLOPT_CAPATH). */
static const char *const kDirs[] = {
    "/etc/ssl/certs",
    "/etc/pki/tls/certs",
    "/etc/ca-certificates/extracted",
    NULL,
};

static int is_file(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISREG(st.st_mode) != 0;
}

static int is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) != 0;
}

const char *lumen_ca_file(void) {
    static const char *cached = NULL;
    static int resolved = 0;
    if (!resolved) {
        resolved = 1;
        for (int i = 0; kFiles[i]; i++) {
            if (is_file(kFiles[i])) {
                cached = kFiles[i];
                break;
            }
        }
    }
    return cached;
}

const char *lumen_ca_dir(void) {
    static const char *cached = NULL;
    static int resolved = 0;
    if (!resolved) {
        resolved = 1;
        for (int i = 0; kDirs[i]; i++) {
            if (is_dir(kDirs[i])) {
                cached = kDirs[i];
                break;
            }
        }
    }
    return cached;
}

const char *const *lumen_ca_file_candidates(void) { return kFiles; }
const char *const *lumen_ca_dir_candidates(void) { return kDirs; }
