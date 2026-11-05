// Plain reference counting without the cycle collector (newkotlinc --gc=rc). Same regions and fast paths as
// the default; possibly cyclic objects are freed only when their count reaches zero, so unreachable
// reference cycles leak. Exists to measure the collector's cost and to prove the GC interface is swappable.
#include "../common/regions.inc"

/* Never sets the buffered bit, so generated code frees every traced object at count zero. */
void rt_cc_possible_root(void *p) { (void)p; }
/* Count zero, fields already released: free immediately (vtable pointer is word 1, see kxgc.h). */
void rt_cc_dead(void *p) { (*(KxVTab **)((char *)p + 8))->freemem(p); }
void rt_gc_collect(void) {}
const char *rt_gc_name(void) { return "rc"; }
void rt_gc_stats(KxGcStats *out) { *out = (KxGcStats){0}; }
