// Shared object regions for the reference-counting implementations (default, rc): included by exactly
// one gc.c. Defines rt_alloc / rt_free / rt_alloc_trace / rt_free_trace (kxgc.h).
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "kxgc.h"

// ---- object allocation: two regions ---------------------------------------
// The compiler classifies every class (NativeBackend.cyclic): a class whose instances can lie on a
// reference cycle (a field cycle containing a `var` field) is "possibly cyclic"; all others are acyclic.
//   * RC region (rt_alloc / rt_free): acyclic objects. Freed the instant their count hits zero,
//     never buffered, never traced (escape analysis puts non-escaping ones on the stack instead).
//   * Tracing region (rt_alloc_trace / rt_free_trace): possibly cyclic objects only. The cycle
//     collector below runs over this region alone; it never visits an RC-region object.
// Backing memory: RC region = the object allocator (mimalloc by default, malloc, or the pool);
// tracing region = its own size-class slabs (64 KiB), so traced objects stay dense and apart from
// short-lived acyclic ones. With --alloc malloc (ASan / macOS leaks builds) both regions use malloc
// so the tools see every object.
// --leak-check (RT_LEAKCHECK) prefixes each object with a region tag and counts, per region,
// allocations and collector visits; any collector visit outside the tracing region fails the run.

#ifdef RT_LEAKCHECK
enum { RG_RC = 0x5243 /* "RC" */, RG_TRACE = 0x5452 /* "TR" */ };
/* Index into rg_alloc / rg_free. */
enum { RG_INDEX_RC = 0, RG_INDEX_TRACE = 1 };
static int64_t rg_alloc[2], rg_free[2], cc_visits, cc_visits_outside, cc_runs;
#define RG_PREFIX 16 /* tag word + padding, keeps 16-byte alignment */
static void *rg_tag(void *raw, int64_t tag) { if (!raw) rt_panic("OutOfMemoryError"); *(int64_t *)raw = tag; return (char *)raw + RG_PREFIX; }
static void *rg_raw(void *p, int64_t tag) {
    char *raw = (char *)p - RG_PREFIX;
    if (*(int64_t *)raw != tag) { fprintf(stderr, "region: object %p freed into the wrong region\n", p); abort(); }
    *(int64_t *)raw = 0; return raw;
}
static int rg_is_trace(void *p) { return *(int64_t *)((char *)p - RG_PREFIX) == RG_TRACE; }
__attribute__((destructor(200))) static void rt_region_report(void) {
    fprintf(stderr, "region: rc allocated=%lld freed=%lld traced=0\n", (long long)rg_alloc[RG_INDEX_RC], (long long)rg_free[RG_INDEX_RC]);
    fprintf(stderr, "region: trace allocated=%lld freed=%lld\n", (long long)rg_alloc[RG_INDEX_TRACE], (long long)rg_free[RG_INDEX_TRACE]);
    fprintf(stderr, "region: collector runs=%lld visits=%lld outside-trace=%lld\n", (long long)cc_runs, (long long)cc_visits, (long long)cc_visits_outside);
    if (cc_visits_outside) { fprintf(stderr, "region: FAIL collector touched RC-region objects\n"); fflush(stderr); _exit(4); }
}
void *rt_alloc(int64_t size) { rt_leak_obj(1); rg_alloc[RG_INDEX_RC]++; return rg_tag(malloc((size_t)size + RG_PREFIX), RG_RC); }
void rt_free(void *p, int64_t size) { (void)size; rt_leak_obj(-1); rg_free[RG_INDEX_RC]++; free(rg_raw(p, RG_RC)); }
void *rt_alloc_trace(int64_t size) { rt_leak_obj(1); rg_alloc[RG_INDEX_TRACE]++; return rg_tag(malloc((size_t)size + RG_PREFIX), RG_TRACE); }
void rt_free_trace(void *p, int64_t size) { (void)size; rt_leak_obj(-1); rg_free[RG_INDEX_TRACE]++; free(rg_raw(p, RG_TRACE)); }
#define CC_VISIT(p) do { cc_visits++; if (!rg_is_trace(p)) cc_visits_outside++; } while (0)
#else
#define CC_VISIT(p) ((void)0)

/* Size-class slab pool (8-byte classes up to RT_CLASSES*8 bytes, 64 KiB slabs, larger -> malloc). */
#define RT_CLASSES 32
#define RT_SIZE_CLASS_SHIFT 3            /* 8-byte granularity */
#define RT_SLAB_BYTES (1 << 16)          /* 64 KiB bump-allocated slab */
/* Free list per size class (singly linked through the first word of each free block) + current slab.
 * Freed blocks are never returned to malloc; memory is reused only for the same size class. */
typedef struct { void *free_list[RT_CLASSES + 1]; char *ptr, *end; } Pool;
static inline void *pool_alloc(Pool *pl, int64_t size) {
    size_t cls = ((size_t)size + 7) >> RT_SIZE_CLASS_SHIFT;
    if (cls > RT_CLASSES) { void *q = malloc((size_t)size); if (!q) rt_panic("OutOfMemoryError"); return q; }
    void *p = pl->free_list[cls];
    if (p) { pl->free_list[cls] = *(void **)p; return p; }
    size_t bytes = cls << RT_SIZE_CLASS_SHIFT;
    if (pl->ptr + bytes > pl->end) {
        pl->ptr = malloc(RT_SLAB_BYTES);   /* the tail of the old slab is abandoned */
        if (!pl->ptr) rt_panic("OutOfMemoryError");
        pl->end = pl->ptr + RT_SLAB_BYTES;
    }
    p = pl->ptr; pl->ptr += bytes;
    return p;
}
static inline void pool_free(Pool *pl, void *p, int64_t size) {
    size_t cls = ((size_t)size + 7) >> RT_SIZE_CLASS_SHIFT;
    if (cls > RT_CLASSES) { free(p); return; }
    *(void **)p = pl->free_list[cls];
    pl->free_list[cls] = p;
}

#ifdef RT_POOL
static Pool rc_pool;
void *rt_alloc(int64_t size) { return pool_alloc(&rc_pool, size); }
void rt_free(void *p, int64_t size) { pool_free(&rc_pool, p, size); }
#else
void *rt_alloc(int64_t size) { void *p = malloc((size_t)size); if (!p) rt_panic("OutOfMemoryError"); return p; }
void rt_free(void *p, int64_t size) { (void)size; free(p); }
#endif

#ifdef RT_PLAIN_MALLOC
void *rt_alloc_trace(int64_t size) { return rt_alloc(size); }
void rt_free_trace(void *p, int64_t size) { rt_free(p, size); }
#else
static Pool trace_pool;
void *rt_alloc_trace(int64_t size) { return pool_alloc(&trace_pool, size); }
void rt_free_trace(void *p, int64_t size) { pool_free(&trace_pool, p, size); }
#endif
#endif

/* Runtime storage that may hold references: plain malloc for the RC implementations. */
void *rt_gc_mem_alloc(size_t n) { void *p = malloc(n); if (!p && n) rt_panic("OutOfMemoryError"); return p; }
void *rt_gc_mem_calloc(size_t n) { void *p = calloc(1, n); if (!p && n) rt_panic("OutOfMemoryError"); return p; }
void *rt_gc_mem_realloc(void *p, size_t n) { p = realloc(p, n); if (!p && n) rt_panic("OutOfMemoryError"); return p; }
void rt_gc_mem_free(void *p) { free(p); }

/* Deferred-RC hooks (kxgc.h): never called for this implementation (its caps do not list "deferred"). */
void rt_gc_log_inc(void *p) { (void)p; rt_panic("rt_gc_log_inc without deferred RC"); }
void rt_gc_log_dec(void *p) { (void)p; rt_panic("rt_gc_log_dec without deferred RC"); }
void rt_gc_write_barrier(void *obj) { (void)obj; }
void rt_gc_root_hint(void *p) { if (*(uint64_t *)p & KX_CNT_MASK) rt_cc_possible_root(p); }
void rt_gc_free_later(void *p) { (void)p; rt_panic("rt_gc_free_later without deferred RC"); }
