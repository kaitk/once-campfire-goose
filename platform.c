#include "goose.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <crypt.h>
#include <qrencode.h>
#include <pthread.h>
#endif

typedef struct { const uint8_t *data; int64_t len; } campfire_bytes;
typedef struct { const uint64_t *data; int64_t len; } campfire_times;

int64_t campfire_qr(campfire_bytes text, gs_rref out) {
#ifdef _WIN32
    return 0;
#else
    if (text.len < 1 || text.len > 8192) return 0;
    QRcode *qr = QRcode_encodeData((int)text.len, text.data, 0, QR_ECLEVEL_M);
    if (!qr) return 0;
    int64_t width = qr->width;
    gs_bld_append(out, qr->data, width * width);
    QRcode_free(qr);
    return width;
#endif
}

static int profile_writes;
void campfire_profile_enable(uint8_t enabled) { profile_writes = enabled; }
uint64_t campfire_profile_clock(void) {
    if (!profile_writes) return 0;
    struct timespec now;
#ifdef _WIN32
    timespec_get(&now, TIME_UTC);
#else
    clock_gettime(CLOCK_MONOTONIC, &now);
#endif
    return (uint64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

void campfire_profile_record(campfire_times times) {
    if (!profile_writes || times.len != 6) return;
    static _Thread_local uint64_t count, totals[6];
    for (int i = 0; i < 6; ++i) totals[i] += times.data[i];
    if (++count == 1024) {
        fprintf(stderr, "write_profile count=%llu context_ns=%llu wait_ns=%llu sql_ns=%llu render_ns=%llu commit_ns=%llu cleanup_ns=%llu\n",
                (unsigned long long)count, (unsigned long long)totals[0], (unsigned long long)totals[1],
                (unsigned long long)totals[2], (unsigned long long)totals[3], (unsigned long long)totals[4], (unsigned long long)totals[5]);
        count = 0;
        memset(totals, 0, sizeof totals);
    }
}

int64_t campfire_epoch_ms(campfire_bytes text) {
    if (text.len < 19 || text.len >= 64) return 0;
    char input[64]; memcpy(input, text.data, (size_t)text.len); input[text.len] = 0;
    if (input[10] == 'T') input[10] = ' ';
    struct tm utc = {0};
    if (sscanf(input, "%d-%d-%d %d:%d:%d", &utc.tm_year, &utc.tm_mon, &utc.tm_mday,
               &utc.tm_hour, &utc.tm_min, &utc.tm_sec) != 6) return 0;
    utc.tm_year -= 1900; --utc.tm_mon;
#ifdef _WIN32
    time_t seconds = _mkgmtime(&utc);
#else
    time_t seconds = timegm(&utc);
#endif
    // Rails converts the exact decimal timestamp to double before multiplying by 1000.
    char decimal[96];
    snprintf(decimal, sizeof decimal, "%lld%s", (long long)seconds, input[19] == '.' ? input + 19 : "");
    return (int64_t)(strtod(decimal, NULL) * 1000.0);
}

#ifdef _WIN32
static SRWLOCK writer_mutex = SRWLOCK_INIT, checkpoint_mutex = SRWLOCK_INIT;
typedef CONDITION_VARIABLE writer_condition;
#define writer_lock() AcquireSRWLockExclusive(&writer_mutex)
#define writer_unlock() ReleaseSRWLockExclusive(&writer_mutex)
#define condition_init(c) InitializeConditionVariable(c)
#define condition_wait(c) SleepConditionVariableSRW(c, &writer_mutex, INFINITE, 0)
#define condition_signal(c) WakeConditionVariable(c)
#define condition_destroy(c) ((void)(c))
void campfire_checkpoint_lock(void) { AcquireSRWLockExclusive(&checkpoint_mutex); }
void campfire_checkpoint_unlock(void) { ReleaseSRWLockExclusive(&checkpoint_mutex); }
#else
static pthread_mutex_t writer_mutex = PTHREAD_MUTEX_INITIALIZER, checkpoint_mutex = PTHREAD_MUTEX_INITIALIZER;
typedef pthread_cond_t writer_condition;
#define writer_lock() pthread_mutex_lock(&writer_mutex)
#define writer_unlock() pthread_mutex_unlock(&writer_mutex)
#define condition_init(c) pthread_cond_init(c, NULL)
#define condition_wait(c) pthread_cond_wait(c, &writer_mutex)
#define condition_signal(c) pthread_cond_signal(c)
#define condition_destroy(c) pthread_cond_destroy(c)
void campfire_checkpoint_lock(void) { pthread_mutex_lock(&checkpoint_mutex); }
void campfire_checkpoint_unlock(void) { pthread_mutex_unlock(&checkpoint_mutex); }
#endif

typedef struct writer_waiter {
    struct writer_waiter *next;
    writer_condition condition;
    int ready;
} writer_waiter;
static writer_waiter *writer_first, *writer_last;
static int writer_active;
static int64_t checkpoint_woken_at;

// Access changes that open cable connections must follow: revocations and room grants, in the order they
// commit. Cable workers read the epoch once per publication mail they enroll, and the entries only when it moved.
#define CAMPFIRE_ACCESS_LOG 4096
static int64_t access_entries[CAMPFIRE_ACCESS_LOG][3];
static int64_t access_epoch;
#ifdef _WIN32
static SRWLOCK access_mutex = SRWLOCK_INIT;
#define access_lock() AcquireSRWLockExclusive(&access_mutex)
#define access_unlock() ReleaseSRWLockExclusive(&access_mutex)
#else
static pthread_mutex_t access_mutex = PTHREAD_MUTEX_INITIALIZER;
#define access_lock() pthread_mutex_lock(&access_mutex)
#define access_unlock() pthread_mutex_unlock(&access_mutex)
#endif

void campfire_access_note(int64_t kind, int64_t user, int64_t room) {
    access_lock();
    int64_t *entry = access_entries[access_epoch & (CAMPFIRE_ACCESS_LOG - 1)];
    entry[0] = kind; entry[1] = user; entry[2] = room;
    __atomic_store_n(&access_epoch, access_epoch + 1, __ATOMIC_RELEASE);
    access_unlock();
}

int64_t campfire_access_epoch(void) { return __atomic_load_n(&access_epoch, __ATOMIC_ACQUIRE); }

// Field 0, 1 or 2 of entry index, or -1 once a later note replaced it.
int64_t campfire_access_field(int64_t index, int64_t field) {
    access_lock();
    int64_t value = access_epoch - index > CAMPFIRE_ACCESS_LOG || index >= access_epoch || field < 0 || field > 2
        ? -1 : access_entries[index & (CAMPFIRE_ACCESS_LOG - 1)][field];
    access_unlock();
    return value;
}

// Called under writer admission, so the shared notification counter needs no lock.
uint8_t campfire_checkpoint_due(int64_t pages) {
    if (pages < checkpoint_woken_at) checkpoint_woken_at = 0;
    if (pages - checkpoint_woken_at < 1000) return 0;
    checkpoint_woken_at = pages;
    return 1;
}

// FIFO admission wakes only the next writer. Each queued node belongs to the
// waiting call's stack and is removed before that call can return.
void campfire_writer_enter(void) {
    writer_lock();
    if (!writer_active) { writer_active = 1; writer_unlock(); return; }
    writer_waiter waiter = {0};
    condition_init(&waiter.condition);
    if (writer_last) writer_last->next = &waiter; else writer_first = &waiter;
    writer_last = &waiter;
    while (!waiter.ready) condition_wait(&waiter.condition);
    writer_unlock();
    condition_destroy(&waiter.condition);
}

void campfire_writer_leave(void) {
    writer_lock();
    if (writer_first) {
        writer_waiter *next = writer_first;
        writer_first = next->next;
        if (!writer_first) writer_last = NULL;
        next->ready = 1;
        condition_signal(&next->condition);
    } else { writer_active = 0; }
    writer_unlock();
}

static size_t campfire_timestamp_text(char text[40], const struct timespec *instant, int sql, int future, int seconds_ago) {
    typedef struct { time_t second; size_t length; char prefix[32]; } timestamp_prefix;
    static _Thread_local timestamp_prefix prefixes[6];
    timestamp_prefix *prefix = &prefixes[sql + (future ? 2 : seconds_ago ? 4 : 0)];
    time_t now = instant->tv_sec - seconds_ago;
    // Only the calendar conversion is cached; fractions always use this clock sample.
    if (!prefix->length || prefix->second != now) {
        struct tm utc;
#ifdef _WIN32
        if (gmtime_s(&utc, &now)) return 0;
#else
        if (!gmtime_r(&now, &utc)) return 0;
#endif
        if (future) {
            utc.tm_year += 20;
            int year = utc.tm_year + 1900;
            if (utc.tm_mon == 1 && utc.tm_mday == 29 && (year % 4 || (year % 100 == 0 && year % 400)))
                utc.tm_mday = 28;
        }
        prefix->length = strftime(prefix->prefix, sizeof prefix->prefix,
                                  sql ? "%Y-%m-%d %H:%M:%S" : "%Y-%m-%dT%H:%M:%S", &utc);
        if (!prefix->length) return 0;
        prefix->second = now;
    }
    size_t length = prefix->length;
    memcpy(text, prefix->prefix, length);
    text[length++] = '.';
    int digits = sql ? 6 : 3;
    long fraction = instant->tv_nsec / (sql ? 1000 : 1000000);
    for (int i = digits; i > 0; --i) { text[length + i - 1] = '0' + fraction % 10; fraction /= 10; }
    length += digits;
    if (!sql) text[length++] = 'Z';
    text[length] = 0;
    return length;
}

static void campfire_timestamp(gs_rref out, int sql, int future, int seconds_ago) {
    struct timespec instant;
    if (!timespec_get(&instant, TIME_UTC)) return;
    char text[40];
    size_t length = campfire_timestamp_text(text, &instant, sql, future, seconds_ago);
    gs_bld_append(out, text, (int64_t)length);
}

void campfire_now(gs_rref out) { campfire_timestamp(out, 0, 0, 0); }
void campfire_sql_now(gs_rref out) { campfire_timestamp(out, 1, 0, 0); }
void campfire_expiry(gs_rref out) { campfire_timestamp(out, 0, 1, 0); }
void campfire_disconnected_before(gs_rref out) { campfire_timestamp(out, 1, 0, 60); }

// Time.current + seconds, as iso8601(3): a signed message's expiry.
void campfire_after(int64_t seconds, gs_rref out) {
    struct timespec instant;
    if (!timespec_get(&instant, TIME_UTC)) return;
    time_t when = instant.tv_sec + (time_t)seconds;
    struct tm utc;
#ifdef _WIN32
    if (gmtime_s(&utc, &when)) return;
#else
    if (!gmtime_r(&when, &utc)) return;
#endif
    char text[48];
    size_t length = strftime(text, sizeof text, "%Y-%m-%dT%H:%M:%S", &utc);
    if (!length) return;
    length += (size_t)snprintf(text + length, sizeof text - length, ".%03dZ", (int)(instant.tv_nsec / 1000000));
    gs_bld_append(out, text, (int64_t)length);
}

int32_t campfire_password_verify(campfire_bytes password, campfire_bytes digest) {
#ifdef _WIN32
    (void)password;
    (void)digest;
    return -1;
#else
    if (password.len < 0 || password.len > 4096 || digest.len != 60 ||
        memchr(password.data, 0, (size_t)password.len) || digest.data[0] != '$' || digest.data[1] != '2')
        return 0;
    char input[73], setting[61];
    size_t length = password.len > 72 ? 72 : (size_t)password.len;
    memcpy(input, password.data, length);
    input[length] = 0;
    memcpy(setting, digest.data, 60);
    setting[60] = 0;
    struct crypt_data state = {0};
    char *result = crypt_r(input, setting, &state);
    if (!result || strlen(result) != 60) return 0;
    unsigned difference = 0;
    for (int i = 0; i < 60; ++i) difference |= (unsigned char)result[i] ^ digest.data[i];
    return difference == 0;
#endif
}

uint8_t campfire_password_hash(campfire_bytes password, campfire_bytes entropy, gs_rref out) {
#ifdef _WIN32
    (void)password; (void)entropy; (void)out;
    return 0;
#else
    if (password.len < 1 || password.len > 72 || entropy.len != 16 || memchr(password.data, 0, (size_t)password.len)) return 0;
    char input[73], setting[CRYPT_GENSALT_OUTPUT_SIZE];
    memcpy(input, password.data, (size_t)password.len); input[password.len] = 0;
    if (!crypt_gensalt_rn("$2b$", 12, (const char *)entropy.data, (int)entropy.len, setting, sizeof setting)) return 0;
    struct crypt_data state = {0};
    const char *digest = crypt_r(input, setting, &state);
    if (!digest || strlen(digest) != 60) return 0;
    gs_bld_append(out, digest, 60);
    memset(input, 0, sizeof input);
    memset(&state, 0, sizeof state);
    return 1;
#endif
}

/* A monotonic clock in milliseconds, for cable write pacing. */
int64_t campfire_clock_ms(void) {
#ifdef _WIN32
    return (int64_t)GetTickCount64();
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
#endif
}

/* MD5 (RFC 1321), for Active Storage's blob checksums. */
static const uint32_t md5_k[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
static const uint8_t md5_s[16] = {7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21};

void campfire_md5(campfire_bytes data, gs_rref out) {
    uint32_t h[4] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476};
    uint64_t bits = (uint64_t)data.len * 8;
    int64_t total = ((data.len + 8) / 64 + 1) * 64;
    for (int64_t at = 0; at < total; at += 64) {
        uint8_t block[64];
        for (int i = 0; i < 64; ++i) {
            int64_t n = at + i;
            block[i] = n < data.len ? data.data[n] : n == data.len ? 0x80 :
                       n >= total - 8 ? (uint8_t)(bits >> (8 * (n - (total - 8)))) : 0;
        }
        uint32_t w[16];
        for (int i = 0; i < 16; ++i)
            w[i] = (uint32_t)block[4 * i] | (uint32_t)block[4 * i + 1] << 8 | (uint32_t)block[4 * i + 2] << 16 | (uint32_t)block[4 * i + 3] << 24;
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
        for (int i = 0; i < 64; ++i) {
            uint32_t f; int g;
            if (i < 16) { f = (b & c) | (~b & d); g = i; }
            else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) & 15; }
            else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) & 15; }
            else { f = c ^ (b | ~d); g = (7 * i) & 15; }
            uint32_t s = md5_s[(i >> 4) * 4 + (i & 3)];
            uint32_t sum = a + f + md5_k[i] + w[g];
            a = d; d = c; c = b;
            b = b + (sum << s | sum >> (32 - s));
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    }
    uint8_t digest[16];
    for (int i = 0; i < 16; ++i) digest[i] = (uint8_t)(h[i >> 2] >> (8 * (i & 3)));
    gs_bld_append(out, digest, 16);
}
