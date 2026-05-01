/* Memory + error stubs for the wimlib lzx_compress slice we vendor.
 *
 * wimlib's full library has its own malloc/error machinery
 * (wimlib_malloc, ERROR(), etc.). We pull in only the LZX encoder
 * source, so we satisfy the symbols it actually references with thin
 * stdlib-backed shims. Keeps vendor/wimlib pristine. */

#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

void *wimlib_malloc(size_t size) { return malloc(size); }
void  wimlib_free_memory(void *p) { free(p); }
void *wimlib_realloc(void *p, size_t size) { return realloc(p, size); }
void *wimlib_calloc(size_t nmemb, size_t size) { return calloc(nmemb, size); }
char *wimlib_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = (char *)malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

#if defined(_WIN32)
void *wimlib_aligned_malloc(size_t size, size_t alignment) {
    return _aligned_malloc(size, alignment);
}
void wimlib_aligned_free(void *p) { _aligned_free(p); }
#else
void *wimlib_aligned_malloc(size_t size, size_t alignment) {
    void *p = NULL;
    if (alignment < sizeof(void *)) alignment = sizeof(void *);
    if (posix_memalign(&p, alignment, size) != 0) return NULL;
    return p;
}
void wimlib_aligned_free(void *p) { free(p); }
#endif

/* wimlib's error machinery — silence everything; the encoder's own
 * return codes are what we propagate to Nim. */
int wimlib_print_errors = 0;
FILE *wimlib_error_file = NULL;

void wimlib_error(const char *format, ...) { (void)format; }
void wimlib_error_with_errno(const char *format, ...) { (void)format; }
void wimlib_warning(const char *format, ...) { (void)format; }
void wimlib_warning_with_errno(const char *format, ...) { (void)format; }
