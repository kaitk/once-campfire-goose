// libvips for Active Storage's image work, as ruby-vips does it for Campfire: the Vips image
// analyzer (ActiveStorage::Analyzer::ImageAnalyzer::Vips) and image_processing 1.14's
// resize_to_limit with the format conversion (ActiveStorage::Transformers::ImageProcessingTransformer).
// The calls are declared here rather than through vips/vips.h, which needs GLib's include paths.
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
#else
#include <pthread.h>

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
