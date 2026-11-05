/* Test-only shim for traversal.zig: includes the collector (as compiler/gc/tests/unit/traversal.c did) and
 * exports the internals the test inspects. Build with -DTEST_INCREMENTAL for the other consumer of
 * trial_deletion.inc. Contains no test logic. */
#ifdef TEST_INCREMENTAL
#include "../../../../incremental/gc.c"
#else
#include "../../../../perceus/gc.c"
#endif

uint64_t kxt_ref_count(void *p) { return ref_count(p); }
int kxt_color(void *p) { return color(p); }
int kxt_is_buffered(void *p) { return is_buffered(p); }
int kxt_black(void) { return BLACK; }
size_t kxt_work_cap(void) { return cc_work.cap; }
size_t kxt_initial_capacity(void) { return PTR_STACK_INITIAL_CAPACITY; }
