// libvips for Active Storage's image work, as ruby-vips does it for Campfire: the Vips image
// analyzer (ActiveStorage::Analyzer::ImageAnalyzer::Vips) and image_processing 1.14's
// resize_to_limit with the format conversion (ActiveStorage::Transformers::ImageProcessingTransformer).
// The calls are declared here rather than through vips/vips.h, which needs GLib's include paths.
// ffprobe and ffmpeg, for the video analyzer and previewer, run as child processes.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "goose.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

typedef struct { const uint8_t *data; int64_t len; } media_bytes;
typedef struct { int64_t *data; int64_t len; } media_i64s;

#ifdef _WIN32
int32_t campfire_image_analyze(media_bytes path, media_i64s info) { (void)path; (void)info; return 0; }
int32_t campfire_image_variant(media_bytes path, int64_t width, int64_t height, media_bytes suffix, gs_rref out, gs_rref error) {
    (void)path; (void)width; (void)height; (void)suffix; (void)out;
    gs_bld_append(error, (const uint8_t *)"libvips is unavailable", 22);
    return 0;
}
int32_t campfire_media_run(media_bytes args, int64_t timeout_ms, int64_t max_out, uint8_t capture_err, gs_rref out, gs_rref err) {
    (void)args; (void)timeout_ms; (void)max_out; (void)capture_err; (void)out; (void)err;
    return -2;
}
uint8_t campfire_ffmpeg_exists(void) { return 0; }
int32_t campfire_media_link(media_bytes path, media_bytes ext, gs_rref link) { (void)path; (void)ext; (void)link; return 0; }
void campfire_media_unlink(media_bytes link) { (void)link; }
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

static char *c_path(media_bytes path);

static int make_pipe(int fds[2]) {
#ifdef __linux__
    return pipe2(fds, O_CLOEXEC);
#else
    if (pipe(fds) != 0) return -1;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC); fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
#endif
}

// What campfire_media_run answers besides an exit status.
enum { RUN_UNSTARTED = -1, RUN_MISSING = -2, RUN_TIMED_OUT = -3, RUN_SIGNALED = -4, RUN_TOO_LARGE = -5 };

static int64_t clock_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

// The program and arguments of args, each ended by a NUL, as an argv; NULL when there are none
// or too many.
static char **split_args(media_bytes args) {
    if (args.len <= 0 || args.len > 65536 || args.data[args.len - 1] != 0) return NULL;
    int count = 0;
    for (int64_t i = 0; i < args.len; i++) if (args.data[i] == 0) count++;
    if (count > 64) return NULL;
    char *copy = malloc((size_t)args.len);
    char **argv = malloc(sizeof(char *) * (size_t)(count + 1));
    if (!copy || !argv) { free(copy); free(argv); return NULL; }
    memcpy(copy, args.data, (size_t)args.len);
    int n = 0; char *at = copy;
    while (n < count) { argv[n++] = at; at += strlen(at) + 1; }
    argv[n] = NULL;
    return argv;
}

static void free_args(char **argv) { if (argv) { free(argv[0]); free(argv); } }

// IO.popen(argv) as Active Storage's analyzers and previewers run ffprobe and ffmpeg: the program
// is looked up on PATH, stdin is /dev/null, stdout is appended to out (at most max_out bytes) and
// stderr either to err (its first 64 KiB) or to the server's own stderr. No other descriptor is
// inherited. The child is killed when it runs past timeout_ms, which Rails doesn't do, so that a
// crafted or hour-long video can't hold a media thread. Answers the exit status, or one of RUN_*.
int32_t campfire_media_run(media_bytes args, int64_t timeout_ms, int64_t max_out, uint8_t capture_err, gs_rref out, gs_rref err) {
    char **argv = split_args(args);
    if (!argv) return RUN_UNSTARTED;
    int out_pipe[2] = { -1, -1 }, err_pipe[2] = { -1, -1 };
    if (make_pipe(out_pipe) != 0 || (capture_err && make_pipe(err_pipe) != 0)) {
        if (out_pipe[0] >= 0) { close(out_pipe[0]); close(out_pipe[1]); }
        free_args(argv);
        return RUN_UNSTARTED;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attributes);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, out_pipe[1], 1);
    if (capture_err) posix_spawn_file_actions_adddup2(&actions, err_pipe[1], 2);
#if defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 34))
    posix_spawn_file_actions_addclosefrom_np(&actions, 3);
#endif
    // The child starts with no signals blocked and SIGPIPE's default action, whatever the
    // server's threads have.
    sigset_t none, defaults;
    sigemptyset(&none);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    posix_spawnattr_setsigmask(&attributes, &none);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    pid_t pid;
    int spawned = posix_spawnp(&pid, argv[0], &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    free_args(argv);
    close(out_pipe[1]);
    if (capture_err) close(err_pipe[1]);
    if (spawned != 0) {
        close(out_pipe[0]);
        if (capture_err) close(err_pipe[0]);
        return spawned == ENOENT ? RUN_MISSING : RUN_UNSTARTED;
    }
    int64_t deadline = clock_ms() + timeout_ms, written = 0, errored = 0;
    int result = 0, open_out = 1, open_err = capture_err ? 1 : 0;
    enum { CHUNK = 65536 };
    char *chunk = malloc(CHUNK);
    if (!chunk) result = RUN_UNSTARTED;
    // Read both pipes until they close, so that a chatty child can't stall on a full one.
    while ((open_out || open_err) && result == 0) {
        int64_t left = deadline - clock_ms();
        if (left <= 0) { result = RUN_TIMED_OUT; break; }
        struct pollfd fds[2]; int n = 0, at_out = -1, at_err = -1;
        if (open_out) { at_out = n; fds[n].fd = out_pipe[0]; fds[n].events = POLLIN; fds[n].revents = 0; n++; }
        if (open_err) { at_err = n; fds[n].fd = err_pipe[0]; fds[n].events = POLLIN; fds[n].revents = 0; n++; }
        int ready = poll(fds, (nfds_t)n, left > 1000 ? 1000 : (int)left);
        if (ready < 0 && errno != EINTR) { result = RUN_UNSTARTED; break; }
        if (ready <= 0) continue;
        if (at_out >= 0 && fds[at_out].revents) {
            ssize_t got = read(out_pipe[0], chunk, CHUNK);
            if (got > 0) {
                if (written + got > max_out) { result = RUN_TOO_LARGE; break; }
                gs_bld_append(out, chunk, got); written += got;
            } else if (got == 0 || errno != EINTR) open_out = 0;
        }
        if (at_err >= 0 && fds[at_err].revents) {
            ssize_t got = read(err_pipe[0], chunk, CHUNK);
            if (got > 0) {
                int64_t keep = got < 65536 - errored ? got : 65536 - errored;
                if (keep > 0) { gs_bld_append(err, chunk, keep); errored += keep; }
            } else if (got == 0 || errno != EINTR) open_err = 0;
        }
    }
    close(out_pipe[0]);
    if (capture_err) close(err_pipe[0]);
    free(chunk);
    // Both pipes closed: wait for the exit, polling waitpid with pauses that grow to 5 ms.
    int status = 0; int64_t pause_us = 1000;
    for (;;) {
        pid_t done = result == 0 ? waitpid(pid, &status, WNOHANG) : 0;
        if (done == pid) break;
        if (done < 0 && errno != EINTR) { result = RUN_UNSTARTED; break; }
        if (result != 0 || clock_ms() >= deadline) {
            if (result == 0) result = RUN_TIMED_OUT;
            kill(pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            break;
        }
        struct timespec nap = { 0, (long)pause_us * 1000 };
        nanosleep(&nap, NULL);
        pause_us = pause_us * 2 > 5000 ? 5000 : pause_us * 2;
    }
    if (result != 0) return result;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return RUN_SIGNALED;
}

static pthread_once_t ffmpeg_once = PTHREAD_ONCE_INIT;
static int ffmpeg_found;

static void ffmpeg_check(void) {
    static const char args[] = "ffmpeg\0-version";
    // The output is thrown away; a longer one than the buffer only ends the read.
    char out_buffer[65536]; gs_rhdr out_header = { (uint8_t *)out_buffer, 0 }; gs_stack out_stack = { (uint8_t *)out_buffer };
    gs_rref out = { &out_header, &out_stack };
    ffmpeg_found = campfire_media_run((media_bytes){ (const uint8_t *)args, sizeof args }, 10000, sizeof out_buffer, 0, out, out) == 0;
}

// VideoPreviewer.ffmpeg_exists?: whether `ffmpeg -version` succeeds, asked once.
uint8_t campfire_ffmpeg_exists(void) {
    pthread_once(&ffmpeg_once, ffmpeg_check);
    return (uint8_t)ffmpeg_found;
}

// Blob#open's tempfile, as the analyzers and previewers hand ffprobe and ffmpeg: a path ending in
// the blob's extension (ext, with its dot, or empty), here a symbolic link to the blob's file in a
// directory of its own under TMPDIR rather than a copy. Appends the link's path to link; 0 when it
// can't be made.
int32_t campfire_media_link(media_bytes path, media_bytes ext, gs_rref link) {
    char *target = c_path(path);
    if (!target || ext.len < 0 || ext.len > 64 || memchr(ext.data, '/', (size_t)ext.len) || memchr(ext.data, 0, (size_t)ext.len)) { free(target); return 0; }
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp || strlen(tmp) > 1024) tmp = "/tmp";
    char directory[1100];
    snprintf(directory, sizeof directory, "%s/ActiveStorage-XXXXXX", tmp);
    if (!mkdtemp(directory)) { free(target); return 0; }
    char name[1200];
    snprintf(name, sizeof name, "%s/blob%.*s", directory, (int)ext.len, (const char *)ext.data);
    int linked = symlink(target, name) == 0;
    free(target);
    if (!linked) { rmdir(directory); return 0; }
    gs_bld_append(link, name, (int64_t)strlen(name));
    return 1;
}

// Removes a link campfire_media_link made, and its directory.
void campfire_media_unlink(media_bytes link) {
    char *name = c_path(link);
    if (!name) return;
    unlink(name);
    char *slash = strrchr(name, '/');
    if (slash) { *slash = 0; rmdir(name); }
    free(name);
}

typedef struct _VipsImage VipsImage;
typedef struct _VipsOperation VipsOperation;

extern int vips_init(const char *argv0);
extern const char *vips_version_string(void);
extern void vips_block_untrusted_set(int state);
extern void vips_operation_block_set(const char *name, int state);
extern void vips_concurrency_set(int concurrency);
extern void vips_cache_set_max(int max);
extern const char *vips_error_buffer(void);
extern void vips_error_clear(void);
extern const char *vips_foreign_find_load(const char *filename);
extern VipsOperation *vips_operation_new(const char *name);
extern int vips_object_get_args(void *object, const char ***names, int **flags, int *n_args);
extern VipsImage *vips_image_new_from_file(const char *name, ...);
extern VipsImage *vips_image_new_matrix_from_array(int width, int height, const double *array, int size);
extern void vips_image_set_double(VipsImage *image, const char *name, double d);
extern int vips_image_get_width(const VipsImage *image);
extern int vips_image_get_height(const VipsImage *image);
extern unsigned long vips_image_get_typeof(const VipsImage *image, const char *name);
extern int vips_image_get_as_string(const VipsImage *image, const char *name, char **out);
extern int vips_autorot(VipsImage *in, VipsImage **out, ...);
extern int vips_thumbnail_image(VipsImage *in, VipsImage **out, int width, ...);
extern int vips_conv(VipsImage *in, VipsImage **out, VipsImage *mask, ...);
extern int vips_image_write_to_buffer(VipsImage *in, const char *suffix, void **buf, size_t *size, ...);
extern void g_object_unref(void *object);
extern void g_free(void *memory);

enum { ACCESS_SEQUENTIAL = 1, SIZE_DOWN = 2, PRECISION_INTEGER = 0 };
enum { ARGUMENT_REQUIRED = 1, ARGUMENT_CONSTRUCT = 2, ARGUMENT_INPUT = 16, ARGUMENT_DEPRECATED = 64 };

static pthread_once_t vips_once = PTHREAD_ONCE_INIT;
static int vips_ready;

// config/initializers/vips.rb: Vips.block_untrusted(true), Vips.block("VipsForeignLoadOpenslide", true).
// The media threads take one core each: libvips' own thread pool would compete with the HTTP workers.
static void vips_start(void) {
    if (vips_init("campfire") != 0) return;
    vips_block_untrusted_set(1);
    vips_operation_block_set("VipsForeignLoadOpenslide", 1);
    vips_concurrency_set(1);
    vips_cache_set_max(0);
    vips_ready = 1;
}

static int started(void) {
    pthread_once(&vips_once, vips_start);
    return vips_ready;
}

// libvips' error buffer is shared by every thread; this takes what is there.
static void take_error(gs_rref error, const char *fallback) {
    const char *text = vips_error_buffer();
    if (!text || !*text) text = fallback;
    size_t n = strlen(text);
    while (n > 0 && (text[n - 1] == '\n' || text[n - 1] == ' ')) n--;
    gs_bld_append(error, (const uint8_t *)text, (int64_t)n);
    vips_error_clear();
}

static char *c_path(media_bytes path) {
    if (path.len <= 0 || path.len > 4096 || memchr(path.data, 0, (size_t)path.len)) return NULL;
    char *p = malloc((size_t)path.len + 1);
    if (!p) return NULL;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    return p;
}

// ImageAnalyzer::Vips#metadata: Vips::Image.new_from_file(path, access: :sequential), its width and
// height, swapped for an EXIF orientation that turns it by 90 degrees. info gets width and height;
// returns 1, or 0 for a file libvips can't read, which Rails analyzes as {}.
int32_t campfire_image_analyze(media_bytes path, media_i64s info) {
    if (info.len < 2 || !started()) return 0;
    char *p = c_path(path);
    if (!p) return 0;
    VipsImage *image = vips_image_new_from_file(p, "access", ACCESS_SEQUENTIAL, NULL);
    free(p);
    if (!image) { vips_error_clear(); return 0; }
    int64_t width = vips_image_get_width(image), height = vips_image_get_height(image);
    if (vips_image_get_typeof(image, "exif-ifd0-Orientation") != 0) {
        char *orientation = NULL;
        if (vips_image_get_as_string(image, "exif-ifd0-Orientation", &orientation) == 0 && orientation) {
            if (strstr(orientation, "Right-top") || strstr(orientation, "Left-bottom") ||
                strstr(orientation, "Top-right") || strstr(orientation, "Bottom-left")) {
                int64_t t = width; width = height; height = t;
            }
            g_free(orientation);
        } else vips_error_clear();
    }
    g_object_unref(image);
    info.data[0] = width;
    info.data[1] = height;
    return 1;
}

// Whether the loader libvips picks for path takes an optional page, as image_processing's
// Utils.select_valid_loader_options asks ruby-vips' Introspect.
static int loader_accepts_page(const char *path) {
    const char *loader = vips_foreign_find_load(path);
    if (!loader) { vips_error_clear(); return 0; }
    VipsOperation *operation = vips_operation_new(loader);
    if (!operation) { vips_error_clear(); return 0; }
    const char **names = NULL; int *flags = NULL; int n = 0, found = 0;
    if (vips_object_get_args(operation, &names, &flags, &n) == 0) {
        for (int i = 0; i < n; i++) {
            if (strcmp(names[i], "page") != 0) continue;
            int required = (flags[i] & ARGUMENT_REQUIRED) && !(flags[i] & ARGUMENT_DEPRECATED);
            if ((flags[i] & ARGUMENT_CONSTRUCT) && (flags[i] & ARGUMENT_INPUT) && !required) found = 1;
        }
    }
    g_object_unref(operation);
    return found;
}

// variation.transform: ImageProcessing::Vips.source(file).loader(page: 0).convert(format)
// .resize_to_limit(width, height).call, i.e. autorot after loading, thumbnail_image(width,
// height:, size: :down, no_rotate: true), conv(SHARPEN_MASK, precision: :integer), and the saver
// suffix picks (".png", ".jpg", ".webp", ...). A width or height below 0 is no limit; both below 0
// is no resize. Appends the encoded image to out; 0 with why in error when libvips fails.
int32_t campfire_image_variant(media_bytes path, int64_t width, int64_t height, media_bytes suffix, gs_rref out, gs_rref error) {
    if (!started()) { gs_bld_append(error, (const uint8_t *)"vips_init failed", 16); return 0; }
    char *p = c_path(path), *s = c_path(suffix);
    if (!p || !s) { free(p); free(s); gs_bld_append(error, (const uint8_t *)"invalid path", 12); return 0; }
    VipsImage *loaded = loader_accepts_page(p) ? vips_image_new_from_file(p, "page", 0, NULL) : vips_image_new_from_file(p, NULL);
    free(p);
    if (!loaded) { free(s); take_error(error, "cannot load the image"); return 0; }
    VipsImage *image = NULL;
    int status = vips_autorot(loaded, &image, NULL);
    g_object_unref(loaded);
    if (status != 0) { free(s); take_error(error, "autorot failed"); return 0; }
    if (width >= 0 || height >= 0) {
        int w = width < 0 ? 10000000 : (int)width, h = height < 0 ? 10000000 : (int)height;
        VipsImage *thumbnail = NULL;
        status = vips_thumbnail_image(image, &thumbnail, w, "height", h, "size", SIZE_DOWN, "no_rotate", 1, NULL);
        g_object_unref(image);
        if (status != 0) { free(s); take_error(error, "thumbnail failed"); return 0; }
        static const double sharpen[9] = { -1, -1, -1, -1, 32, -1, -1, -1, -1 };
        VipsImage *mask = vips_image_new_matrix_from_array(3, 3, sharpen, 9);
        if (!mask) { g_object_unref(thumbnail); free(s); take_error(error, "mask failed"); return 0; }
        vips_image_set_double(mask, "scale", 24.0);
        vips_image_set_double(mask, "offset", 0.0);
        status = vips_conv(thumbnail, &image, mask, "precision", PRECISION_INTEGER, NULL);
        g_object_unref(mask);
        g_object_unref(thumbnail);
        if (status != 0) { free(s); take_error(error, "sharpen failed"); return 0; }
    }
    void *buffer = NULL; size_t size = 0;
    status = vips_image_write_to_buffer(image, s, &buffer, &size, NULL);
    g_object_unref(image);
    free(s);
    if (status != 0) { take_error(error, "cannot save the image"); return 0; }
    gs_bld_append(out, (const uint8_t *)buffer, (int64_t)size);
    g_free(buffer);
    return 1;
}
#endif
