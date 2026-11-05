// Original (pre-epoch default) KotlinX memory manager (newkotlinc --gc=perceus; was --gc=default before epoch became the default): Perceus-style reference counting (fast paths
// inlined by the code generator) + a synchronous trial-deletion cycle collector (Bacon & Rajan 2001)
// over the tracing region.
//
// Only objects of possibly cyclic classes (on a field cycle with a `var` field; vtable->cyclic != NULL)
// take part. A decrement to a non-zero count makes the object a possible root: generated code colors it
// PURPLE and calls rt_cc_possible_root, which buffers it once. When the buffer reaches the adaptive
// threshold, and at program exit, the collector runs MarkRoots / ScanRoots / CollectRoots over all
// buffered roots in one pause. Everything else (acyclic classes, lists, maps, builders) is plain RC.
// ArrayList/HashMap fields are traversed from their owner while it holds the only reference (architecture.md §5).
// Docs: compiler/gc/docs/architecture.md.
#include <stdint.h>
#include <stdlib.h>
#include "../common/regions.inc"
#include "../common/object.inc"
#define CC_CLAIM_SKIPS_BUFFERED 1
#include "../common/trial_deletion.inc"

static PtrStack cc_roots;     /* buffered possible roots (each has the buffered bit set) */
static int cc_running;        /* re-entrancy guard: releases during a collection must not start another */
static KxGcStats gc_stats;

static void collect_cycles(void);

void rt_cc_possible_root(void *obj) {
    set_color(obj, PURPLE);
    if (is_buffered(obj)) return;
    set_buffered(obj);
    stack_push(&cc_roots, obj);
    if (cc_roots.len >= cc_threshold && !cc_running && !rt_rel_draining) collect_cycles();
}

/* Count reached zero and the children were released: free now, unless the root buffer still holds it
 * (then MarkRoots frees it when it takes it out of the buffer). */
void rt_cc_dead(void *obj) {
    set_color(obj, BLACK);
    if (!is_buffered(obj)) vtab(obj)->freemem(obj);
}

/* MarkRoots: keep the roots that are still PURPLE with a live count and mark-gray them. Every other root
 * leaves the buffer; if it died while buffered (BLACK, count 0) it is freed here. Returns the kept count. */
static size_t mark_roots(void **roots, size_t n) {
    size_t kept = 0;
    for (size_t i = 0; i < n; i++) {
        void *root = roots[i];
        if (color(root) == PURPLE && ref_count(root) > 0) { mark_gray(root); roots[kept++] = root; }
        else {
            clear_buffered(root);
            if (color(root) == BLACK && ref_count(root) == 0) vtab(root)->freemem(root);
        }
    }
    return kept;
}

/* Releases the acyclic children and untraced fields of all garbage, then frees it. Returns the number of
 * objects freed. */
static size_t free_garbage(void) {
    release_acyclic_children();
    for (size_t i = 0; i < cc_garbage.len; i++) vtab(cc_garbage.items[i])->relo(cc_garbage.items[i]);
    for (size_t i = 0; i < cc_garbage.len; i++) vtab(cc_garbage.items[i])->freemem(cc_garbage.items[i]);
    size_t freed = cc_garbage.len;
    cc_garbage.len = 0;
    return freed;
}

static void collect_cycles(void) {
    if (cc_running || cc_roots.len == 0) return;
    cc_running = 1;
    int64_t start = rt_nanos();
#ifdef RT_LEAKCHECK
    cc_runs++;
#endif
    PtrStack roots = cc_roots; cc_roots = (PtrStack){0};   /* new possible roots go to a fresh buffer */
    cc_traced = 0;
    roots.len = mark_roots(roots.items, roots.len);
    for (size_t i = 0; i < roots.len; i++) scan(roots.items[i]);    /* ScanRoots */
    for (size_t i = 0; i < roots.len; i++) {                       /* CollectRoots */
        clear_buffered(roots.items[i]);
        collect_white(roots.items[i]);
    }
    size_t reclaimed = free_garbage();
    free(roots.items);
    adapt_threshold(reclaimed);
    gc_stats.collections++;
    gc_stats.reclaimed += (int64_t)reclaimed;
    stats_add_pause(&gc_stats, rt_nanos() - start);
    cc_running = 0;
    if (cc_roots.len >= cc_threshold) collect_cycles();   /* freeing garbage buffered new roots */
}

/* Runs until the buffer is empty: freeing garbage can buffer the roots of garbage it alone kept reachable. */
void rt_gc_collect(void) { while (cc_roots.len && !cc_running) collect_cycles(); }
const char *rt_gc_name(void) { return "perceus"; }
void rt_gc_stats(KxGcStats *out) { *out = gc_stats; }
