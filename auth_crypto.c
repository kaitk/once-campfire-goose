// Sign-in's C helpers over OpenSSL's libcrypto: AES-256-GCM for the Rails session cookie
// (ActiveSupport::MessageEncryptor's aes-256-gcm), and the counters of SessionsController's
// rate_limit, which every worker thread shares as Rails' processes share its cache store.
#include "goose.h"
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

typedef struct { const uint8_t *data; int64_t len; } auth_bytes;

// plaintext sealed with key (32 bytes) under a random 12-byte IV: out gets the IV, the 16-byte
// tag and the ciphertext, in that order.
uint8_t campfire_gcm_encrypt(auth_bytes key, auth_bytes plaintext, gs_rref out) {
    if (key.len != 32 || plaintext.len < 0 || plaintext.len > (1 << 20)) return 0;
    uint8_t iv[12], tag[16];
    if (RAND_bytes(iv, sizeof iv) != 1) return 0;
    uint8_t *sealed = malloc((size_t)plaintext.len + 16);
    if (!sealed) return 0;
    int ok = 0, length = 0, final = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx && EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1 &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, sizeof iv, NULL) == 1 &&
        EVP_EncryptInit_ex(ctx, NULL, NULL, key.data, iv) == 1 &&
        EVP_EncryptUpdate(ctx, sealed, &length, plaintext.data, (int)plaintext.len) == 1 &&
        EVP_EncryptFinal_ex(ctx, sealed + length, &final) == 1 &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, sizeof tag, tag) == 1) {
        gs_bld_append(out, iv, sizeof iv);
        gs_bld_append(out, tag, sizeof tag);
        gs_bld_append(out, sealed, (int64_t)(length + final));
        ok = 1;
    }
    EVP_CIPHER_CTX_free(ctx);
    free(sealed);
    return (uint8_t)ok;
}

// The plaintext of ciphertext sealed with key, iv (12 bytes) and tag (16 bytes); false when it
// doesn't open.
uint8_t campfire_gcm_decrypt(auth_bytes key, auth_bytes iv, auth_bytes tag, auth_bytes ciphertext, gs_rref out) {
    if (key.len != 32 || iv.len != 12 || tag.len != 16 || ciphertext.len < 0 || ciphertext.len > (1 << 20)) return 0;
    uint8_t *plain = malloc((size_t)ciphertext.len + 16);
    if (!plain) return 0;
    int ok = 0, length = 0, final = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx && EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1 &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) == 1 &&
        EVP_DecryptInit_ex(ctx, NULL, NULL, key.data, iv.data) == 1 &&
        EVP_DecryptUpdate(ctx, plain, &length, ciphertext.data, (int)ciphertext.len) == 1 &&
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, (void *)tag.data) == 1 &&
        EVP_DecryptFinal_ex(ctx, plain + length, &final) == 1) {
        gs_bld_append(out, plain, (int64_t)(length + final));
        ok = 1;
    }
    EVP_CIPHER_CTX_free(ctx);
    free(plain);
    return (uint8_t)ok;
}

// rate_limit's counters: "rate-limit:<controller>:<key>" incremented with expires_in: within,
// which sets the expiry only when the counter starts (a fixed window from the first hit).
typedef struct { char key[96]; int64_t count; int64_t expires_ms; } rate_entry;
static rate_entry *rate_entries;
static int64_t rate_used, rate_size;
#ifdef _WIN32
static SRWLOCK rate_mutex = SRWLOCK_INIT;
#define rate_lock() AcquireSRWLockExclusive(&rate_mutex)
#define rate_unlock() ReleaseSRWLockExclusive(&rate_mutex)
#else
static pthread_mutex_t rate_mutex = PTHREAD_MUTEX_INITIALIZER;
#define rate_lock() pthread_mutex_lock(&rate_mutex)
#define rate_unlock() pthread_mutex_unlock(&rate_mutex)
#endif

// The count for key after this hit, at now_ms, in a window of window_ms.
int64_t campfire_rate_count(auth_bytes key, int64_t now_ms, int64_t window_ms) {
    if (key.len < 0) return 0;
    size_t length = key.len >= 95 ? 95 : (size_t)key.len;
    rate_lock();
    int64_t kept = 0, found = -1;
    for (int64_t i = 0; i < rate_used; ++i) {
        if (rate_entries[i].expires_ms <= now_ms) continue;
        if (kept != i) rate_entries[kept] = rate_entries[i];
        if (strlen(rate_entries[kept].key) == length && memcmp(rate_entries[kept].key, key.data, length) == 0) found = kept;
        ++kept;
    }
    rate_used = kept;
    int64_t count = 1;
    if (found >= 0) {
        count = ++rate_entries[found].count;
    } else {
        if (rate_used == rate_size) {
            int64_t size = rate_size ? rate_size * 2 : 64;
            if (size <= 65536) {
                rate_entry *grown = realloc(rate_entries, (size_t)size * sizeof *grown);
                if (grown) { rate_entries = grown; rate_size = size; }
            }
        }
        if (rate_used < rate_size) {
            rate_entry *e = &rate_entries[rate_used++];
            memcpy(e->key, key.data, length);
            e->key[length] = 0;
            e->count = 1;
            e->expires_ms = now_ms + window_ms;
        }
    }
    rate_unlock();
    return count;
}
