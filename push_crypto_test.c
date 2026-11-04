// push_crypto.c against RFC 8291's example, ES256 signatures OpenSSL verifies, and the address guard.
#include "push_crypto.c"
#include <assert.h>
#include <openssl/ecdsa.h>

static uint8_t storage[1 << 16];
static gs_stack stack;
static gs_rhdr header;

static gs_rref fresh(void) {
    stack.top = storage;
    header.base = storage;
    header.len = 0;
    return (gs_rref){ &header, &stack };
}

static size_t decode(const char *text, uint8_t *out) {
    char standard[256];
    size_t n = strlen(text), i;
    for (i = 0; i < n; ++i) standard[i] = text[i] == '-' ? '+' : text[i] == '_' ? '/' : text[i];
    while (i % 4) standard[i++] = '=';
    standard[i] = 0;
    uint8_t raw[256];
    int len = EVP_DecodeBlock(raw, (const unsigned char *)standard, (int)i);
    assert(len >= 0);
    size_t pad = 0;
    while (pad < i && standard[i - 1 - pad] == '=') ++pad;
    memcpy(out, raw, (size_t)len - pad);
    return (size_t)len - pad;
}

static push_bytes bytes(const uint8_t *data, size_t len) { return (push_bytes){ data, (int64_t)len }; }

static int blocked(const char *text) {
    uint8_t addr[16];
    if (inet_pton(AF_INET, text, addr) == 1) return campfire_push_blocked(addr, 0);
    assert(inet_pton(AF_INET6, text, addr) == 1);
    return campfire_push_blocked(addr, 1);
}

int main(void) {
    // RFC 8291, section 5 and appendix A.
    uint8_t ua_public[65], auth[16], salt[16], as_private[32], body[256];
    assert(decode("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4", ua_public) == 65);
    assert(decode("BTBZMqHH6r4Tts7J_aSIgg", auth) == 16);
    assert(decode("DGv6ra1nlYgDCS1FRnbzlw", salt) == 16);
    assert(decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw", as_private) == 32);
    size_t body_len = decode("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN", body);
    const char *plain = "When I grow up, I want to be a watermelon";
    gs_rref out = fresh();
    assert(campfire_push_encrypt(bytes(ua_public, 65), bytes(auth, 16), bytes((const uint8_t *)plain, strlen(plain)),
                                 bytes(salt, 16), bytes(as_private, 32), out) == 0);
    assert((size_t)header.len == body_len);
    // The gem's record size is the record's length (58) where the RFC's example says 4096.
    assert(memcmp(storage, body, 16) == 0);
    assert(storage[16] == 0 && storage[17] == 0 && storage[18] == 0 && storage[19] == 58);
    assert(memcmp(storage + 20, body + 20, body_len - 20) == 0);

    // A random sender and salt, and the errors.
    out = fresh();
    assert(campfire_push_encrypt(bytes(ua_public, 65), bytes(auth, 16), bytes((const uint8_t *)plain, strlen(plain)), bytes(NULL, 0), bytes(NULL, 0), out) == 0);
    assert(header.len == 86 + (int64_t)strlen(plain) + 17 && memcmp(storage, body, 16) != 0);
    uint8_t off_curve[65];
    memcpy(off_curve, ua_public, 65);
    off_curve[64] ^= 1;
    out = fresh();
    assert(campfire_push_encrypt(bytes(off_curve, 65), bytes(auth, 16), bytes((const uint8_t *)plain, 5), bytes(NULL, 0), bytes(NULL, 0), out) == PUSH_INVALID_KEY);
    assert(campfire_push_encrypt(bytes(ua_public, 64), bytes(auth, 16), bytes((const uint8_t *)plain, 5), bytes(NULL, 0), bytes(NULL, 0), out) == PUSH_INVALID_KEY);
    static uint8_t big[4080];
    assert(campfire_push_encrypt(bytes(ua_public, 65), bytes(auth, 16), bytes(big, 4079), bytes(NULL, 0), bytes(NULL, 0), out) == 0);
    out = fresh();
    assert(campfire_push_encrypt(bytes(ua_public, 65), bytes(auth, 16), bytes(big, 4080), bytes(NULL, 0), bytes(NULL, 0), out) == PUSH_TOO_BIG);
    assert(header.len == 0);

    // VAPID: the RFC's sender pair, a mismatched pair, and a signature OpenSSL verifies.
    uint8_t as_public[65], ua_private[32];
    assert(decode("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8", as_public) == 65);
    assert(decode("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94", ua_private) == 32);
    assert(campfire_vapid_check(bytes(as_public, 65), bytes(as_private, 32)) == 0);
    assert(campfire_vapid_check(bytes(ua_public, 65), bytes(as_private, 32)) == 2);
    assert(campfire_vapid_check(bytes(off_curve, 65), bytes(as_private, 32)) == 2);
    assert(campfire_vapid_check(bytes(as_public, 65), bytes(NULL, 0)) == 1);
    const char *signing = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9.e30";
    out = fresh();
    assert(campfire_vapid_sign(bytes(as_public, 65), bytes(as_private, 32), bytes((const uint8_t *)signing, strlen(signing)), out));
    assert(header.len == 64);
    ECDSA_SIG *sig = ECDSA_SIG_new();
    assert(ECDSA_SIG_set0(sig, BN_bin2bn(storage, 32, NULL), BN_bin2bn(storage + 32, 32, NULL)) == 1);
    unsigned char *der = NULL;
    int der_len = i2d_ECDSA_SIG(sig, &der);
    EVP_PKEY *verifier = p256_key(as_public, 65, NULL);
    EVP_MD_CTX *md = EVP_MD_CTX_new();
    assert(EVP_DigestVerifyInit(md, NULL, EVP_sha256(), NULL, verifier) == 1);
    assert(EVP_DigestVerify(md, der, (size_t)der_len, (const uint8_t *)signing, strlen(signing)) == 1);
    EVP_MD_CTX_free(md);
    EVP_PKEY_free(verifier);
    OPENSSL_free(der);
    ECDSA_SIG_free(sig);

    // Surfguard's default policy.
    const char *refused[] = { "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1",
        "0.0.0.0", "168.63.129.16", "192.0.2.1", "198.18.0.1", "203.0.113.9", "224.0.0.1", "255.255.255.255",
        "::1", "::", "fe80::1", "fc00::1", "fd12::1", "::ffff:8.8.8.8", "::8.8.8.8", "64:ff9b::a00:1", "64:ff9b:1::1",
        "2001:db8::1", "2001::1", "2002::1", "ff02::1", "3fff::1", "5f00::1", "fec0::1", "4000::1", NULL };
    const char *admitted[] = { "8.8.8.8", "142.250.74.10", "93.184.216.34", "172.32.0.1", "2a00:1450:4001::1",
        "2606:4700::1", "64:ff9b::808:808", "2001:3::1", "2001:4:112::1", "2001:4860::1", NULL };
    for (const char **a = refused; *a; ++a) if (!blocked(*a)) { fprintf(stderr, "admitted %s\n", *a); return 1; }
    for (const char **a = admitted; *a; ++a) if (blocked(*a)) { fprintf(stderr, "refused %s\n", *a); return 1; }

    // Lookups: literals, the test table, and names that don't resolve.
    out = fresh();
    assert(campfire_push_resolve(bytes((const uint8_t *)"127.0.0.1", 9), out, -1) == -2);
    assert(campfire_push_resolve(bytes((const uint8_t *)"8.8.8.8", 7), out, -1) == 0 && header.len == 7 && !memcmp(storage, "8.8.8.8", 7));
    setenv("CAMPFIRE_PUSH_TEST_RESOLVE", "push.test=93.184.216.34,private.test=10.0.0.1", 1);
    out = fresh();
    assert(campfire_push_resolve(bytes((const uint8_t *)"PUSH.test", 9), out, -1) == 0 && header.len == 13 && !memcmp(storage, "93.184.216.34", 13));
    assert(campfire_push_resolve(bytes((const uint8_t *)"private.test", 12), out, -1) == -2);
    assert(campfire_push_resolve(bytes((const uint8_t *)"nothing.invalid", 15), out, -1) == -1);
    // A time limit: the answer as before, from the lookup's own thread, or -3 once it has passed.
    setenv("CAMPFIRE_PUSH_TEST_RESOLVE", "push.test=93.184.216.34,slow.test=hang", 1);
    out = fresh();
    assert(campfire_push_resolve(bytes((const uint8_t *)"push.test", 9), out, 5000) == 0 && header.len == 13 && !memcmp(storage, "93.184.216.34", 13));
    assert(campfire_push_resolve(bytes((const uint8_t *)"8.8.8.8", 7), out, 0) == -3);
    int64_t started = lookup_clock_ms();
    out = fresh();
    assert(campfire_push_resolve(bytes((const uint8_t *)"slow.test", 9), out, 200) == -3 && header.len == 0);
    int64_t took = lookup_clock_ms() - started;
    assert(took >= 150 && took < 2000);
    unsetenv("CAMPFIRE_PUSH_TEST_RESOLVE");
    puts("push crypto: RFC 8291 example, ES256, address guard ok");
    return 0;
}
