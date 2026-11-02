// Web Push's cryptography and its address guard, for push.goose, over OpenSSL's libcrypto:
// RFC 8291 message encryption (aes128gcm, RFC 8188), RFC 8292 VAPID signatures (ES256), and the
// endpoint lookup with RestrictedHTTP::PrivateNetworkGuard's policy (the surfguard gem).
#include "goose.h"
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/core_names.h>
#include <openssl/param_build.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/err.h>
#include <openssl/bn.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#endif

typedef struct { const uint8_t *data; int64_t len; } push_bytes;

// What campfire_push_encrypt returns besides 0.
#define PUSH_INVALID_KEY 1   // the subscription's p256dh isn't a P-256 point (OpenSSL::PKey::EC::Point::Error)
#define PUSH_TOO_BIG 2       // the record is over 4096 bytes ("encrypted payload is too big")
#define PUSH_FAILED 3        // anything else OpenSSL refused

// A P-256 key from its uncompressed public point and, for a key pair, its 32-byte private scalar;
// NULL when they don't make one. Importing the point checks that it is on the curve.
static EVP_PKEY *p256_key(const uint8_t *pub, size_t pub_len, const uint8_t *priv) {
    EVP_PKEY *key = NULL;
    BIGNUM *d = NULL;
    OSSL_PARAM *params = NULL;
    EVP_PKEY_CTX *ctx = NULL;
    OSSL_PARAM_BLD *build = OSSL_PARAM_BLD_new();
    if (!build) return NULL;
    if (!OSSL_PARAM_BLD_push_utf8_string(build, OSSL_PKEY_PARAM_GROUP_NAME, "prime256v1", 0)) goto done;
    if (!OSSL_PARAM_BLD_push_octet_string(build, OSSL_PKEY_PARAM_PUB_KEY, pub, pub_len)) goto done;
    if (priv) {
        d = BN_bin2bn(priv, 32, NULL);
        if (!d || !OSSL_PARAM_BLD_push_BN(build, OSSL_PKEY_PARAM_PRIV_KEY, d)) goto done;
    }
    params = OSSL_PARAM_BLD_to_param(build);
    ctx = EVP_PKEY_CTX_new_from_name(NULL, "EC", NULL);
    if (!params || !ctx || EVP_PKEY_fromdata_init(ctx) != 1) goto done;
    if (EVP_PKEY_fromdata(ctx, &key, priv ? EVP_PKEY_KEYPAIR : EVP_PKEY_PUBLIC_KEY, params) != 1) key = NULL;
done:
    EVP_PKEY_CTX_free(ctx);
    OSSL_PARAM_free(params);
    BN_clear_free(d);
    OSSL_PARAM_BLD_free(build);
    return key;
}

// A key's uncompressed public point, 65 bytes, into out; whether it had one.
static int public_point(EVP_PKEY *key, uint8_t out[65]) {
    size_t len = 0;
    return EVP_PKEY_get_octet_string_param(key, OSSL_PKEY_PARAM_ENCODED_PUBLIC_KEY, out, 65, &len) == 1 && len == 65 && out[0] == 4;
}

// HMAC-SHA-256 of the concatenation of a and b, keyed by key: HKDF's extract, and its expand for
// one block when b ends with 0x01.
static int hmac2(const uint8_t *key, size_t key_len, const uint8_t *a, size_t a_len, const uint8_t *b, size_t b_len, uint8_t out[32]) {
    uint8_t buffer[256];
    if (a_len + b_len > sizeof buffer) return 0;
    memcpy(buffer, a, a_len);
    if (b_len) memcpy(buffer + a_len, b, b_len);
    unsigned int len = 0;
    return HMAC(EVP_sha256(), key, (int)key_len, buffer, a_len + b_len, out, &len) != NULL && len == 32;
}

// HKDF-SHA-256 (RFC 5869) for at most 32 bytes: out = T(1)[..length].
static int hkdf(const uint8_t *salt, size_t salt_len, const uint8_t *ikm, size_t ikm_len,
                const uint8_t *info, size_t info_len, uint8_t *out, size_t length) {
    uint8_t prk[32], block[32], one = 1;
    if (!hmac2(salt, salt_len, ikm, ikm_len, NULL, 0, prk)) return 0;
    if (!hmac2(prk, 32, info, info_len, &one, 1, block)) return 0;
    memcpy(out, block, length);
    OPENSSL_cleanse(prk, sizeof prk);
    OPENSSL_cleanse(block, sizeof block);
    return 1;
}

// WebPush::Encryption.encrypt: the aes128gcm body for plaintext to the subscription's p256dh (65
// bytes) and auth secret: salt(16) || rs(4) || idlen(1) || the sender's public key(65) || one
// record, plaintext || 0x02, sealed. rs is the record's length, as the gem writes it. salt and
// sender (a 32-byte private key) are random when empty; tests pass RFC 8291's. 0, or a PUSH_ code.
int32_t campfire_push_encrypt(push_bytes p256dh, push_bytes auth, push_bytes plaintext,
                              push_bytes salt_in, push_bytes sender_in, gs_rref out) {
    int32_t result = PUSH_FAILED;
    EVP_PKEY *peer = NULL, *sender = NULL;
    EVP_PKEY_CTX *derive = NULL;
    EVP_CIPHER_CTX *cipher = NULL;
    uint8_t salt[16], sender_public[65], secret[32], ikm[32], cek[16], nonce[12], info[144];
    uint8_t *sealed = NULL;
    size_t secret_len = sizeof secret;
    ERR_clear_error();
    if (p256dh.len != 65 || p256dh.data[0] != 4) { result = PUSH_INVALID_KEY; goto done; }
    if (auth.len < 0 || auth.len > 64 || plaintext.len < 0) goto done;
    int64_t record = plaintext.len + 1 + 16;
    if (record > 4096) { result = PUSH_TOO_BIG; goto done; }
    peer = p256_key(p256dh.data, 65, NULL);
    if (!peer) { result = PUSH_INVALID_KEY; goto done; }
    if (salt_in.len == 16) memcpy(salt, salt_in.data, 16);
    else if (RAND_bytes(salt, sizeof salt) != 1) goto done;
    if (sender_in.len == 32) {
        // A fixed sender key, for tests: its public point from the scalar.
        EC_GROUP *group = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
        EC_POINT *point = group ? EC_POINT_new(group) : NULL;
        BIGNUM *d = BN_bin2bn(sender_in.data, 32, NULL);
        int ok = group && point && d && EC_POINT_mul(group, point, d, NULL, NULL, NULL) == 1 &&
                 EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, sender_public, 65, NULL) == 65;
        BN_clear_free(d);
        EC_POINT_free(point);
        EC_GROUP_free(group);
        if (!ok || !(sender = p256_key(sender_public, 65, sender_in.data))) goto done;
    } else {
        sender = EVP_PKEY_Q_keygen(NULL, NULL, "EC", "P-256");
        if (!sender || !public_point(sender, sender_public)) goto done;
    }
    derive = EVP_PKEY_CTX_new_from_pkey(NULL, sender, NULL);
    if (!derive || EVP_PKEY_derive_init(derive) != 1) goto done;
    if (EVP_PKEY_derive_set_peer(derive, peer) != 1) { result = PUSH_INVALID_KEY; goto done; }
    if (EVP_PKEY_derive(derive, secret, &secret_len) != 1 || secret_len != 32) goto done;
    // key_info = "WebPush: info" || 0x00 || ua_public || as_public; IKM = HKDF(auth, ecdh, key_info, 32).
    static const char key_label[] = "WebPush: info";
    size_t at = sizeof key_label;  // with its NUL
    memcpy(info, key_label, at);
    memcpy(info + at, p256dh.data, 65); at += 65;
    memcpy(info + at, sender_public, 65); at += 65;
    if (!hkdf(auth.data, (size_t)auth.len, secret, 32, info, at, ikm, 32)) goto done;
    static const char cek_label[] = "Content-Encoding: aes128gcm";
    static const char nonce_label[] = "Content-Encoding: nonce";
    if (!hkdf(salt, 16, ikm, 32, (const uint8_t *)cek_label, sizeof cek_label, cek, 16)) goto done;
    if (!hkdf(salt, 16, ikm, 32, (const uint8_t *)nonce_label, sizeof nonce_label, nonce, 12)) goto done;
    sealed = malloc((size_t)record);
    cipher = EVP_CIPHER_CTX_new();
    int n = 0, total = 0;
    static const uint8_t delimiter = 2;
    if (!sealed || !cipher) goto done;
    if (EVP_EncryptInit_ex(cipher, EVP_aes_128_gcm(), NULL, NULL, NULL) != 1) goto done;
    if (EVP_CIPHER_CTX_ctrl(cipher, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) != 1) goto done;
    if (EVP_EncryptInit_ex(cipher, NULL, NULL, cek, nonce) != 1) goto done;
    if (plaintext.len > 0) {
        if (EVP_EncryptUpdate(cipher, sealed, &n, plaintext.data, (int)plaintext.len) != 1) goto done;
        total += n;
    }
    if (EVP_EncryptUpdate(cipher, sealed + total, &n, &delimiter, 1) != 1) goto done;
    total += n;
    if (EVP_EncryptFinal_ex(cipher, sealed + total, &n) != 1) goto done;
    total += n;
    if (EVP_CIPHER_CTX_ctrl(cipher, EVP_CTRL_GCM_GET_TAG, 16, sealed + total) != 1) goto done;
    total += 16;
    if (total != record) goto done;
    uint8_t header[16 + 4 + 1 + 65];
    memcpy(header, salt, 16);
    header[16] = (uint8_t)(record >> 24); header[17] = (uint8_t)(record >> 16);
    header[18] = (uint8_t)(record >> 8); header[19] = (uint8_t)record;
    header[20] = 65;
    memcpy(header + 21, sender_public, 65);
    gs_bld_append(out, header, sizeof header);
    gs_bld_append(out, sealed, record);
    result = 0;
done:
    OPENSSL_cleanse(secret, sizeof secret);
    OPENSSL_cleanse(ikm, sizeof ikm);
    OPENSSL_cleanse(cek, sizeof cek);
    EVP_CIPHER_CTX_free(cipher);
    free(sealed);
    EVP_PKEY_CTX_free(derive);
    EVP_PKEY_free(sender);
    EVP_PKEY_free(peer);
    ERR_clear_error();
    return result;
}

// The VAPID key pair from the decoded VAPID_PUBLIC_KEY (65 bytes) and VAPID_PRIVATE_KEY (at most
// 32 bytes, as Ruby's BN#to_s(2) writes it, without leading zeros): 0 when they make a key and
// belong together, 1 when they make none, 2 when the public key isn't the private key's.
static int vapid_key(push_bytes pub, push_bytes priv, EVP_PKEY **key) {
    uint8_t scalar[32] = {0}, derived[65];
    *key = NULL;
    if (pub.len != 65 || pub.data[0] != 4 || priv.len < 1 || priv.len > 32) return 1;
    memcpy(scalar + 32 - priv.len, priv.data, (size_t)priv.len);
    int result = 1;
    EC_GROUP *group = EC_GROUP_new_by_curve_name(NID_X9_62_prime256v1);
    EC_POINT *point = group ? EC_POINT_new(group) : NULL;
    BIGNUM *d = BN_bin2bn(scalar, 32, NULL);
    if (group && point && d && !BN_is_zero(d) && EC_POINT_mul(group, point, d, NULL, NULL, NULL) == 1 &&
        EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, derived, 65, NULL) == 65) {
        if (memcmp(derived, pub.data, 65) != 0) result = 2;
        else if ((*key = p256_key(pub.data, 65, scalar)) != NULL) result = 0;
    }
    BN_clear_free(d);
    EC_POINT_free(point);
    EC_GROUP_free(group);
    OPENSSL_cleanse(scalar, sizeof scalar);
    ERR_clear_error();
    return result;
}

int32_t campfire_vapid_check(push_bytes pub, push_bytes priv) {
    EVP_PKEY *key = NULL;
    int result = vapid_key(pub, priv, &key);
    EVP_PKEY_free(key);
    return result;
}

// JWT's ES256 (RFC 7518 §3.4): the SHA-256 ECDSA signature of data by the VAPID key, as r || s,
// 64 bytes, into out. Whether it signed.
uint8_t campfire_vapid_sign(push_bytes pub, push_bytes priv, push_bytes data, gs_rref out) {
    EVP_PKEY *key = NULL;
    if (vapid_key(pub, priv, &key) != 0) return 0;
    uint8_t der[80], raw[64];
    size_t der_len = sizeof der;
    int ok = 0;
    EVP_MD_CTX *md = EVP_MD_CTX_new();
    if (md && EVP_DigestSignInit(md, NULL, EVP_sha256(), NULL, key) == 1 &&
        EVP_DigestSign(md, der, &der_len, data.data, (size_t)data.len) == 1) {
        const uint8_t *p = der;
        ECDSA_SIG *sig = d2i_ECDSA_SIG(NULL, &p, (long)der_len);
        const BIGNUM *r = NULL, *s = NULL;
        if (sig) {
            ECDSA_SIG_get0(sig, &r, &s);
            ok = BN_bn2binpad(r, raw, 32) == 32 && BN_bn2binpad(s, raw + 32, 32) == 32;
            ECDSA_SIG_free(sig);
        }
    }
    EVP_MD_CTX_free(md);
    EVP_PKEY_free(key);
    ERR_clear_error();
    if (ok) gs_bld_append(out, raw, 64);
    return (uint8_t)ok;
}

int64_t campfire_unix_seconds(void) { return (int64_t)time(NULL); }

// --- Surfguard.blocked_address? (default policy), RestrictedHTTP::PrivateNetworkGuard ----------

typedef struct { uint8_t addr[16]; int bits; } push_prefix;

static int parse_prefix(const char *text, push_prefix *p, int v6) {
    char buffer[64];
    const char *slash = strchr(text, '/');
    size_t len = slash ? (size_t)(slash - text) : strlen(text);
    if (len >= sizeof buffer) return 0;
    memcpy(buffer, text, len); buffer[len] = 0;
    p->bits = slash ? atoi(slash + 1) : (v6 ? 128 : 32);
    memset(p->addr, 0, 16);
    return inet_pton(v6 ? AF_INET6 : AF_INET, buffer, p->addr) == 1;
}

static int in_prefix(const uint8_t *addr, const char *text, int v6) {
    push_prefix p;
    if (!parse_prefix(text, &p, v6)) return 0;
    int full = p.bits / 8, rest = p.bits % 8;
    if (memcmp(addr, p.addr, (size_t)full) != 0) return 0;
    if (!rest) return 1;
    uint8_t mask = (uint8_t)(0xFF << (8 - rest));
    return (addr[full] & mask) == (p.addr[full] & mask);
}

static int in_any(const uint8_t *addr, const char *const *list, int v6) {
    for (; *list; ++list) if (in_prefix(addr, *list, v6)) return 1;
    return 0;
}

// Surfguard::DISALLOWED_IPV4, with what IPAddr#private?, #loopback? and #link_local? add (all in it).
static const char *const disallowed_ipv4[] = {
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "168.63.129.16/32", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
    "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15",
    "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4", NULL,
};
// Surfguard::DISALLOWED_IPV6, and IPAddr#private?, #loopback? and #link_local?.
static const char *const disallowed_ipv6[] = {
    "::/128", "100::/64", "100:0:0:1::/64", "2001::/32", "2001:2::/48",
    "2001:db8::/32", "2002::/16", "3fff::/20", "5f00::/16", "fec0::/10", "ff00::/8",
    "fc00::/7", "::1/128", "fe80::/10", "2001::/23", NULL,
};
static const char *const reachable_ietf_ipv6[] = { "2001:3::/32", "2001:4:112::/48", NULL };
// Surfguard::IANA_ALLOCATED_IPV6_UNICAST: other IPv6 addresses are refused.
static const char *const allocated_ipv6[] = {
    "2001::/23", "2001:200::/23", "2001:400::/23", "2001:600::/23", "2001:800::/22",
    "2001:c00::/23", "2001:e00::/23", "2001:1200::/23", "2001:1400::/22", "2001:1800::/23",
    "2001:1a00::/23", "2001:1c00::/22", "2001:2000::/19", "2001:4000::/23", "2001:4200::/23",
    "2001:4400::/23", "2001:4600::/23", "2001:4800::/23", "2001:4a00::/23", "2001:4c00::/23",
    "2001:5000::/20", "2001:8000::/19", "2001:a000::/20", "2001:b000::/20", "2002::/16",
    "2003::/18", "2400::/12", "2410::/12", "2600::/12", "2610::/23", "2620::/23", "2630::/12",
    "2800::/12", "2a00::/12", "2a10::/12", "2c00::/12", NULL,
};

static int blocked_ipv4(const uint8_t *v4) { return in_any(v4, disallowed_ipv4, 0); }

// Whether the guard refuses an address: v6 says whether addr is 16 bytes or 4.
int campfire_push_blocked(const uint8_t *addr, int v6) {
    if (!v6) return blocked_ipv4(addr);
    // IPv4-mapped and IPv4-compatible (::/96, so :: and ::1 too) are refused outright.
    if (in_prefix(addr, "::ffff:0:0/96", 1) || in_prefix(addr, "::/96", 1)) return 1;
    if (in_prefix(addr, "64:ff9b:1::/48", 1)) return 1;
    // NAT64 well-known and IPv4-translatable addresses are judged by the IPv4 they embed.
    if (in_prefix(addr, "64:ff9b::/96", 1) || in_prefix(addr, "::ffff:0:0:0/96", 1)) return blocked_ipv4(addr + 12);
    if (in_any(addr, reachable_ietf_ipv6, 1)) return 0;
    if (in_any(addr, disallowed_ipv6, 1)) return 1;
    return !in_any(addr, allocated_ipv6, 1);
}

static int same_name(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x = (char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = (char)(y - 'A' + 'a');
        if (x != y) return 0;
    }
    return 1;
}

// TEST ONLY: CAMPFIRE_PUSH_TEST_RESOLVE, "name=address,…", answers for those names in place of
// DNS. The guard still judges the answer. Off unless the environment sets it.
static int test_answer(const char *host, uint8_t addr[16], int *v6) {
    const char *table = getenv("CAMPFIRE_PUSH_TEST_RESOLVE");
    if (!table || !*table) return 0;
    size_t host_len = strlen(host);
    for (const char *entry = table; *entry;) {
        const char *end = strchr(entry, ',');
        size_t len = end ? (size_t)(end - entry) : strlen(entry);
        const char *eq = memchr(entry, '=', len);
        if (eq && (size_t)(eq - entry) == host_len && same_name(entry, host, host_len)) {
            char text[64];
            size_t text_len = len - (size_t)(eq + 1 - entry);
            if (text_len >= sizeof text) return -1;
            memcpy(text, eq + 1, text_len); text[text_len] = 0;
            if (inet_pton(AF_INET, text, addr) == 1) { *v6 = 0; return 1; }
            if (inet_pton(AF_INET6, text, addr) == 1) { *v6 = 1; return 1; }
            return -1;
        }
        if (!end) break;
        entry = end + 1;
    }
    return 0;
}

// RestrictedHTTP::PrivateNetworkGuard.resolve: host's addresses from the system resolver, and the
// first the guard admits, IPv4 before IPv6, as text into out. 0 when one is, -1 when host doesn't
// resolve (Surfguard::Unresolvable), -2 when it resolves only to refused addresses (Violation).
int32_t campfire_push_resolve(push_bytes host, gs_rref out) {
    char name[256];
    if (host.len <= 0 || host.len >= (int64_t)sizeof name || memchr(host.data, 0, (size_t)host.len)) return -1;
    memcpy(name, host.data, (size_t)host.len);
    name[host.len] = 0;
    uint8_t chosen[16];
    int chosen_v6 = -1, any = 0;
    uint8_t test[16];
    int test_v6 = 0;
    int answered = test_answer(name, test, &test_v6);
    if (answered < 0) return -1;
    if (answered > 0) {
        any = 1;
        if (!campfire_push_blocked(test, test_v6)) { memcpy(chosen, test, test_v6 ? 16 : 4); chosen_v6 = test_v6; }
    } else {
        struct addrinfo hints, *list = NULL;
        memset(&hints, 0, sizeof hints);
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(name, NULL, &hints, &list) != 0 || !list) return -1;
        for (int family = 0; family < 2 && chosen_v6 < 0; ++family) {
            for (struct addrinfo *a = list; a; a = a->ai_next) {
                const uint8_t *addr = NULL;
                if (family == 0 && a->ai_family == AF_INET) addr = (const uint8_t *)&((struct sockaddr_in *)a->ai_addr)->sin_addr;
                else if (family == 1 && a->ai_family == AF_INET6) addr = (const uint8_t *)&((struct sockaddr_in6 *)a->ai_addr)->sin6_addr;
                if (!addr) continue;
                any = 1;
                if (!campfire_push_blocked(addr, family)) { memcpy(chosen, addr, family ? 16 : 4); chosen_v6 = family; break; }
            }
        }
        freeaddrinfo(list);
    }
    if (!any) return -1;
    if (chosen_v6 < 0) return -2;
    char text[INET6_ADDRSTRLEN];
    if (!inet_ntop(chosen_v6 ? AF_INET6 : AF_INET, chosen, text, sizeof text)) return -1;
    gs_bld_append(out, text, (int64_t)strlen(text));
    return 0;
}

// Counts Web Push work turned away for a full queue; the count, so callers can log sparsely.
int64_t campfire_push_dropped(void) {
    static int64_t dropped;
    return __atomic_add_fetch(&dropped, 1, __ATOMIC_RELAXED);
}
