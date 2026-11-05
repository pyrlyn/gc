// Field publication for src/unit/mt_test.zig, compiled with the collector's flags (incl. -fsanitize=thread)
// so ThreadSanitizer sees the release / acquire pairs that generated code compiled by clang would have.
// (The Zig object is not instrumented: without this, every new object linked into a traced field would be
// reported as a race between its initialization and the collector's first visit.) No test logic here.
#include <stdint.h>
void mt_init(uint64_t *o, void *vt, uint64_t magic, int64_t val) {
    o[0] = 1; o[1] = (uint64_t)(uintptr_t)vt; o[2] = 0; o[3] = magic; o[4] = (uint64_t)val; o[5] = 0; o[6] = 0;
}
void mt_store(void **field, void *v) { __atomic_store_n(field, v, __ATOMIC_RELEASE); }
void *mt_load(void **field) { return __atomic_load_n(field, __ATOMIC_ACQUIRE); }
