// Epoch-based GC (newkotlinc --gc=epoch): deferred RC + concurrent cycle collection on a background thread
// (Bacon, Attanasio, Lee, Rajan, Smith: "Java without the Coffee Breaks" / Bacon & Rajan, "Concurrent Cycle
// Collection in Reference Counted Systems", 2001), adapted to KotlinX.
//
// Mutator (the program thread):
//   * Acyclic objects: unchanged inline RC (Perceus), freed immediately.
//   * Traced (possibly cyclic) objects: generated code never touches their header after initialization.
//     Retain/release append (pointer | op) to the current epoch log (rt_gc_log_inc / rt_gc_log_dec); a
//     reference store into a traced object's field is a release store followed by rt_gc_write_barrier,
//     which logs the object as modified. A release that leaves an ArrayList/HashMap with one reference logs
//     the object holding it as a possible root (rt_gc_root_hint, applied with the decrements).
//   * Epoch boundary (log full: log_cap entries, adaptive LOG_MIN..LOG_CAP): the log is handed to the collector (one mutex
//     round-trip) and the mutator frees objects the collector found dead, under a time budget
//     (KX_GC_FREE_BUDGET_US, default half of KX_GC_TARGET_PAUSE_US) only beyond a backlog of KX_GC_BOUNDARY_KEEP
//     objects; the rest is freed by traced allocations (paced by the backlog). The boundary is the only pause; it blocks only if the
//     collector falls more than KX_GC_MAX_QUEUED (adaptive 2-16 by default) logs behind (back-pressure).
// Collector (background thread), per log, in order:
//   1. apply all increments, then all decrements (the mutator is single-threaded, so no count drops to
//      zero early); every touched object is marked dirty. Count zero -> dead: decrement its traced children
//      and return it to the mutator (which releases its acyclic fields and frees the memory). Non-zero ->
//      purple candidate root.
//   2. when the root buffer is large: concurrent trial deletion (MarkGray / Scan / CollectWhite) on a
//      separate cyclic count (CRC, header bits 40-63), so real counts are never disturbed while the
//      mutator keeps running; each white component becomes a candidate cycle.
//   3. a candidate cycle gets the Sigma test when detection ends (sum of member counts minus
//      member-to-member edges is zero: no external references) and the Delta test after the next log whose
//      hand-off happened after that (no member was touched by any RC operation or write barrier since
//      detection). Passing cycles are freed (traced children outside the cycle decremented, members
//      returned to the mutator); failing members go back to the root buffer.
// Traced objects live in 64 KiB-aligned size-class slabs registered in a page bitmap, so the
// collector recognizes traced pointers without dereferencing (acyclic objects may be freed concurrently).
// Generations: objects found externally referenced by a scan become stable (old) until decremented; minor
// detections do not trace them, major detections (amortized against the stable population, with a
// geometric backoff while majors find no garbage) do.
// Trial deletion's MarkGray/Scan (minor and one-pass major detections) run in parallel on KX_GC_THREADS
// threads whenever a runtime cost model predicts it is faster: expected visits (roots x visits per root) x
// measured serial ns per visit against expected visits x measured parallel ns per visit plus the measured
// cost of waking the helpers. No tuning thresholds. (The incremental major traces on one thread.)
// Bounded slices: a minor detection takes at most KX_GC_SLICE_ROOTS roots, validation at most
// VALIDATE_BUDGET members per log; the leftovers carry over to the next log. Opt-in experiments:
// KX_GC_CARRY_QUEUE=n skips detection while n logs are queued, KX_GC_MAJOR_SLACK=k lets the queue grow
// k-fold during a major (both measured worse, see bench/results/gc/exp/combined).
// Program exit drains the queue only for --leak-check / --alloc malloc builds or KX_GC_EXIT_DRAIN=1.
// See compiler/gc/docs/architecture.md, section 7.
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "kxgc.h"

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#include <sanitizer/asan_interface.h>
#define POISON(p, n) ASAN_POISON_MEMORY_REGION(p, n)
#define UNPOISON(p, n) ASAN_UNPOISON_MEMORY_REGION(p, n)
#endif
#endif
#ifndef POISON
#define POISON(p, n) ((void)0)
#define UNPOISON(p, n) ((void)0)
#endif

#include "../common/object.inc"

// ---- statistics / leak check ----
static KxGcStats gc_st;
static int64_t ep_epochs, ep_detections;
#ifdef RT_LEAKCHECK
static int64_t rg_alloc[2], rg_free[2], cc_visits;
__attribute__((destructor(200))) static void rt_region_report(void) {
    fprintf(stderr, "region: rc allocated=%lld freed=%lld traced=0\n", (long long)rg_alloc[0], (long long)rg_free[0]);
    fprintf(stderr, "region: trace allocated=%lld freed=%lld\n", (long long)rg_alloc[1], (long long)rg_free[1]);
    fprintf(stderr, "region: collector runs=%lld visits=%lld outside-trace=0\n", (long long)ep_detections, (long long)cc_visits);
}
#define LEAK(d) rt_leak_obj(d)
#define VISIT() __atomic_fetch_add(&cc_visits, 1, __ATOMIC_RELAXED)
#else
#define LEAK(d) ((void)0)
#define VISIT() ((void)0)
#endif

// ---- acyclic objects: plain allocator (mimalloc / malloc) ----
void *rt_alloc(int64_t size) {
    void *p = malloc((size_t)size); if (!p) rt_panic("OutOfMemoryError");
    LEAK(1);
#ifdef RT_LEAKCHECK
    rg_alloc[0]++;
#endif
    return p;
}
void rt_free(void *p, int64_t size) {
    (void)size; LEAK(-1);
#ifdef RT_LEAKCHECK
    rg_free[0]++;
#endif
    free(p);
}
void *rt_gc_mem_alloc(size_t n) { void *p = malloc(n); if (!p && n) rt_panic("OutOfMemoryError"); return p; }
void *rt_gc_mem_calloc(size_t n) { void *p = calloc(1, n); if (!p && n) rt_panic("OutOfMemoryError"); return p; }
void *rt_gc_mem_realloc(void *p, size_t n) { p = realloc(p, n); if (!p && n) rt_panic("OutOfMemoryError"); return p; }
void rt_gc_mem_free(void *p) { free(p); }

// ---- traced objects: 64 KiB-aligned slabs + page bitmap ----
#define PAGE_SHIFT 16
#define PAGE (1u << PAGE_SHIFT)
/* Page bitmap: one bit per 64 KiB page of the 47-bit address space (256 MiB of virtual memory,
 * reserved lazily; only the pages covering the heap are ever touched). Never dereferences p. */
#define PAGE_BITS_LOG 31
static _Atomic uint64_t *page_bits;
static void reg_add(uintptr_t addr) {
    uintptr_t pg = addr >> PAGE_SHIFT;
    if (pg >> PAGE_BITS_LOG) rt_panic("epoch GC: heap address outside the page bitmap");
    atomic_fetch_or_explicit(&page_bits[pg >> 6], 1ULL << (pg & 63), memory_order_release);
}
static inline int is_traced(void *p) {
    uintptr_t pg = (uintptr_t)p >> PAGE_SHIFT;
    if (!p || (pg >> PAGE_BITS_LOG) || !page_bits) return 0;
    return (atomic_load_explicit(&page_bits[pg >> 6], memory_order_acquire) >> (pg & 63)) & 1;
}
#define CLASSES 32
static void *free_list[CLASSES + 1];
static char *bump, *bump_end;
typedef struct Big { struct Big *next; size_t size; } Big;
static Big *big_free;
#define SLAB_CHUNK (2u << 20)
static int64_t dbg_slab_bytes, dbg_log_allocs, dbg_batch_bytes, dbg_batch_peak;
/* Base address of every slab chunk / big block. The allocator never frees them, and after the cells were
 * handed out the only pointers left may be interior ones (free-list links, bump), so without this list
 * macOS `leaks` intermittently reported a malloc'd slab as a ROOT LEAK (depending on free order, i.e. on
 * collector timing). Written by the mutator only (page_alloc). */
static PtrStack slab_bases;
static _Atomic int64_t t_allocs, t_frees;   /* traced objects allocated / freed (mutator-written; debug) */
static void *page_alloc(size_t bytes) {
    void *p = NULL; dbg_slab_bytes += (int64_t)bytes;
    if (!page_bits) {
        page_bits = mmap(NULL, (1ULL << PAGE_BITS_LOG) / 8, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
        if (page_bits == MAP_FAILED) rt_panic("OutOfMemoryError");
    }
    if (bytes == PAGE) {   /* small-object slabs: carved from 2 MiB mmap chunks (no per-slab malloc header or alignment slack) */
        static char *ch, *ch_end;
        if (ch == ch_end) {
            size_t want = SLAB_CHUNK + PAGE;
            char *m = mmap(NULL, want, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (m == MAP_FAILED) rt_panic("OutOfMemoryError");
            char *a = (char *)(((uintptr_t)m + PAGE - 1) & ~(uintptr_t)(PAGE - 1));
            if (a > m) munmap(m, (size_t)(a - m));
            if (a + SLAB_CHUNK < m + want) munmap(a + SLAB_CHUNK, (size_t)(m + want - (a + SLAB_CHUNK)));
            ch = a; ch_end = a + SLAB_CHUNK; stack_push(&slab_bases, a);
        }
        p = ch; ch += PAGE;
    } else { if (posix_memalign(&p, PAGE, bytes)) rt_panic("OutOfMemoryError"); stack_push(&slab_bases, p); }
    for (size_t o = 0; o < bytes; o += PAGE) reg_add((uintptr_t)p + o);
    return p;
}
// ---- per-slab bookkeeping: empty small-object slabs go back to the OS (KX_GC_SLAB_RELEASE, default 1) ----
/* Every small-object slab (one 64 KiB page) holds cells of one size class and has a side descriptor
 * (never inside the slab, so a released slab has no resident page left): its own free list, bump pointer
 * and live-cell count. A class allocates from its current slab, then from its partial slabs (some cells
 * free), then from the pool of empty slabs, then from a fresh page. A slab whose last cell is freed (and
 * that is not its class's current slab) leaves the partial list and waits on slab_pending; the next epoch
 * boundary moves it to the pool, keeping SLAB_RESIDENT_KEEP of them resident and madvising the rest
 * (adjacent slabs coalesced into one call). A released slab faults in zero pages when it is reused.
 * Only the mutator allocates and frees traced memory, so none of this needs a lock.
 * KX_GC_SLAB_RELEASE=0: the previous allocator (global per-class free lists, one shared bump slab). */
typedef struct Slab { struct Slab *next, *prev; void *free; char *base, *bump; uint32_t live; uint16_t cls; uint8_t in_partial, resident; } Slab;
#define SLAB_DIR_TOP (1u << (PAGE_BITS_LOG - 16))
static Slab **slab_dir[SLAB_DIR_TOP];
static Slab *slab_cur[CLASSES + 1], *slab_partial[CLASSES + 1], *slab_pool;
static PtrStack slab_pending;
static int slab_release = -1;
#define SLAB_RESIDENT_KEEP 16   /* empty slabs kept resident in the pool (no madvise / refault churn); KX_GC_SLAB_KEEP */
static int64_t slab_keep = -1;
static int64_t slab_pool_resident, dbg_slab_released, dbg_slab_reused, dbg_slab_madv_calls;
static inline Slab *slab_of(void *p) {
    uintptr_t pg = (uintptr_t)p >> PAGE_SHIFT;
    Slab **d = slab_dir[pg >> 16];
    return d ? d[pg & 0xffff] : NULL;
}
static Slab *slab_new(void) {
    char *base = page_alloc(PAGE);
    uintptr_t pg = (uintptr_t)base >> PAGE_SHIFT;
    Slab **d = slab_dir[pg >> 16];
    if (!d) { d = slab_dir[pg >> 16] = calloc(1u << 16, sizeof(Slab *)); if (!d) rt_panic("OutOfMemoryError"); }
    Slab *s = calloc(1, sizeof *s); if (!s) rt_panic("OutOfMemoryError");
    s->base = base; s->resident = 1; d[pg & 0xffff] = s;
    return s;
}
static void partial_unlink(Slab *s, size_t cls) {
    if (s->prev) s->prev->next = s->next; else slab_partial[cls] = s->next;
    if (s->next) s->next->prev = s->prev;
    s->next = s->prev = NULL; s->in_partial = 0;
}
static __attribute__((noinline)) void *slab_refill(size_t cls) {
    Slab *s = slab_partial[cls];
    if (s) partial_unlink(s, cls);
    else if ((s = slab_pool)) {
        slab_pool = s->next; s->next = NULL; dbg_slab_reused++;
        if (s->resident) slab_pool_resident--;
        s->resident = 1; s->free = NULL; s->bump = s->base; s->live = 0;
        UNPOISON(s->base, PAGE);   /* bump-allocated again, possibly for another size class: old cell poison is stale */
    } else { s = slab_new(); s->bump = s->base; }
    s->cls = (uint16_t)cls; slab_cur[cls] = s;
    void *p;
    if (s->free) { p = s->free; UNPOISON(p, cls << 3); s->free = *(void **)p; }
    else { p = s->bump; s->bump += cls << 3; }
    s->live++;
    return p;
}
static inline void *slab_alloc(size_t cls) {
    Slab *s = slab_cur[cls];
    if (__builtin_expect(s != NULL, 1)) {
        void *p = s->free;
        if (p) { UNPOISON(p, cls << 3); s->free = *(void **)p; s->live++; return p; }
        if (s->bump + (cls << 3) <= s->base + PAGE) { p = s->bump; s->bump += cls << 3; s->live++; return p; }
    }
    return slab_refill(cls);
}
static inline void slab_free(void *p, size_t cls) {
    Slab *s = slab_of(p);
    *(void **)p = s->free; s->free = p;
    POISON((char *)p + 8, (cls << 3) - 8);
    if (s == slab_cur[cls]) { s->live--; return; }
    if (--s->live == 0) {
        if (s->in_partial) partial_unlink(s, cls);
        stack_push(&slab_pending, s);
    } else if (!s->in_partial) {
        s->in_partial = 1; s->prev = NULL; s->next = slab_partial[cls];
        if (s->next) s->next->prev = s; slab_partial[cls] = s;
    }
}
static int slab_cmp(const void *a, const void *b) { uintptr_t x = (uintptr_t)(*(Slab *const *)a)->base, y = (uintptr_t)(*(Slab *const *)b)->base; return x < y ? -1 : x > y; }
#ifdef MADV_FREE_REUSABLE
#define KX_MADV MADV_FREE_REUSABLE   /* macOS: leaves the resident set (and the footprint) at once */
#else
#define KX_MADV MADV_DONTNEED
#endif
/* Epoch boundary: empty slabs into the pool; beyond SLAB_RESIDENT_KEEP resident ones, back to the OS. */
static void slab_flush(void) {
    if (!slab_pending.len) return;
    if (slab_keep < 0) { const char *e = getenv("KX_GC_SLAB_KEEP"); slab_keep = e && *e ? atoll(e) : SLAB_RESIDENT_KEEP; if (slab_keep < 0) slab_keep = 0; }
    size_t n = 0;
    for (size_t i = 0; i < slab_pending.len; i++) {
        Slab *s = slab_pending.items[i];
        if (s->live || s == slab_cur[s->cls]) continue;   /* reused (became current, or a cell was taken) since */
        s->next = slab_pool; slab_pool = s;
        if (slab_pool_resident < slab_keep) { slab_pool_resident++; continue; }
        s->resident = 0; slab_pending.items[n++] = s;
    }
    if (n > 1) qsort(slab_pending.items, n, sizeof(void *), slab_cmp);
    for (size_t i = 0; i < n;) {
        size_t j = i + 1;
        while (j < n && ((Slab *)slab_pending.items[j])->base == ((Slab *)slab_pending.items[j - 1])->base + PAGE) j++;
        char *from = ((Slab *)slab_pending.items[i])->base;
        UNPOISON(from, (j - i) * PAGE);
        if (madvise(from, (j - i) * (size_t)PAGE, KX_MADV) == 0) dbg_slab_released += (int64_t)(j - i);
        dbg_slab_madv_calls++;
        i = j;
    }
    slab_pending.len = 0;
}
// ---- small vector ----
/* Moves every pointer of `from` onto `to`. */
static void stack_move(PtrStack *to, PtrStack *from) { for (size_t i = 0; i < from->len; i++) stack_push(to, from->items[i]); from->len = 0; }

static int64_t dbg_bp_ns, dbg_bp_max, dbg_exit_ns, dbg_bmax;
static PtrStack ret_local; static size_t ret_pos;       /* mutator: dead objects returned by the collector */
static int64_t dbg_paced, dbg_bfreed;                   /* objects freed by allocation pacing / at boundaries */
/* KX_GC_BOUNDARY_KEEP: returned objects a boundary leaves to allocation-paced freeing (it frees only the
 * excess, within the free budget). 0 = free everything at the boundary (the previous behavior). */
static int64_t boundary_keep = -1;
#define BOUNDARY_KEEP_DEFAULT 0   /* was 16384: a standing backlog of 16K dead objects freed by allocations cost
                                   * cycles 1.6-1.9x (183 -> 270-340 ms); the boundary budget already bounds the pause */
static void free_returned(void *p);
void *rt_alloc_trace(int64_t size) {
    atomic_store_explicit(&t_allocs, atomic_load_explicit(&t_allocs, memory_order_relaxed) + 1, memory_order_relaxed);
    /* Allocation-paced freeing: every traced allocation frees some returned dead objects, so reclamation
     * keeps pace with allocation without a pause. The rate grows with the backlog (2 per allocation, up to
     * 16 when more than 64K objects wait), so the backlog drains while the program allocates. */
    if (ret_pos < ret_local.len) {
        size_t back = ret_local.len - ret_pos;
        int k = back > 65536 ? 16 : back > 16384 ? 8 : back > 4096 ? 4 : 2;
        for (; k > 0 && ret_pos < ret_local.len; k--) { free_returned(ret_local.items[ret_pos++]); dbg_paced++; }
        if (ret_pos == ret_local.len) { ret_local.len = 0; ret_pos = 0; }
    }
    LEAK(1);
#ifdef RT_LEAKCHECK
    rg_alloc[1]++;
#endif
    size_t cls = ((size_t)size + 7) >> 3;
    void *p;
    if (cls > CLASSES) {
        size_t bytes = ((size_t)size + PAGE - 1) & ~(size_t)(PAGE - 1);
        for (Big **b = &big_free; *b; b = &(*b)->next) if ((*b)->size == bytes) { p = *b; *b = (*b)->next; UNPOISON(p, bytes); return p; }
        return page_alloc(bytes);
    }
    if (__builtin_expect(slab_release < 0, 0)) { const char *e = getenv("KX_GC_SLAB_RELEASE"); slab_release = !(e && *e == '0'); }
    if (slab_release) return slab_alloc(cls);
    p = free_list[cls];
    if (p) { UNPOISON(p, cls << 3); free_list[cls] = *(void **)p; return p; }
    if (bump + (cls << 3) > bump_end) { bump = page_alloc(PAGE); bump_end = bump + PAGE; }
    p = bump; bump += cls << 3;
    return p;
}
/* madvise for freed big blocks: everything after the first OS page (which holds the Big free-list link) is
 * handed back with MADV_FREE, so peak RSS drops while the block waits for reuse; a reused block's contents
 * are undefined anyway. KX_GC_MADVISE=0 disables it. Empty small-object slabs: see slab_flush. */
static int64_t dbg_madvised;
static void big_release(void *p, size_t bytes) {
    static long os_page; static int enabled = -1;
    if (enabled < 0) { const char *e = getenv("KX_GC_MADVISE"); enabled = !(e && *e == '0'); os_page = sysconf(_SC_PAGESIZE); }
    if (!enabled || os_page <= 0 || bytes < 2 * (size_t)os_page) return;
    char *from = (char *)p + os_page; size_t len = bytes - (size_t)os_page;
    if (madvise(from, len, KX_MADV) == 0) dbg_madvised += (int64_t)len;
}
/* An empty collector stack above STACK_RELEASE_MIN bytes gives its pages back (capacity is kept, the pages
 * fault in again on the next use); the huge_live_churn major left 380 MiB of such stacks resident. */
#define STACK_RELEASE_MIN (1u << 20)
static int64_t dbg_stack_released;
static void stack_release(PtrStack *st) {
    static long os_page;
    if (!os_page) os_page = sysconf(_SC_PAGESIZE);
    if (st->len || st->cap * sizeof(void *) < STACK_RELEASE_MIN || os_page <= 0) return;
    uintptr_t a = ((uintptr_t)st->items + (uintptr_t)os_page - 1) & ~(uintptr_t)(os_page - 1);
    uintptr_t e = ((uintptr_t)(st->items + st->cap)) & ~(uintptr_t)(os_page - 1);
    if (e > a && madvise((void *)a, e - a, KX_MADV) == 0) dbg_stack_released += (int64_t)(e - a);
}
void rt_free_trace(void *p, int64_t size) {
    atomic_store_explicit(&t_frees, atomic_load_explicit(&t_frees, memory_order_relaxed) + 1, memory_order_relaxed);
    LEAK(-1);
#ifdef RT_LEAKCHECK
    rg_free[1]++;
#endif
    size_t cls = ((size_t)size + 7) >> 3;
    if (cls > CLASSES) {
        size_t bytes = ((size_t)size + PAGE - 1) & ~(size_t)(PAGE - 1);
        Big *b = p; b->size = bytes; b->next = big_free; big_free = b; POISON((char *)p + sizeof(Big), bytes - sizeof(Big));
        big_release(p, bytes);
        return;
    }
    if (slab_release > 0) { slab_free(p, cls); return; }
    *(void **)p = free_list[cls]; free_list[cls] = p;
    POISON((char *)p + 8, (cls << 3) - 8);
}
/* Not used with deferred RC (generated code logs instead). */
void rt_cc_possible_root(void *p) { (void)p; rt_panic("epoch GC: rt_cc_possible_root"); }
void rt_cc_dead(void *p) { (void)p; rt_panic("epoch GC: rt_cc_dead"); }

// ---- epoch logs, hand-off ----
#define LOG_CAP 32768
#define MAX_QUEUED_DEFAULT 16   /* logs (256 KiB each) the collector may fall behind; KX_GC_MAX_QUEUED */
static size_t max_queued;
/* Effective log capacity (entries before a hand-off). Everything the collector has not yet confirmed dead
 * waits for a few logs (the one being filled, the queue, the one being applied, the one a candidate set's
 * Delta test waits for), so peak garbage in flight is a small multiple of the log size: with 32K-entry logs
 * that was ~350K unfreed cyclic objects (23 MiB peak RSS on cyclic_garbage vs 3.4 for Boehm). The log
 * capacity therefore follows the detection threshold: LOG_MIN while detections keep finding garbage (the
 * threshold stays at its minimum), growing with it (LOG_PER_ROOT entries per threshold root, up to LOG_CAP)
 * when detections mostly retrace live data and the per-log overhead would dominate. KX_GC_LOG_CAP fixes it. */
#define LOG_MIN 2048
#define LOG_PER_ROOT 4
static _Atomic size_t log_cap = 512;   /* LOG_FLOOR_DEFAULT; written by the collector, read (relaxed) by the mutator */
static int log_cap_fixed;
static _Atomic size_t log_boost = 1;   /* hand-off back-pressure multiplier on the log size, see handoff() */
/* Minor detection threshold (buffered roots), adaptive between c_min_threshold (KX_GC_MIN_THRESHOLD)
 * and C_MAX_THRESHOLD; was a fixed 10000 minimum, i.e. at least ~1 large log of cyclic garbage per detection. */
static size_t c_threshold = LOG_MIN / LOG_PER_ROOT, c_min_threshold = LOG_MIN / LOG_PER_ROOT;
/* While detections run at the minimum threshold (pure garbage, every detection pays off) and the hand-off sees
 * no back-pressure, logs are cut at log_floor entries: less garbage waits in flight (cyclic_garbage peak RSS
 * 5.2 -> 3.7 MiB under load). As soon as the threshold grows or back-pressure boosts the log size, the
 * normal LOG_MIN.. sizing applies, so live-heap workloads keep long logs. KX_GC_LOG_FLOOR overrides it. */
#define LOG_FLOOR_DEFAULT 512
static size_t log_floor = LOG_FLOOR_DEFAULT;
static int c_pure = 0;   /* the last minor detection traced (almost) only garbage: work <= KX_GC_PURE_RATIO (default 1) x found; keeps live-heap churn (LRU) on normal logs */
static int64_t pure_ratio = 1;
/* KX_GC_PURE_NOBOOST (default 1): no back-pressure log boost while detections find only garbage. Longer logs
 * only hold more garbage in flight there (cyclic_garbage peaked with 16x logs, 32K entries each, under load). */
static int pure_noboost = 1;
#define PURE_STABLE_MAX 65536   /* and the old generation is small (no live heap to keep pace with, unlike LRU churn) */
static void log_cap_follow(void) {
    if (log_cap_fixed) return;
    size_t boost = atomic_load_explicit(&log_boost, memory_order_relaxed);
    size_t c = c_threshold * LOG_PER_ROOT, b = LOG_MIN * boost;
    if (c < b) c = b; if (c > LOG_CAP) c = LOG_CAP;
    if (c_pure && c_threshold <= c_min_threshold && boost == 1 && log_floor < c) c = log_floor;
    atomic_store_explicit(&log_cap, c, memory_order_relaxed);
}
#define Q_ADAPT_START 4
#define Q_ADAPT_MIN 2
#define Q_ADAPT_MAX 16   /* was 64: a starved collector (busy machine) doubled it to 64 within a few hand-offs; 64 queued
                          * logs are 16 MiB of logs plus the garbage they hold back, and exceed the early-validation
                          * scan (EARLY_SCAN_MAX = 32 logs), so every candidate also waited for the whole queue:
                          * 2x peak RSS on live_heap_churn (78 vs 36 MiB) in about 1 run of 6 under load */
#define Q_ADAPT_COOL 16  /* hand-offs between two doublings */
#define Q_ADAPT_WINDOW 64
static int q_fixed, q_win, q_win_bad, q_cool, pool_len;   /* guarded by mu */
static int64_t q_target_ns; static size_t dbg_q_max;
static int major_slack = -1;          /* KX_GC_MAJOR_SLACK: queue limit multiplier while a major runs (default 1: off; measured: the mutator fills any slack within a major) */
static _Atomic int c_in_major;         /* collector is in a major detection */
enum { OP_INC = 0, OP_DEC = 1, OP_MOD = 2, OP_ROOT = 3 };   /* OP_ROOT: rt_gc_root_hint */
/* frees: runtime memory the mutator released while the collector could still read it (rt_gc_free_later) */
typedef struct Log { struct Log *next; size_t n; uint64_t seq; PtrStack frees; uintptr_t a[LOG_CAP]; } Log;
static Log *cur;                                   /* mutator */
static Log *q_head, *q_tail, *log_pool;            /* guarded by mu */
static size_t q_len;
static uint64_t handed, applied;                   /* guarded by mu */
static uint64_t m_applied;                         /* mutator: `applied` as of its last look under mu */
static PtrStack ret_shared;                             /* dead objects for the mutator, guarded by mu */
static int full_req, coll_quiet, shutting;         /* guarded by mu */
static uint64_t full_done;
/* KX_GC_LOCK_CHECK (test builds, src/unit/mt_test.zig): error-checking mutexes, and every lock, unlock and
 * wait on them aborts on failure, so a lock that is missing (unlock or wait by a thread that does not hold it)
 * fails the test in plain builds too, not only under TSan. */
#ifdef KX_GC_LOCK_CHECK
#ifdef __APPLE__
#define KX_MU_INIT PTHREAD_ERRORCHECK_MUTEX_INITIALIZER
#else
#define KX_MU_INIT PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP
#endif
static int kx_lock_ok(int r, const char *what) {
    if (r) { fprintf(stderr, "epoch: KX_GC_LOCK_CHECK: %s failed (%d)\n", what, r); abort(); }
    return 0;
}
#define pthread_mutex_lock(m) kx_lock_ok(pthread_mutex_lock(m), "pthread_mutex_lock")
#define pthread_mutex_unlock(m) kx_lock_ok(pthread_mutex_unlock(m), "pthread_mutex_unlock")
#define pthread_cond_wait(c, m) kx_lock_ok(pthread_cond_wait(c, m), "pthread_cond_wait")
#else
#define KX_MU_INIT PTHREAD_MUTEX_INITIALIZER
#endif
static pthread_mutex_t mu = KX_MU_INIT;
static pthread_cond_t cv_work = PTHREAD_COND_INITIALIZER, cv_done = PTHREAD_COND_INITIALIZER;
static pthread_t coll_thread;
static int coll_started;
static int in_boundary;
/* KX_GC_FREE_BUDGET_US: freeing budget per boundary, default half the target pause (measured: 200 us let
 * returned garbage pile up, 3x peak RSS on cyclic_garbage; freeing only beyond a backlog of LOG_CAP
 * objects kept 1.4x of it). The boundary still ends by the target pause. */
static int64_t free_budget_ns = -1;
#define FREE_BUDGET_MIN_NS 200000

static void *collector_main(void *);
static Log *log_new(void) {
    Log *l = log_pool;
    if (l) { log_pool = l->next; pool_len--; } else { dbg_log_allocs++; l = malloc(sizeof *l); if (!l) rt_panic("OutOfMemoryError"); l->frees = (PtrStack){0}; }
    l->n = 0; l->next = NULL; return l;
}
/* Hands the current log to the collector; takes the dead objects it returned. Caller holds no lock. */
static void handoff(void) {
    pthread_mutex_lock(&mu);
    if (!coll_started) {
        coll_started = 1;
        if (pthread_create(&coll_thread, NULL, collector_main, NULL)) rt_panic("epoch GC: cannot start the collector thread");
    }
    if (cur && (cur->n || cur->frees.len)) {
        cur->seq = ++handed;
        if (q_tail) q_tail->next = cur; else q_head = cur;
        q_tail = cur; q_len++;
        cur = NULL;
        pthread_cond_signal(&cv_work);
    }
    if (!max_queued) {
        const char *e = getenv("KX_GC_MAX_QUEUED");
        if (e && atoi(e) > 0) { max_queued = (size_t)atoi(e); q_fixed = 1; } else max_queued = Q_ADAPT_START;
        e = getenv("KX_GC_TARGET_PAUSE_US"); q_target_ns = (e && *e ? atoll(e) : 3000) * 1000;   /* KX_GC_TARGET_PAUSE_US, default 3 ms */
    }
    if (major_slack < 0) { const char *e = getenv("KX_GC_MAJOR_SLACK"); major_slack = e && *e ? atoi(e) : 1; if (major_slack < 1) major_slack = 1; }
    /* a major detection is one long collector step: let the queue grow (bounded) instead of stopping the
     * mutator; the backlog is carried over, and the raised limit stays until it is back under max_queued,
     * so the mutator never waits for the whole backlog at once */
#define Q_LIMIT() (atomic_load_explicit(&c_in_major, memory_order_relaxed) ? max_queued * (size_t)major_slack : max_queued)
    int64_t d = 0;
    if (q_len > Q_LIMIT()) { int64_t w0 = rt_nanos(); while (q_len > Q_LIMIT()) pthread_cond_wait(&cv_done, &mu); d = rt_nanos() - w0; dbg_bp_ns += d; if (d > dbg_bp_max) dbg_bp_max = d; }
    /* Adaptive queue depth (unless KX_GC_MAX_QUEUED is set): a back-pressure wait longer than the pause
     * target doubles the limit (up to Q_ADAPT_MAX, at most once per Q_ADAPT_COOL hand-offs); a window of
     * Q_ADAPT_WINDOW hand-offs with no wait over a quarter of the target and the queue never past half the
     * limit halves it (down to Q_ADAPT_MIN).
     * A short queue means garbage is confirmed and returned sooner (lower RSS); a long one absorbs collector
     * spikes (lower pauses). */
    if (!q_fixed) {
        if (q_cool) q_cool--;
        /* once the queue is at its maximum depth, collector spikes are absorbed by longer logs instead (the
         * queue limit counts logs, and short logs hold little): log_boost doubles the log size, and a calm
         * window halves it again before the queue depth shrinks. Pure cyclic garbage never waits that long,
         * so it keeps short logs and little garbage in flight. */
        if (d > q_target_ns && !q_cool) {
            if (max_queued >= Q_ADAPT_MAX && !log_cap_fixed && !(c_pure && pure_noboost) && LOG_MIN * atomic_load_explicit(&log_boost, memory_order_relaxed) < LOG_CAP) { atomic_fetch_add(&log_boost, atomic_load(&log_boost)); log_cap_follow(); }
            if (max_queued < Q_ADAPT_MAX) max_queued *= 2; if (max_queued > Q_ADAPT_MAX) max_queued = Q_ADAPT_MAX; q_win = 0; q_win_bad = 0; q_cool = Q_ADAPT_COOL; }
        else if (d > q_target_ns) q_win_bad = 1;
        else {
            if (d > q_target_ns / 4 || q_len * 2 > max_queued) q_win_bad = 1;
            if (++q_win >= Q_ADAPT_WINDOW && !q_win_bad && atomic_load(&log_boost) > 1) { atomic_store(&log_boost, atomic_load(&log_boost) / 2); log_cap_follow(); q_win = 0; }
            else if (q_win >= Q_ADAPT_WINDOW) { if (!q_win_bad && max_queued > Q_ADAPT_MIN) max_queued = max_queued / 2 > Q_ADAPT_MIN ? max_queued / 2 : Q_ADAPT_MIN; q_win = 0; q_win_bad = 0; }
        }
        if (max_queued > dbg_q_max) dbg_q_max = max_queued;
    }
    stack_move(&ret_local, &ret_shared);
    m_applied = applied;
    if (!cur) cur = log_new();
    pthread_mutex_unlock(&mu);
}
/* Frees dead traced objects returned by the collector: release acyclic fields, free memory. */
static void mut_release_child(void *t) { if (t && !is_traced(t)) vtab(t)->rel(t); }
/* Dead owners of collections (rt_relo_owner) with the sequence number of the log that has to be applied before
 * their memory can go: OWNER_MOD and rt_gc_root_hint reach an owner through the collection, not through a
 * counted reference, so entries naming it can be logged after it died, up to its relo. Pairs (object, seq). */
static PtrStack m_held;
static void free_held(int all) {
    size_t k = 0;
    for (size_t i = 0; i < m_held.len; i += 2) {
        void *p = m_held.items[i]; uint64_t seq = (uint64_t)(uintptr_t)m_held.items[i + 1];
        if (all || seq <= m_applied) vtab(p)->freemem(p);
        else { m_held.items[k++] = p; m_held.items[k++] = m_held.items[i + 1]; }
    }
    m_held.len = k;
}
static void free_returned(void *p) {
    rt_trav_mode = RT_TRAV_FREE;
    vtab(p)->trav(p, mut_release_child);
    rt_trav_mode = RT_TRAV_SCAN;
    rt_relo_owner = 0;
    vtab(p)->relo(p);
    if (!rt_relo_owner) { vtab(p)->freemem(p); return; }
    /* entries logged up to now are in the current log (handed next, as handed + 1) or in a handed one */
    stack_push(&m_held, p);
    stack_push(&m_held, (void *)(uintptr_t)(cur && cur->n ? handed + 1 : handed));
}
static void process_returns(int64_t budget_ns, int64_t t0, size_t keep) {
    if (m_held.len) free_held(0);
    while (ret_pos + keep < ret_local.len) {
        free_returned(ret_local.items[ret_pos++]); dbg_bfreed++;
        if (budget_ns >= 0 && (ret_pos & 31) == 0 && rt_nanos() - t0 > budget_ns) break;
    }
    if (ret_pos == ret_local.len) { ret_local.len = 0; ret_pos = 0; }
    else if (ret_pos >= 4096 && ret_pos * 2 >= ret_local.len) {   /* keep the pending tail at the front */
        memmove(ret_local.items, ret_local.items + ret_pos, (ret_local.len - ret_pos) * sizeof(void *));
        ret_local.len -= ret_pos; ret_pos = 0;
    }
}
static void note_pause(int64_t t0) { stats_add_pause(&gc_st, rt_nanos() - t0); }
__attribute__((noinline)) static void boundary(void) {
    if (in_boundary) { /* log filled while freeing returned objects: just hand it over */
        pthread_mutex_lock(&mu);
        cur->seq = ++handed; if (q_tail) q_tail->next = cur; else q_head = cur; q_tail = cur; q_len++; cur = NULL;
        pthread_cond_signal(&cv_work);
        cur = log_new();
        pthread_mutex_unlock(&mu);
        return;
    }
    in_boundary = 1;
    int64_t t0 = rt_nanos();
    ep_epochs++;
    handoff();
    if (free_budget_ns < 0) { const char *e = getenv("KX_GC_FREE_BUDGET_US"); free_budget_ns = e && *e ? atoll(e) * 1000 : (q_target_ns / 2 > FREE_BUDGET_MIN_NS ? q_target_ns / 2 : FREE_BUDGET_MIN_NS); }
    if (boundary_keep < 0) { const char *e = getenv("KX_GC_BOUNDARY_KEEP"); boundary_keep = e && *e ? atoll(e) : BOUNDARY_KEEP_DEFAULT; if (boundary_keep < 0) boundary_keep = 0; }
    process_returns(free_budget_ns, t0, (size_t)boundary_keep);
    slab_flush();
    if (rt_nanos() - t0 > dbg_bmax) dbg_bmax = rt_nanos() - t0;
    note_pause(t0);
    in_boundary = 0;
}
/* First log entry: read the tunables, take the first log. Out of line, so the append below needs no stack
 * frame: log_op and the three entry points are inlined into generated code by LTO (always_inline). As calls
 * (prologue + epilogue per entry, ~35 per lru get) they cost lru 337 -> 260 ms, see bench/gc/ops/README.md. */
static int64_t defer_flush = 8, defer_flush_base = 8;   /* KX_GC_DEFER_FLUSH: flush once the batch is 1/N of the old generation (adaptive, see flush_live_def) */
static int c_after_flush;
#define DEFER_FLUSH_MAX 65536   /* batch cap: a 1/8 batch of a 7M old generation (wide_graph_churn) grew the root and deferred stacks by ~100 MiB */
static int defer_live = 1;   /* KX_GC_DEFER_LIVE, see dec_apply */
static __attribute__((noinline)) void log_first(void) {
    /* first log: before the collector thread exists, so no race on the tunables */
    const char *e = getenv("KX_GC_LOG_FLOOR"); if (e && atoll(e) > 0) log_floor = (size_t)atoll(e);
    e = getenv("KX_GC_PURE_NOBOOST"); if (e && *e) pure_noboost = atoi(e) != 0;
    e = getenv("KX_GC_DEFER_LIVE"); defer_live = !(e && *e == '0');
    e = getenv("KX_GC_DEFER_FLUSH"); if (e && atoll(e) > 0) defer_flush = defer_flush_base = atoll(e);
    e = getenv("KX_GC_PURE_RATIO"); if (e && atoll(e) > 0) pure_ratio = atoll(e);
    e = getenv("KX_GC_MIN_THRESHOLD"); if (e && atoll(e) > 0) c_threshold = c_min_threshold = (size_t)atoll(e);
    e = getenv("KX_GC_LOG_CAP");
    if (e && atoll(e) > 0) { size_t c = (size_t)atoll(e); log_cap = c > LOG_CAP ? LOG_CAP : c; log_cap_fixed = 1; } else log_cap_follow();
    pthread_mutex_lock(&mu); cur = log_new(); pthread_mutex_unlock(&mu);
}
static inline __attribute__((always_inline)) void log_op(uintptr_t e) {
    if (__builtin_expect(cur == NULL, 0)) log_first();
    cur->a[cur->n++] = e;
    if (__builtin_expect(cur->n >= atomic_load_explicit(&log_cap, memory_order_relaxed), 0)) boundary();
}
__attribute__((always_inline)) void rt_gc_log_inc(void *p) { if (p) log_op((uintptr_t)p | OP_INC); }
__attribute__((always_inline)) void rt_gc_log_dec(void *p) { if (p) log_op((uintptr_t)p | OP_DEC); }
__attribute__((always_inline)) void rt_gc_write_barrier(void *obj) { log_op((uintptr_t)obj | OP_MOD); }
void rt_gc_root_hint(void *p) { log_op((uintptr_t)p | OP_ROOT); }
/* Freed when the collector takes the current log (see collector_main). Without a log the collector has not
 * started, so it cannot be reading p. */
void rt_gc_free_later(void *p) {
    if (!p) return;
    if (!cur) { free(p); return; }
    stack_push(&cur->frees, p);
}

// ---- collector (background thread): header bits are collector-owned for traced objects ----
// Header word of a traced object under epoch (bits 0-34 as in object.inc; the rest is collector-owned):
//
//   63         40   39     38      37     36     35      34        33  32   31                 0
//   +------------+-------+-------+------+------+-------+----------+-------+-------------------+
//   | CRC / set  | stable| zombie| dead | cand | dirty | buffered | color |  reference count  |
//   +------------+-------+-------+------+------+-------+----------+-------+-------------------+
//
//   dirty:  touched by an RC operation or write barrier since the last MarkGray visit (Delta test)
//   cand:   member of a candidate cycle; the CRC field then holds the cycle's set id
//   dead:   count reached zero while a candidate; freed by the set's validation
//   zombie: dead (children already released) but still listed in the root buffer or deferred list;
//           its memory is returned when the list entry is removed
//   stable: survived a cycle scan as externally referenced and untouched since (old generation);
//           minor detections treat it as an opaque live object, so they never re-trace the live graph
//   bit 63: SEEN by the in-progress incremental major (CRC / set id then use bits 40-62)
#define DIRTY_BIT (1ULL << 35)
#define CAND_BIT (1ULL << 36)
#define DEAD_BIT (1ULL << 37)
#define ZOMBIE_BIT (1ULL << 38)   /* freed cycle member still referenced by the root buffer */
#define STABLE_BIT (1ULL << 39)
#define CRC_SHIFT 40
#define CRC_MAX 0x7fffffULL
#define CRC_MASK (CRC_MAX << CRC_SHIFT)
#define SEEN_BIT (1ULL << 63)   /* visited by the in-progress incremental major (its memory is held until it ends) */
static inline int has(void *p, uint64_t b) { return (*header(p) & b) != 0; }
static inline void set_bit(void *p, uint64_t b) { *header(p) |= b; }
static inline void clr_bit(void *p, uint64_t b) { *header(p) &= ~b; }
static inline uint64_t crc(void *p) { return (*header(p) >> CRC_SHIFT) & CRC_MAX; }
static inline void set_crc(void *p, uint64_t c) { *header(p) = (*header(p) & ~CRC_MASK) | ((c & CRC_MAX) << CRC_SHIFT); }

static PtrStack c_roots, c_work, c_ret;                 /* collector-local */
#define C_MAX_THRESHOLD (1u << 18)
#define MAJOR_RATIO 4   /* major detection once 4x as many roots were deferred as there are stable objects */
#define MAJOR_RATIO_MAX 256
static int64_t major_ratio = MAJOR_RATIO, major_ratio_base = MAJOR_RATIO;   /* adaptive: doubles after a major that found (almost) no garbage */
/* Candidate cycles of one detection, validated together: set i has id first_id + i and members
 * members[ends[i-1] .. ends[i]). One allocation per detection; batches are validated in FIFO order. */
typedef struct Batch { struct Batch *next; uint64_t valid_after, first_id; int tried; size_t nsets; size_t *ends; void *members[]; } Batch;
static Batch *cands, *cands_tail;
static uint64_t next_set_id = 1;
static int64_t dbg_dem_touch, dbg_dem_other, dbg_prom, dbg_major_visits, dbg_minor_visits, dbg_roots_k, dbg_t_mark, dbg_t_scan, dbg_t_apply, dbg_t_valid, dbg_t_detect, c_stable_n, c_deferred_new, dbg_majors, c_traversed, dbg_members, dbg_sets, dbg_pass, dbg_fail_delta, dbg_fail_sigma, dbg_dead, dbg_logs;

/* An increment or write barrier touched p: it is dirty (Delta test) but stays in the old generation.
 * Neither can make p garbage (an increment adds a reference, a store changes only p's out-edges, whose
 * targets get their own increment / decrement), so a stable object stays opaque to minor detections. */
static inline void touch_keep(void *p) { *header(p) |= DIRTY_BIT; }
/* A decrement touched p: it is dirty and leaves the old generation (it may have become garbage). */
static inline void touch(void *p) {
    uint64_t h = *header(p);
    if (h & STABLE_BIT) { c_stable_n--; dbg_dem_touch++; }
    *header(p) = (h | DIRTY_BIT) & ~STABLE_BIT;
}
static inline void promote(void *p) { if (!has(p, STABLE_BIT)) { set_bit(p, STABLE_BIT); c_stable_n++; } }
static void dec_apply(void *p);
static int64_t dbg_deferred_live, dbg_swept;
static PtrStack c_deferred;   /* see detect */
static PtrStack c_live_def;   /* deferred live roots (dec_apply), flushed to minor roots in batches */
static int64_t dbg_flushes;
static void release_dead_child(void *t) { if (t && is_traced(t)) dec_apply(t); }
/* Count reached zero (no candidate set or root buffer holds it): decrement traced children, return memory.
 * Iterative (c_dying), so freeing a long dead list cannot overflow the collector thread's stack. */
static PtrStack c_dying;
static int c_releasing;
static void release_children(void *p);
static void ret_push(void *p);
static void release_dead(void *p) {
    ret_push(p);
    release_children(p);
}
/* Count reached zero while p is still listed in the root buffer or the deferred list: release its
 * children now (so dead chains do not keep each other alive until the list is drained) and mark it a
 * zombie; its memory is returned when the list entry is removed (detect, pass 1). */
static size_t c_zombies;   /* zombies made since the last sweep_deferred (root buffer and deferred list) */
static void release_zombie(void *p) {
    c_zombies++;
    set_bit(p, ZOMBIE_BIT);
    release_children(p);
}
static void release_children(void *p) {
    dbg_dead++;
    if (has(p, STABLE_BIT)) { clr_bit(p, STABLE_BIT); c_stable_n--; }
    clr_bit(p, DEAD_BIT);
    set_color(p, BLACK);
    stack_push(&c_dying, p);
    if (c_releasing) return;
    c_releasing = 1;
    int pm = rt_trav_mode; rt_trav_mode = RT_TRAV_RELEASE;   /* may run inside validate's release loop */
    while (c_dying.len) { void *x = stack_pop(&c_dying); vtab(x)->trav(x, release_dead_child); }
    rt_trav_mode = pm;
    c_releasing = 0;
}
static void possible_root(void *p) {
    set_color(p, PURPLE);
    if (!has(p, KX_BUF_BIT)) { set_bit(p, KX_BUF_BIT); stack_push(&c_roots, p); }
}
/* KX_GC_DEFER_LIVE (default 1): a decrement that leaves an old-generation (stable) object alive keeps it in
 * the old generation and defers it to the next major detection instead of making it a minor root. Such an
 * object was proven externally referenced by a detection; on live-data churn (lru: every pointer swap in the
 * list decrements live neighbours) re-tracing it in minors finds nothing and costs most of the collector time.
 * Sound: a major detection traces from every deferred root with the stable bit ignored, so a cycle it
 * became the last way into is still found, only later (the exit drain runs a major too). */
/* Deferred live roots wait for a major, and those that die meanwhile (lru: evicted entries) are zombies whose
 * memory would wait too: once most of the deferred list is zombies, return their memory now. */
static void sweep_list(PtrStack *st) {
    size_t k = 0;
    for (size_t i = 0; i < st->len; i++) {
        void *s = st->items[i];
        if (has(s, ZOMBIE_BIT)) { clr_bit(s, ZOMBIE_BIT); clr_bit(s, KX_BUF_BIT); ret_push(s); dbg_swept++; }
        else st->items[k++] = s;
    }
    st->len = k;
}
/* both lists that wait for a major: flushed live roots that a minor deferred again end up in c_deferred */
static void sweep_deferred(void) { sweep_list(&c_live_def); sweep_list(&c_deferred); c_zombies = 0; }
/* The batch of deferred live roots is large against the old generation: demote them and hand them to the next
 * minor detection (the behaviour without deferral, once per batch instead of once per decrement), so garbage
 * cycles reached through old objects do not wait for a major (cycles: +37% peak RSS when they did). */
static void flush_live_def(void) {
    dbg_flushes++; c_after_flush = 1;
    for (size_t i = 0; i < c_live_def.len; i++) {
        void *s = c_live_def.items[i];
        if (has(s, ZOMBIE_BIT)) { clr_bit(s, ZOMBIE_BIT); clr_bit(s, KX_BUF_BIT); ret_push(s); continue; }
        if (has(s, STABLE_BIT)) { clr_bit(s, STABLE_BIT); c_stable_n--; }
        stack_push(&c_roots, s);
    }
    c_live_def.len = 0; c_zombies = 0;
}
static void dec_apply(void *p) {
    uint64_t h = *header(p);
    if ((h & KX_CNT_MASK) == 0) rt_panic("epoch GC: reference count underflow");
    if ((h & STABLE_BIT) && (h & KX_CNT_MASK) > 1 && defer_live) {
        *header(p) = (h - 1) | DIRTY_BIT;
        if (!(h & (KX_BUF_BIT | CAND_BIT))) { set_color(p, PURPLE); set_bit(p, KX_BUF_BIT); stack_push(&c_live_def, p); dbg_deferred_live++; }
        return;
    }
    *header(p) = h - 1; touch(p);
    if (ref_count(p) == 0) {
        if (has(p, CAND_BIT)) set_bit(p, DEAD_BIT);          /* the candidate set's validation frees it */
        else if (has(p, KX_BUF_BIT)) release_zombie(p);
        else release_dead(p);
    }
    else possible_root(p);
}
/* rt_gc_root_hint: as a decrement that leaves the count unchanged (dec_apply). A dead object (count zero; its
 * memory is held until this log is applied, see m_held) needs nothing. */
static void hint_apply(void *p) {
    uint64_t h = *header(p);
    if ((h & KX_CNT_MASK) == 0) return;
    if ((h & STABLE_BIT) && defer_live) {
        *header(p) = h | DIRTY_BIT;
        if (!(h & (KX_BUF_BIT | CAND_BIT))) { set_color(p, PURPLE); set_bit(p, KX_BUF_BIT); stack_push(&c_live_def, p); dbg_deferred_live++; }
        return;
    }
    touch(p);
    possible_root(p);
}
/* Increments first, then decrements and root hints (see the header comment). The first pass compacts those to
 * the front of the log (it is collector-private once dequeued), so the second pass reads only those
 * (software prefetch of the headers measured ~15% slower). */
static void apply_log(Log *l) {
    size_t n = l->n, nd = 0;
    for (size_t i = 0; i < n; i++) {
        uintptr_t e = l->a[i]; void *p = (void *)(e & ~(uintptr_t)3);
        if ((e & 3) == OP_INC) { *header(p) = (*header(p) + 1) | DIRTY_BIT; }
        else if ((e & 3) == OP_MOD) touch_keep(p);
        else l->a[nd++] = e;
    }
    for (size_t i = 0; i < nd; i++) {
        uintptr_t e = l->a[i]; void *p = (void *)(e & ~(uintptr_t)3);
        if ((e & 3) == OP_DEC) dec_apply(p); else hint_apply(p);
    }
}

// Concurrent trial deletion, run in parallel by the collector thread and KX_GC_THREADS - 1 helpers.
// MarkGray counts, per object, the references from traversed objects in the CRC field (header bits
// 40-63, zero outside a detection); Scan compares it with the real count: count - CRC > 0 means a
// reference from outside the traversed subgraph. Both phases change headers only with atomic
// operations; CollectWhite and everything else run on the collector thread alone, separated from the
// parallel phases by the phase barrier. Objects in a candidate set are opaque, and in a minor detection
// so are stable (old-generation) objects. A wrong CRC can only make the detector propose a wrong candidate,
// which validation rejects. It does happen: the trace counts an edge the mutator stored after the last
// applied log. Such a candidate can be live, so see close_sets for why the Sigma test must run before the
// Delta test.
#define MAX_THREADS 16
/* Cost model, learned at run time: wall ns per visited object on one thread (ns_ser) and on all threads
 * (ns_par, the real speedup including contention and imbalance), plus the fixed cost of one parallel
 * phase (wake + barrier, calibrated by an empty parallel phase). ns_par starts at a perfect split; while
 * the model keeps choosing serial it drifts back towards optimistic (PAR_RETRY_DECAY per detection), so a
 * machine that was busy is retried later. The first parallel sample replaces the guess. */
#define PAR_RETRY_DECAY 0.995
#define PAR_MARGIN 0.8          /* parallel only if predicted at least 20% faster (hysteresis, not a size threshold) */
static int par_sampled;
static double ns_ser = 20.0, ns_par = -1.0, par_wake_ns = -1.0;
static int64_t dbg_par_det;
static double visits_per_root[2] = { 1.0, 1.0 };   /* [major]: running estimate from previous detections */
#define SHARE_CHUNK 128
static int c_major;                 /* current detection ignores the stable bit (traces the old generation too) */
static _Atomic int c_hit_stable;    /* current minor detection stopped at a stable object */
static _Atomic int64_t c_stable_delta;
static int n_threads = 1;
typedef struct { PtrStack work, black, marked; int64_t traversed; } Worker;   /* marked: see settle */
static Worker workers[MAX_THREADS];
static __thread Worker *tw;
static pthread_mutex_t pmu = KX_MU_INIT;
static pthread_cond_t p_go = PTHREAD_COND_INITIALIZER, p_wait = PTHREAD_COND_INITIALIZER;
static uint64_t p_gen;                         /* guarded by pmu: phase generation */
static int p_phase, p_active, p_idle, p_finished, p_done, p_stop;
static PtrStack p_shared;                      /* guarded by pmu: work shared between workers */
enum { PHASE_MARK = 1, PHASE_SCAN = 2 };

static inline uint64_t hload(void *p) { return __atomic_load_n(header(p), __ATOMIC_RELAXED); }
static inline int hcas(void *p, uint64_t *old, uint64_t nw) {
    return __atomic_compare_exchange_n(header(p), old, nw, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
}
static inline uint64_t with_color(uint64_t h, int c) { return (h & ~COLOR_MASK) | ((uint64_t)c << KX_COLOR_SHIFT); }
static inline void promote_atomic(void *p) {
    if (!(__atomic_fetch_or(header(p), STABLE_BIT, __ATOMIC_RELAXED) & STABLE_BIT)) atomic_fetch_add_explicit(&c_stable_delta, 1, memory_order_relaxed);
}
static int c_im;                    /* an incremental major is tracing (single-threaded) */
static PtrStack im_seen, c_hold, sm_retry;   /* sm_retry: side-minor roots retried after the major */     /* objects it visited; freed objects it visited (held until it ends) */
/* Scan can reach an object MarkGray did not: the edge was stored after MarkGray left its source. Its stacks
 * keep the object across steps, so its memory must be held like that of every other visited object. */
static inline void im_note(void *t) { if (c_im && !has(t, SEEN_BIT)) { set_bit(t, SEEN_BIT); stack_push(&im_seen, t); } }
static void mg_child(void *t) {
    if (!t || !is_traced(t)) return;
    uint64_t h = hload(t);
    if (h & (CAND_BIT | DEAD_BIT)) return;
    if (!c_major && (h & STABLE_BIT)) { atomic_store_explicit(&c_hit_stable, 1, memory_order_relaxed); return; }
    tw->traversed++;
    h = __atomic_add_fetch(header(t), 1ULL << CRC_SHIFT, __ATOMIC_RELAXED);
    while (((h >> KX_COLOR_SHIFT) & 3) != GRAY)
        /* clear the Delta bit only on the first visit of this detection (CRC 1): an incremental major may
         * see an object re-colored by a log applied between its steps, and must keep that touch visible */
        if (hcas(t, &h, (((h >> CRC_SHIFT) & CRC_MAX) == 1 ? with_color(h, GRAY) & ~DIRTY_BIT : with_color(h, GRAY)) | (c_im ? SEEN_BIT : 0))) {
            if (!c_im) stack_push(&tw->marked, t);
            else if (!(h & SEEN_BIT)) stack_push(&im_seen, t);
            stack_push(&tw->work, t); break;
        }
}
static void sb_child(void *t) {
    if (!t || !is_traced(t)) return;
    uint64_t h = hload(t);
    if (h & (CAND_BIT | DEAD_BIT)) return;
    while (((h >> KX_COLOR_SHIFT) & 3) != BLACK)
        if (hcas(t, &h, with_color(h, BLACK) & ~CRC_MASK)) { im_note(t); promote_atomic(t); stack_push(&tw->black, t); break; }
}
static void scan_child(void *t) { if (t && is_traced(t) && !(hload(t) & CAND_BIT)) { im_note(t); stack_push(&tw->work, t); } }
static void scan_one(void *x) {
    uint64_t h = hload(x);
    while (((h >> KX_COLOR_SHIFT) & 3) == GRAY) {
        int64_t ext = (int64_t)(h & KX_CNT_MASK) - (int64_t)((h >> CRC_SHIFT) & CRC_MAX);
        if (ext > 0) {
            if (hcas(x, &h, with_color(h, BLACK) & ~CRC_MASK)) {
                promote_atomic(x); stack_push(&tw->black, x);
                while (tw->black.len) { void *y = stack_pop(&tw->black); vtab(y)->trav(y, sb_child); }
                return;
            }
        } else if (hcas(x, &h, with_color(h, WHITE))) { vtab(x)->trav(x, scan_child); return; }
    }
}
/* Runs the current phase on this worker until all workers are out of work. */
static void phase_loop(Worker *w) {
    tw = w;
    for (;;) {
        while (w->work.len) {
            void *x = stack_pop(&w->work);
            if (p_phase == PHASE_MARK) { VISIT(); vtab(x)->trav(x, mg_child); } else scan_one(x);
            if (p_active > 1 && w->work.len > 2 * SHARE_CHUNK && __atomic_load_n(&p_idle, __ATOMIC_RELAXED)) {
                pthread_mutex_lock(&pmu);
                if (p_shared.len < SHARE_CHUNK) {
                    for (int i = 0; i < SHARE_CHUNK; i++) stack_push(&p_shared, stack_pop(&w->work));
                    if (__atomic_load_n(&p_idle, __ATOMIC_RELAXED)) pthread_cond_broadcast(&p_wait);
                }
                pthread_mutex_unlock(&pmu);
            }
        }
        if (p_active == 1) return;
        pthread_mutex_lock(&pmu);
        for (;;) {
            if (p_finished) { pthread_mutex_unlock(&pmu); return; }
            if (p_shared.len) {
                for (int i = 0; i < SHARE_CHUNK && p_shared.len; i++) stack_push(&w->work, stack_pop(&p_shared));
                break;
            }
            if (__atomic_add_fetch(&p_idle, 1, __ATOMIC_RELAXED) == p_active) { p_finished = 1; pthread_cond_broadcast(&p_wait); pthread_mutex_unlock(&pmu); return; }
            pthread_cond_wait(&p_wait, &pmu);
            if (!p_finished) __atomic_sub_fetch(&p_idle, 1, __ATOMIC_RELAXED);
        }
        pthread_mutex_unlock(&pmu);
    }
}
static void *helper_main(void *arg) {
    Worker *w = arg;
    uint64_t seen = 0;
    pthread_mutex_lock(&pmu);
    for (;;) {
        while (p_gen == seen && !p_stop) pthread_cond_wait(&p_go, &pmu);
        if (p_stop) break;
        seen = p_gen;
        if (w - workers >= p_active) continue;
        pthread_mutex_unlock(&pmu);
        phase_loop(w);
        pthread_mutex_lock(&pmu);
        if (++p_done == p_active - 1) pthread_cond_broadcast(&p_wait);
    }
    pthread_mutex_unlock(&pmu);
    return NULL;
}
static void start_helpers(void) {
    const char *e = getenv("KX_GC_THREADS");
    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    int n = e && *e ? atoi(e) : (int)(cores < 4 ? cores : 4);
    if (n < 1) n = 1;
    if (n > MAX_THREADS) n = MAX_THREADS;
    n_threads = n;
    for (int i = 1; i < n; i++) {
        pthread_t t;
        if (pthread_create(&t, NULL, helper_main, &workers[i])) { n_threads = i; break; }
        pthread_detach(t);
    }
}
/* Runs one phase over `items` on `active` workers (the collector thread is worker 0). */
static void run_phase(int phase, void **items, size_t n, int active) {
    /* contiguous slices: neighbouring roots usually share cache lines and subgraphs */
    for (int w = 0; w < active; w++)
        for (size_t i = n * (size_t)w / (size_t)active; i < n * (size_t)(w + 1) / (size_t)active; i++) stack_push(&workers[w].work, items[i]);
    p_phase = phase;
    if (active > 1) {
        pthread_mutex_lock(&pmu);
        p_active = active; __atomic_store_n(&p_idle, 0, __ATOMIC_RELAXED); p_finished = 0; p_done = 0; p_gen++;
        pthread_cond_broadcast(&p_go);
        pthread_mutex_unlock(&pmu);
        phase_loop(&workers[0]);
        pthread_mutex_lock(&pmu);
        while (p_done < active - 1) pthread_cond_wait(&p_wait, &pmu);
        pthread_mutex_unlock(&pmu);
    } else {
        p_active = 1;
        phase_loop(&workers[0]);
    }
}
static void collect_phases_stats(void) {
    for (int i = 0; i < n_threads; i++) { c_traversed += workers[i].traversed; workers[i].traversed = 0; }
    int64_t dd = atomic_exchange_explicit(&c_stable_delta, 0, memory_order_relaxed); c_stable_n += dd; dbg_prom += dd;
}
static PtrStack cw_m; static uint64_t cw_id;
static void cw_child(void *t) {
    if (t && is_traced(t) && !has(t, CAND_BIT) && color(t) == WHITE && ref_count(t) > 0 && !has(t, DEAD_BIT)) {
        if (has(t, STABLE_BIT)) { clr_bit(t, STABLE_BIT); c_stable_n--; }
        set_bit(t, CAND_BIT); set_crc(t, cw_id & CRC_MAX); stack_push(&cw_m, t); stack_push(&c_work, t);
    }
}
static PtrStack cw_ends;    /* end index in cw_m of every set of the current detection */
static uint64_t cw_first_id;
static void collect_white(void *s) {
    if (color(s) != WHITE || has(s, CAND_BIT | DEAD_BIT) || ref_count(s) == 0) return;   /* count 0: freed meanwhile */
    if (!cw_ends.len) cw_first_id = next_set_id;
    cw_id = next_set_id++;
    if (has(s, STABLE_BIT)) { clr_bit(s, STABLE_BIT); c_stable_n--; }
    set_bit(s, CAND_BIT); set_crc(s, cw_id & CRC_MAX); stack_push(&cw_m, s); stack_push(&c_work, s);
    while (c_work.len) { void *x = c_work.items[--c_work.len]; vtab(x)->trav(x, cw_child); }
    stack_push(&cw_ends, (void *)(uintptr_t)cw_m.len);
    dbg_sets++;
}
static void batch_close(uint64_t valid_after) {
    if (!cw_ends.len) return;
    size_t n = cw_m.len, k = cw_ends.len;
    size_t bsz = sizeof(Batch) + n * sizeof(void *) + k * sizeof(size_t);
    Batch *b = malloc(bsz); if (!b) rt_panic("OutOfMemoryError");
    dbg_batch_bytes += (int64_t)bsz; if (dbg_batch_bytes > dbg_batch_peak) dbg_batch_peak = dbg_batch_bytes;
    b->next = NULL; b->tried = 0; b->valid_after = valid_after; b->first_id = cw_first_id; b->nsets = k;
    memcpy(b->members, cw_m.items, n * sizeof(void *));
    b->ends = (size_t *)(b->members + n);
    for (size_t i = 0; i < k; i++) b->ends[i] = (size_t)(uintptr_t)cw_ends.items[i];
    if (cands_tail) cands_tail->next = b; else cands = b;
    cands_tail = b;
    dbg_members += (int64_t)n; cw_m.len = 0; cw_ends.len = 0;
}
static void batch_free(Batch *b) {
    size_t n = b->nsets ? b->ends[b->nsets - 1] : 0;
    dbg_batch_bytes -= (int64_t)(sizeof(Batch) + n * sizeof(void *) + b->nsets * sizeof(size_t)); free(b);
}
#define SLICE_ROOTS 32768   /* KX_GC_SLICE_ROOTS; 0 = unbounded */
static size_t slice_roots = SLICE_ROOTS;
static int trace_q = -1;   /* 1: KX_GC_DEBUG peaks, 2: also KX_GC_TRACE (backlog every 8 logs) */
static int64_t dbg_mn_roots, dbg_mn_found, dbg_mn_work;
static size_t dbg_thr_max, dbg_roots_max, dbg_cand_max, dbg_qseen_max;
static size_t q_seen;          /* queue length when the collector took the current log */
static int64_t carry_q = -1;   /* KX_GC_CARRY_QUEUE: skip detection at this queue length (default 0 = never) */
static uint64_t c_valid_after;                      /* hand-off count when the current detection ended */
static PtrStack c_deferred;   /* buffered roots whose minor detection stopped at the old generation */
/* Minor (major = 0): stable objects are opaque. Roots left non-white after a minor detection that hit a
 * stable object stay buffered in c_deferred; a major detection (every stable object traced) handles them
 * once MAJOR_RATIO times as many roots were deferred as there are stable objects (amortized O(1) per root). */
static size_t detect_prepare(int major, PtrStack *rootsp);
/* KX_GC_LEAN_STACKS (default 1): the incremental major keeps its roots in one array only. MarkGray and Scan
 * walk im_roots with a cursor instead of pushing every root onto the work stack, and roots are not listed in
 * im_seen (their SEEN bit is set; they are settled and cleared from im_roots). The work stacks then hold
 * only the traversal frontier. On huge_live_churn (10M roots) that removes three root-sized copies
 * (deferred, work, im-seen: ~380 MiB of collector stacks at the peak). KX_GC_LEAN_STACKS=0: previous behavior. */
static int lean_stacks_v = -1;
static inline int lean_stacks(void) {
    if (__builtin_expect(lean_stacks_v < 0, 0)) { const char *e = getenv("KX_GC_LEAN_STACKS"); lean_stacks_v = !(e && *e == '0'); }
    return lean_stacks_v;
}
static void detect_finish(int major, PtrStack roots, size_t k, int hit_stable);
static void close_sets(void);
static void detect(int major) {
    PtrStack roots; size_t k = detect_prepare(major, &roots);
    /* minor and one-pass major detections alike, when the expected traversal pays for waking the helpers */
    if (par_wake_ns < 0 && n_threads > 1) {
        int64_t w0 = rt_nanos(); run_phase(PHASE_MARK, NULL, 0, n_threads); run_phase(PHASE_SCAN, NULL, 0, n_threads);
        par_wake_ns = (double)(rt_nanos() - w0) / 2.0;
    }
    if (ns_par < 0) ns_par = ns_ser / n_threads;
    double v_est = (double)k * visits_per_root[major];
    int active = n_threads > 1 && (size_t)n_threads <= k && v_est * ns_par + 2.0 * par_wake_ns < PAR_MARGIN * v_est * ns_ser ? n_threads : 1;
    if (active == 1 && n_threads > 1 && ns_par > ns_ser / n_threads) ns_par = ns_par * PAR_RETRY_DECAY + (1 - PAR_RETRY_DECAY) * ns_ser / n_threads;
    if (active > 1) dbg_par_det++;
    atomic_store_explicit(&c_hit_stable, 0, memory_order_relaxed);
    int64_t t0 = rt_nanos();
    run_phase(PHASE_MARK, roots.items, k, active);
    int64_t t1 = rt_nanos();
    run_phase(PHASE_SCAN, roots.items, k, active);
    int64_t t2 = rt_nanos();
    dbg_t_mark += t1 - t0; dbg_t_scan += t2 - t1;
    {   /* refresh the cost model from this detection's MarkGray + Scan wall time */
        int64_t tr = 0; for (int i = 0; i < n_threads; i++) tr += workers[i].traversed;
        double v = (double)(tr + (int64_t)k), t = (double)(t2 - t0);
        if (k) visits_per_root[major] = 0.5 * visits_per_root[major] + 0.5 * v / (double)k;
        if (v > 0 && t > 0) {
            if (active == 1) ns_ser = 0.8 * ns_ser + 0.2 * (t / v);
            else { double a = (t - 2.0 * par_wake_ns) / v; if (a < ns_ser / active) a = ns_ser / active; ns_par = par_sampled++ ? 0.5 * ns_par + 0.5 * a : a; }
        }
    }
    detect_finish(major, roots, k, atomic_load_explicit(&c_hit_stable, memory_order_relaxed));
}
static size_t detect_prepare(int major, PtrStack *rootsp) {
    ep_detections++;
    c_major = major;
    if (major) stack_move(&c_deferred, &c_live_def);
    if (major) {
        dbg_majors++; c_deferred_new = 0;
        /* lean stacks: hand the deferred buffer over instead of copying it, and drop its storage (stack_move
         * keeps the capacity, so on huge_live_churn 128 MiB of an emptied deferred stack stayed resident) */
        if (lean_stacks() && !c_roots.len) { free(c_roots.items); c_roots = c_deferred; c_deferred = (PtrStack){0}; }
        else { stack_move(&c_roots, &c_deferred); if (lean_stacks()) { free(c_deferred.items); c_deferred = (PtrStack){0}; } }
    }
    PtrStack roots = c_roots; c_roots = (PtrStack){0};
    /* bounded slice: a minor takes at most slice_roots roots, the rest stays buffered for the next one */
    if (!major && slice_roots && roots.len > slice_roots) {
        for (size_t i = slice_roots; i < roots.len; i++) stack_push(&c_roots, roots.items[i]);
        roots.len = slice_roots;
    }
    size_t k = 0;
    /* Pass 1: unbuffer, and free roots that died while buffered. Freeing cascades through dec_apply and
     * may free roots already unbuffered here (count 0, BLACK), so the roots to trace are chosen only
     * afterwards (pass 2); otherwise a root could be freed while it is being traced. */
    for (size_t i = 0; i < roots.len; i++) {
        void *s = roots.items[i];
        clr_bit(s, KX_BUF_BIT);
        if (has(s, ZOMBIE_BIT)) { clr_bit(s, ZOMBIE_BIT); ret_push(s); roots.items[i] = NULL; continue; }
        if (has(s, DEAD_BIT) && !has(s, CAND_BIT)) { clr_bit(s, DEAD_BIT); release_dead(s); roots.items[i] = NULL; }
    }
    /* The color says nothing here: a root waiting in the buffer can be recolored by another root's trace,
     * and dropping it then loses the only root of a cycle that runs through the old generation. */
    for (size_t i = 0; i < roots.len; i++) {
        void *s = roots.items[i];
        if (!s || has(s, CAND_BIT | DEAD_BIT)) continue;
        if (ref_count(s) > 0) { set_color(s, GRAY); set_crc(s, 0); clr_bit(s, DIRTY_BIT); roots.items[k++] = s; }
    }
    *rootsp = roots;
    return k;
}
/* Scan and CollectWhite follow the fields as they are now, MarkGray followed them as they were, so an object
 * that lost the edge MarkGray reached it through is left gray or white with its CRC. MarkGray would not trace
 * through it next time, and a cycle counted through it short of its edges would look live for good. */
static void settle(void *x) {
    if (has(x, CAND_BIT)) return;
    if (color(x) == GRAY || color(x) == WHITE) set_color(x, BLACK);
    set_crc(x, 0);
}
static void detect_finish(int major, PtrStack roots, size_t k, int hit_stable) {
    int64_t tv0 = c_traversed; collect_phases_stats();
    if (major) dbg_major_visits += c_traversed - tv0; else dbg_minor_visits += c_traversed - tv0;
    dbg_roots_k += (int64_t)k;
    for (size_t i = 0; i < k; i++) collect_white(roots.items[i]);
    for (int w = 0; w < n_threads; w++) {
        PtrStack *m = &workers[w].marked;
        for (size_t i = 0; i < m->len; i++) settle(m->items[i]);
        m->len = 0;
    }
    for (size_t i = 0; i < im_seen.len; i++) settle(im_seen.items[i]);
    if (c_im && lean_stacks()) for (size_t i = 0; i < k; i++) { settle(roots.items[i]); clr_bit(roots.items[i], SEEN_BIT); }
    if (!major && hit_stable)
        for (size_t i = 0; i < k; i++) {
            void *s = roots.items[i];
            if (!has(s, CAND_BIT) && !has(s, KX_BUF_BIT)) { set_bit(s, KX_BUF_BIT); stack_push(&c_deferred, s); c_deferred_new++; }
        }
    free(roots.items);
    close_sets();
}
// Incremental major: the old-generation pass (MarkGray, then Scan) runs in bounded steps (see below),
// one step after every applied log and more while the collector is
// idle, so a major never stalls log application (and through back-pressure the mutator) for long.
// Logs applied between steps change counts and colors exactly as a concurrently running mutator would in
// Bacon & Rajan's concurrent collector: every touched object is dirty (the Delta bit is cleared only on an
// object's first visit), and candidates are still checked by Delta + Sigma with current counts. While a
// major is in progress, minors run as side minors (own colors / counts in a hash table, see
// side_minor; KX_GC_SIDE_MINOR=0 pauses them instead), and logs, validation and freeing go on: every object the major visits is marked
// SEEN (header bit 63) and listed; a SEEN object that dies or whose cycle is freed is held (DEAD bit set,
// memory not returned) until the major ends, since the trace's stacks may still point to it, and the trace
// never follows the fields of a dead or held object. Objects the major never visited are returned at once:
// the trace can only reach them through a live object, and a live object cannot point to freed memory.
// Step size: KX_GC_MAJOR_STEP_US (default 1000) of tracing per applied log, in 512-visit pieces; with
// KX_GC_MAJOR_STEP_US=0, a fixed KX_GC_MAJOR_STEP visits (default 2048).
#define MAJOR_STEP 2048       /* visits per step when KX_GC_MAJOR_STEP_US=0 */
#define MAJOR_STEP_US 1000    /* default: steps of 512 visits until 1 ms per log has passed */
static int im_state;                 /* 0 none, 1 MarkGray, 2 Scan */
static PtrStack im_roots; static size_t im_k, im_cur;   /* im_cur: lean-stacks cursor into im_roots */
static int64_t im_step_budget = -1, im_m0, im_w0, im_steps;
static int incremental_major = -1;   /* KX_GC_INC_MAJOR (default 1) */
static int side_minors = 1;          /* KX_GC_SIDE_MINOR (default 1): minors keep running during a major */
static void major_adapt(void);
static int64_t im_step_ns = -1, dbg_held, dbg_held_max;
static inline int im_dead(void *x) { return ref_count(x) == 0 || has(x, DEAD_BIT); }
static void ret_push(void *p) {
    if (c_im && has(p, SEEN_BIT)) { set_bit(p, DEAD_BIT); stack_push(&c_hold, p); dbg_held++; }
    else stack_push(&c_ret, p);
}
static void im_begin(void) {
    im_k = detect_prepare(1, &im_roots);
    c_im = 1;
    int lean = lean_stacks();
    for (size_t i = 0; i < im_k; i++) { set_bit(im_roots.items[i], SEEN_BIT); if (!lean) stack_push(&im_seen, im_roots.items[i]); }
    im_m0 = dbg_members + dbg_dead; im_w0 = c_traversed;
    tw = &workers[0]; p_active = 1; im_cur = 0;
    if (!lean) for (size_t i = 0; i < im_k; i++) stack_push(&workers[0].work, im_roots.items[i]);
    im_state = 1;
}
/* One bounded step; returns 1 when the major finished. */
static int im_step(int64_t budget) {
    Worker *w = &workers[0]; tw = w; c_major = 1;
    int64_t n = 0, t0 = rt_nanos();
    int lean = lean_stacks();
    if (im_state == 1) {
        while (n < budget) {
            void *x;
            if (w->work.len) x = stack_pop(&w->work);
            else if (lean && im_cur < im_k) x = im_roots.items[im_cur++];
            else break;
            if (im_dead(x)) continue; VISIT(); vtab(x)->trav(x, mg_child); n++;
        }
        dbg_t_mark += rt_nanos() - t0;
        if (w->work.len || (lean && im_cur < im_k)) return 0;
        if (!lean) for (size_t i = 0; i < im_k; i++) stack_push(&w->work, im_roots.items[i]);
        im_cur = 0; im_state = 2; t0 = rt_nanos();
    }
    while (n < budget) {
        if (w->black.len) { void *y = stack_pop(&w->black); if (!im_dead(y)) vtab(y)->trav(y, sb_child); }
        else if (w->work.len || (lean && im_cur < im_k)) {
            void *x = w->work.len ? stack_pop(&w->work) : im_roots.items[im_cur++]; uint64_t h = hload(x);
            if (((h >> KX_COLOR_SHIFT) & 3) == GRAY) {
                int64_t ext = (int64_t)(h & KX_CNT_MASK) - (int64_t)((h >> CRC_SHIFT) & CRC_MAX);
                if (ext > 0) { set_color(x, BLACK); set_crc(x, 0); promote_atomic(x); stack_push(&w->black, x); }
                else { set_color(x, WHITE); if (!im_dead(x)) vtab(x)->trav(x, scan_child); }
            }
        } else break;
        n++;
    }
    dbg_t_scan += rt_nanos() - t0; im_steps++;
    if (w->work.len || w->black.len || (lean && im_cur < im_k)) return 0;
    detect_finish(1, im_roots, im_k, 0);
    im_roots = (PtrStack){0}; im_state = 0; c_im = 0;
    for (size_t i = 0; i < im_seen.len; i++) clr_bit(im_seen.items[i], SEEN_BIT);
    im_seen.len = 0; stack_release(&im_seen);
    for (int i = 0; i < n_threads; i++) { stack_release(&workers[i].work); stack_release(&workers[i].black); stack_release(&workers[i].marked); }
    if ((int64_t)c_hold.len > dbg_held_max) dbg_held_max = (int64_t)c_hold.len;
    stack_move(&c_ret, &c_hold);
    stack_move(&c_roots, &sm_retry);
    major_adapt();
    return 1;
}
// Side minor: young-generation trial deletion while an incremental major is in progress. The major owns
// the header's color and CRC fields, so the side minor keeps its colors and counts in a private hash
// table (sm_tab) and its own stacks, and never writes a header color. It treats as opaque (live) every
// object the major has visited (SEEN), every stable, candidate or dead object; roots that are SEEN or
// whose trace stopped at a SEEN object are retried after the major (sm_retry). White components become
// candidate sets exactly as in CollectWhite (CAND bit + set id in the CRC field: the major skips CAND
// objects and never visited these), validated by Delta + Sigma like every other set.
typedef struct { void *k; uint32_t crc; uint8_t col; } SmEnt;
static SmEnt *sm_tab; static size_t sm_cap, sm_n;
static PtrStack sm_work, sm_black, sm_roots;
static int sm_hit_seen, sm_hit_stable;
static int64_t dbg_side_minors, dbg_side_visits;
enum { SM_NONE = 0, SM_GRAY, SM_WHITE, SM_BLACK };
static inline size_t sm_hash(void *p) { uint64_t x = (uint64_t)(uintptr_t)p >> 3; x *= 0x9E3779B97F4A7C15ULL; return (size_t)(x >> 17); }
static SmEnt *sm_find(void *p, int ins);
static void sm_grow(void) {
    SmEnt *old = sm_tab; size_t oc = sm_cap;
    sm_cap = oc ? oc * 2 : 1 << 14; sm_tab = calloc(sm_cap, sizeof(SmEnt)); if (!sm_tab) rt_panic("OutOfMemoryError");
    sm_n = 0;
    for (size_t i = 0; i < oc; i++) if (old[i].k) { SmEnt *e = sm_find(old[i].k, 1); e->crc = old[i].crc; e->col = old[i].col; }
    free(old);
}
static SmEnt *sm_find(void *p, int ins) {
    if (ins && (sm_n + 1) * 2 > sm_cap) sm_grow();
    if (!sm_cap) return NULL;
    size_t m = sm_cap - 1, i = sm_hash(p) & m;
    while (sm_tab[i].k) { if (sm_tab[i].k == p) return &sm_tab[i]; i = (i + 1) & m; }
    if (!ins) return NULL;
    sm_tab[i].k = p; sm_tab[i].crc = 0; sm_tab[i].col = SM_NONE; sm_n++;
    return &sm_tab[i];
}
static inline int sm_opaque(void *t) {
    uint64_t h = *header(t);
    if (h & SEEN_BIT) { sm_hit_seen = 1; return 1; }
    if (h & STABLE_BIT) { sm_hit_stable = 1; return 1; }
    return (h & (CAND_BIT | DEAD_BIT)) || (h & KX_CNT_MASK) == 0;
}
static void sm_mg_child(void *t) {
    if (!t || !is_traced(t) || sm_opaque(t)) return;
    SmEnt *e = sm_find(t, 1); e->crc++; dbg_side_visits++;
    if (e->col != SM_GRAY) { if (e->col == SM_NONE) clr_bit(t, DIRTY_BIT); e->col = SM_GRAY; stack_push(&sm_work, t); }
}
static void sm_sb_child(void *t) {
    if (!t || !is_traced(t)) return;
    SmEnt *e = sm_find(t, 0);
    if (e && e->col != SM_BLACK) { e->col = SM_BLACK; promote(t); stack_push(&sm_black, t); }
}
static void sm_scan_child(void *t) { if (t && is_traced(t) && sm_find(t, 0)) stack_push(&sm_work, t); }
static void sm_cw_child(void *t) {
    if (!t || !is_traced(t) || has(t, CAND_BIT)) return;
    SmEnt *e = sm_find(t, 0);
    if (e && e->col == SM_WHITE) { e->col = SM_BLACK; set_bit(t, CAND_BIT); set_crc(t, cw_id & CRC_MAX); stack_push(&cw_m, t); stack_push(&c_work, t); }
}
static void side_minor(void) {
    ep_detections++; dbg_side_minors++; gc_st.collections++;
    PtrStack roots = c_roots; c_roots = (PtrStack){0};
    if (slice_roots && roots.len > slice_roots) {
        for (size_t i = slice_roots; i < roots.len; i++) stack_push(&c_roots, roots.items[i]);
        roots.len = slice_roots;
    }
    sm_roots.len = 0;
    for (size_t i = 0; i < roots.len; i++) {   /* pass 1, as in detect_prepare */
        void *x = roots.items[i];
        clr_bit(x, KX_BUF_BIT);
        if (has(x, ZOMBIE_BIT)) { clr_bit(x, ZOMBIE_BIT); ret_push(x); roots.items[i] = NULL; continue; }
        if (has(x, DEAD_BIT) && !has(x, CAND_BIT)) { clr_bit(x, DEAD_BIT); release_dead(x); roots.items[i] = NULL; }
    }
    for (size_t i = 0; i < roots.len; i++) {
        void *x = roots.items[i];
        if (!x || has(x, CAND_BIT | DEAD_BIT) || ref_count(x) == 0) continue;
        if (has(x, SEEN_BIT)) { set_bit(x, KX_BUF_BIT); stack_push(&sm_retry, x); continue; }
        set_color(x, BLACK);                  /* leaves the root buffer; the major may trace it like any object */
        SmEnt *e = sm_find(x, 1);
        if (e->col != SM_NONE) continue;
        e->col = SM_GRAY; clr_bit(x, DIRTY_BIT); stack_push(&sm_roots, x); stack_push(&sm_work, x);
    }
    free(roots.items);
    sm_hit_seen = sm_hit_stable = 0;
    while (sm_work.len) { void *x = stack_pop(&sm_work); vtab(x)->trav(x, sm_mg_child); }       /* MarkGray */
    for (size_t i = 0; i < sm_roots.len; i++) stack_push(&sm_work, sm_roots.items[i]);           /* Scan */
    while (sm_work.len || sm_black.len) {
        if (sm_black.len) { void *y = stack_pop(&sm_black); vtab(y)->trav(y, sm_sb_child); continue; }
        void *x = stack_pop(&sm_work); SmEnt *e = sm_find(x, 0);
        if (!e || e->col != SM_GRAY) continue;
        if ((int64_t)ref_count(x) - (int64_t)e->crc > 0) { e->col = SM_BLACK; promote(x); stack_push(&sm_black, x); }
        else { e->col = SM_WHITE; vtab(x)->trav(x, sm_scan_child); }
    }
    for (size_t i = 0; i < sm_roots.len; i++) {                                                 /* CollectWhite */
        void *x = sm_roots.items[i]; SmEnt *e = sm_find(x, 0);
        if (e->col != SM_WHITE || has(x, CAND_BIT)) continue;
        if (!cw_ends.len) cw_first_id = next_set_id;
        cw_id = next_set_id++;
        e->col = SM_BLACK; set_bit(x, CAND_BIT); set_crc(x, cw_id & CRC_MAX); stack_push(&cw_m, x); stack_push(&c_work, x);
        while (c_work.len) { void *y = c_work.items[--c_work.len]; vtab(y)->trav(y, sm_cw_child); }
        stack_push(&cw_ends, (void *)(uintptr_t)cw_m.len);
        dbg_sets++;
    }
    for (size_t i = 0; i < sm_roots.len; i++) {   /* live-looking roots whose trace was cut short: retry later */
        void *x = sm_roots.items[i];
        if (has(x, CAND_BIT) || has(x, KX_BUF_BIT)) continue;
        if (sm_hit_seen) { set_color(x, PURPLE); set_bit(x, KX_BUF_BIT); stack_push(&sm_retry, x); }
        else if (sm_hit_stable) { set_bit(x, KX_BUF_BIT); stack_push(&c_deferred, x); c_deferred_new++; }
    }
    dbg_roots_k += (int64_t)sm_roots.len;
    memset(sm_tab, 0, sm_cap * sizeof(SmEnt)); sm_n = 0;
    close_sets();
}
static uint64_t v_sid; static int64_t v_internal;
static inline int in_set(void *t) { return has(t, CAND_BIT) && crc(t) == v_sid; }
static void count_child(void *t) { if (t && is_traced(t) && in_set(t)) v_internal++; }
static void free_cycle_child(void *t) { if (t && is_traced(t) && !in_set(t)) dec_apply(t); }
/* Sigma test of the current detection's sets, then the batch. A failing set is left dirty, so validation
 * rejects it. The test reads fields as they are now and counts as of the last applied log. Reading `handed`
 * only after it makes that safe: every store it saw is logged at or before the batch's Delta log, so if
 * Delta passes, no store changed a member after the test and the counts it read were still current.
 * The other order is a use after free: a live wrong candidate can pass Sigma on a store whose increment
 * is still queued, and that log is then applied to freed memory. */
static void close_sets(void) {
    size_t start = 0;
    for (size_t s = 0; s < cw_ends.len; s++) {
        size_t end = (size_t)(uintptr_t)cw_ends.items[s];
        int64_t sum = 0;
        v_sid = (cw_first_id + s) & CRC_MAX; v_internal = 0;
        for (size_t i = start; i < end; i++) { void *x = cw_m.items[i]; sum += (int64_t)ref_count(x); vtab(x)->trav(x, count_child); }
        if (sum != v_internal) { touch_keep(cw_m.items[start]); dbg_fail_sigma++; }
        start = end;
    }
    pthread_mutex_lock(&mu); uint64_t h = handed; pthread_mutex_unlock(&mu);
    batch_close(h);
}
/* Delta test; frees a passing cycle, re-roots a failing one. Returns objects freed. */
typedef struct { size_t n; void **a; } Members;
static size_t validate(uint64_t id, Members m) {
    int ok = 1;
    v_sid = id & CRC_MAX;
    for (size_t i = 0; i < m.n; i++)
        if (*header(m.a[i]) & (DIRTY_BIT | DEAD_BIT)) { ok = 0; dbg_fail_delta++; break; }
    size_t freed = 0;
    if (ok) {
        int pm = rt_trav_mode; rt_trav_mode = RT_TRAV_RELEASE;
        for (size_t i = 0; i < m.n; i++) { void *x = m.a[i]; vtab(x)->trav(x, free_cycle_child); }
        rt_trav_mode = pm;
        /* Count zeroed: a root hint logged before a member's memory went back (m_held) must see it dead. */
        for (size_t i = 0; i < m.n; i++) { void *x = m.a[i]; clr_bit(x, CAND_BIT); set_color(x, BLACK); set_crc(x, 0); *header(x) &= ~KX_CNT_MASK; if (has(x, KX_BUF_BIT)) set_bit(x, ZOMBIE_BIT); else ret_push(x); }
        freed = m.n; dbg_pass++;
    } else {
        for (size_t i = 0; i < m.n; i++) {
            void *x = m.a[i];
            clr_bit(x, CAND_BIT); set_color(x, BLACK); set_crc(x, 0);
            if (has(x, DEAD_BIT)) { if (has(x, KX_BUF_BIT)) release_zombie(x); else release_dead(x); }
            else if (ref_count(x) > 0) possible_root(x);
        }
    }
    return freed;
}
/* Validates every candidate set detected before hand-off `upto` (all sets when force). */
#define VALIDATE_BUDGET 65536   /* candidate members validated per log; the rest waits for the next log */
static size_t validate_ready(uint64_t upto, int force) {
    size_t freed = 0, seen = 0;
    while (cands && (force || cands->valid_after < upto) && (force || seen < VALIDATE_BUDGET)) {
        seen += cands->nsets ? cands->ends[cands->nsets - 1] : 0;
        Batch *b = cands; cands = b->next; if (!cands) cands_tail = NULL;
        size_t start = 0;
        for (size_t i = 0; i < b->nsets; i++) {
            freed += validate(b->first_id + i, (Members){ b->ends[i] - start, b->members + start });
            start = b->ends[i];
        }
        batch_free(b);
    }
    return freed;
}
// Early validation: a batch normally waits until the log that was current when its detection ended has
// been APPLIED (valid_after < applied seq), i.e. behind the whole queue. Once that log has merely been
// HANDED OFF, every RC operation made before the detection ended is in an applied or a queued log. If no
// queued log mentions a member or a member's traced child (the objects validation reads or decrements),
// applying those logs first would not change anything validation looks at, so the batch is validated at
// once. Otherwise it waits as before. Queued logs are immutable once handed off; scanning them is bounded
// by EARLY_SCAN_MAX entries (KX_GC_EARLY_SCAN; 0 disables).
#define EARLY_SCAN_MAX (32 * LOG_CAP)
static int64_t early_scan_max = -1, dbg_early_ok, dbg_early_hit, dbg_early_skip;
/* Open-addressing pointer set; `used` lists the occupied slots so clearing costs O(n), not O(capacity) */
typedef struct { void **k; size_t cap, n; PtrStack used; } PSet;
static PSet es;
static void ps_clear(PSet *s) { for (size_t i = 0; i < s->used.len; i++) s->k[(size_t)(uintptr_t)s->used.items[i]] = NULL; s->used.len = 0; s->n = 0; }
static void ps_add(PSet *s, void *p) {
    if ((s->n + 1) * 2 > s->cap) {
        void **old = s->k; size_t oc = s->cap; s->cap = oc ? oc * 2 : 1024; s->k = calloc(s->cap, sizeof(void *)); if (!s->k) rt_panic("OutOfMemoryError"); s->n = 0; s->used.len = 0;
        for (size_t i = 0; i < oc; i++) if (old[i]) ps_add(s, old[i]);
        free(old);
    }
    size_t m = s->cap - 1, i = (size_t)(((uint64_t)(uintptr_t)p >> 3) * 0x9E3779B97F4A7C15ULL >> 20) & m;
    while (s->k[i]) { if (s->k[i] == p) return; i = (i + 1) & m; }
    s->k[i] = p; s->n++; stack_push(&s->used, (void *)(uintptr_t)i);
}
static int ps_has(PSet *s, void *p) {
    if (!s->cap) return 0;
    size_t m = s->cap - 1, i = (size_t)(((uint64_t)(uintptr_t)p >> 3) * 0x9E3779B97F4A7C15ULL >> 20) & m;
    while (s->k[i]) { if (s->k[i] == p) return 1; i = (i + 1) & m; }
    return 0;
}
static void es_child(void *t) { if (t && is_traced(t)) ps_add(&es, t); }
#define ES_MAX_LOGS 64
static size_t try_early(uint64_t applied_seq) {
    if (early_scan_max < 0) { const char *e = getenv("KX_GC_EARLY_SCAN"); early_scan_max = e && *e ? atoll(e) : EARLY_SCAN_MAX; }
    if (!early_scan_max) return 0;
    Log *pend[ES_MAX_LOGS]; size_t np = 0, entries = 0; uint64_t h;
    pthread_mutex_lock(&mu);
    h = handed;
    for (Log *l = q_head; l && np < ES_MAX_LOGS; l = l->next) { pend[np++] = l; entries += l->n; }
    int complete = np == q_len;
    pthread_mutex_unlock(&mu);
    (void)applied_seq;
    size_t freed = 0;
    Batch **pp = &cands;
    while (*pp) {
        Batch *b = *pp;
        if (b->tried || h <= b->valid_after) { pp = &b->next; continue; }
        b->tried = 1;
        if (!complete || (int64_t)entries > early_scan_max) { dbg_early_skip++; pp = &b->next; continue; }
        size_t n = b->nsets ? b->ends[b->nsets - 1] : 0;
        ps_clear(&es);
        for (size_t i = 0; i < n; i++) { ps_add(&es, b->members[i]); vtab(b->members[i])->trav(b->members[i], es_child); }
        int hit = 0;
        for (size_t j = 0; j < np && !hit; j++)
            for (size_t i = 0; i < pend[j]->n; i++) if (ps_has(&es, (void *)(pend[j]->a[i] & ~(uintptr_t)3))) { hit = 1; break; }
        if (hit) { dbg_early_hit++; pp = &b->next; continue; }
        dbg_early_ok++;
        *pp = b->next; if (cands_tail == b) cands_tail = NULL;
        if (!cands_tail) for (Batch *t = cands; t; t = t->next) cands_tail = t;
        size_t start = 0;
        for (size_t i = 0; i < b->nsets; i++) { freed += validate(b->first_id + i, (Members){ b->ends[i] - start, b->members + start }); start = b->ends[i]; }
        batch_free(b);
    }
    return freed;
}
static void publish_returns(void) {
    if (!c_ret.len) return;
    pthread_mutex_lock(&mu); stack_move(&ret_shared, &c_ret); pthread_mutex_unlock(&mu);
}
/* Stop-the-world drain (mutator waits): detect and validate until no garbage is left. */
static void full_cycle(void) {
    while (im_state && !im_step(INT64_MAX)) {}
    for (;;) {
        size_t freed = validate_ready(0, 1);
        if (c_roots.len || c_deferred.len || c_live_def.len) { detect(1); freed += validate_ready(0, 1); }
        gc_st.reclaimed += (int64_t)freed;
        if (!freed && !c_roots.len && !c_deferred.len && !c_live_def.len && !cands) break;
    }
}
/* Geometric major backoff for the incremental major (same rule as in collector_main). */
static void major_adapt(void) {
    int64_t found = dbg_members + dbg_dead - im_m0, work = c_traversed - im_w0;
    if (work > 64 * found) { if (major_ratio < MAJOR_RATIO_MAX) major_ratio *= 2; }
    else major_ratio = major_ratio_base;
}
static void *collector_main(void *arg) {
    (void)arg;
    { const char *e = getenv("KX_GC_SLICE_ROOTS"); if (e && *e) slice_roots = (size_t)atoll(e); } { const char *e = getenv("KX_GC_MAJOR_RATIO"); if (e && atoll(e) > 0) major_ratio = major_ratio_base = atoll(e); }   /* tests: majors sooner */
    start_helpers();
    pthread_mutex_lock(&mu);
    for (;;) {
        while (!q_head && !full_req && !shutting) {
            if (im_state) {   /* idle collector: advance the incremental major */
                pthread_mutex_unlock(&mu);
                int64_t td = rt_nanos(); int done = im_step(im_step_budget); dbg_t_detect += rt_nanos() - td;
                (void)done; publish_returns();
                pthread_mutex_lock(&mu); continue;
            }
            coll_quiet = 1; pthread_cond_wait(&cv_work, &mu);
        }
        coll_quiet = 0;
        if (q_head) {
            Log *l = q_head; q_head = l->next; if (!q_head) q_tail = NULL; q_len--; q_seen = q_len;
            pthread_cond_broadcast(&cv_done);
            pthread_mutex_unlock(&mu);
            /* No trace is running here, and every later read of a field sees the stores made before this
             * log was handed, so nothing can still reach memory freed before then. */
            for (size_t i = 0; i < l->frees.len; i++) free(l->frees.items[i]);
            l->frees.len = 0;
            int64_t ta = rt_nanos(); apply_log(l); dbg_logs++;
            if ((int64_t)c_live_def.len >= 4096 && ((int64_t)c_live_def.len * defer_flush >= c_stable_n || c_live_def.len >= DEFER_FLUSH_MAX)) flush_live_def();
            else if (c_zombies >= 4096 && c_zombies * 2 >= c_live_def.len + c_deferred.len) sweep_deferred();
            int64_t tb = rt_nanos(); size_t freed = validate_ready(l->seq, 0); freed += try_early(l->seq);
            int64_t tc = rt_nanos(); dbg_t_apply += tb - ta; dbg_t_valid += tc - tb;
            int64_t major_at = major_ratio * (c_stable_n > (int64_t)c_threshold ? c_stable_n : (int64_t)c_threshold);
            /* Carry-over (opt-in, KX_GC_CARRY_QUEUE): while the queue holds that many logs, only apply logs and
             * leave detection (roots stay buffered) for a later log, unless the buffer grew 8x past the
             * threshold. Detection work then never stacks up behind a full queue. */
            if (carry_q < 0) { const char *e = getenv("KX_GC_CARRY_QUEUE"); carry_q = e && *e ? atoll(e) : 0; }
            int behind = carry_q > 0 && (int64_t)q_seen >= carry_q && c_roots.len < 8 * c_threshold;
            if (incremental_major < 0) {
                const char *e = getenv("KX_GC_INC_MAJOR"); incremental_major = e && *e ? *e != '0' : 1;
                e = getenv("KX_GC_MAJOR_STEP"); im_step_budget = e && *e ? atoll(e) : MAJOR_STEP;
                e = getenv("KX_GC_SIDE_MINOR"); side_minors = e && *e ? *e != '0' : 1;
                e = getenv("KX_GC_MAJOR_STEP_US"); im_step_ns = (e && *e ? atoll(e) : MAJOR_STEP_US) * 1000;
            }
            if (im_state) {
                int64_t td = rt_nanos();
                /* the per-log major time slice scales with the log size, so the major's share of collector
                 * time does not grow when logs are short (16x more logs would mean 16x more major work per
                 * mutator op, starving apply/validate: +40% wall time on huge_live_churn) */
                int64_t slice = l->n < LOG_CAP ? im_step_ns * (int64_t)l->n / LOG_CAP : im_step_ns;
                if (im_step_ns > 0) { while (!im_step(512) && rt_nanos() - td < slice) {} }
                else im_step(im_step_budget);
                if (im_state && side_minors && c_roots.len >= c_threshold) side_minor();
                dbg_t_detect += rt_nanos() - td;
            }
            else if (incremental_major && !behind && c_deferred_new >= major_at) {
                dbg_majors++; gc_st.collections++; im_begin();
            }
            else if (!behind && (c_roots.len >= c_threshold || c_deferred_new >= major_at)) {
                size_t nroots = c_roots.len;
                int64_t m0 = dbg_members + dbg_dead, w0 = c_traversed;
                int major = c_deferred_new >= major_at;
                if (major) { pthread_mutex_lock(&mu); atomic_store(&c_in_major, 1); pthread_cond_broadcast(&cv_done); pthread_mutex_unlock(&mu); }
                int64_t td = rt_nanos(); detect(major);
                dbg_t_detect += rt_nanos() - td;
                gc_st.collections++;
                /* adaptive: traversal work mostly spent on live data -> detect less often */
                int64_t found = dbg_members + dbg_dead - m0, work = c_traversed - w0;
                if (major) {
                    /* old generation only when needed: a major that mostly re-traced live data makes the
                     * next one rarer (geometric backoff); one that found garbage resets the ratio */
                    if (work > 64 * found) { if (major_ratio < MAJOR_RATIO_MAX) major_ratio *= 2; }
                    else major_ratio = major_ratio_base;
                } else if (dbg_mn_roots += (int64_t)nroots, dbg_mn_found += found, dbg_mn_work += work, work > 4 * found + 2 * (int64_t)nroots) { if (c_threshold < C_MAX_THRESHOLD) c_threshold *= 2; }
                else if (c_threshold > c_min_threshold) { c_threshold /= 2; if (c_threshold < c_min_threshold) c_threshold = c_min_threshold; }
                /* a flush whose minor found (almost) only live data makes the next flush rarer (geometric
                 * backoff, lru); one that found garbage resets the ratio (cycles) */
                if (!major && c_after_flush) { c_after_flush = 0; if (work > 64 * found) { if (defer_flush < 4096) defer_flush *= 2; } else defer_flush = defer_flush_base; }
                if (!major) c_pure = found > 0 && work <= pure_ratio * found && c_stable_n < PURE_STABLE_MAX;
                log_cap_follow();
            }
            gc_st.reclaimed += (int64_t)freed;
            /* KX_GC_DEBUG peaks / KX_GC_TRACE: in-flight backlog (buffered roots, candidate members waiting for
             * their Delta test, dead objects not yet handed back, queued logs) */
            if (trace_q < 0) { const char *te = getenv("KX_GC_TRACE"), *de = getenv("KX_GC_DEBUG"); trace_q = (te && *te) ? 2 : (de && *de) ? 1 : 0; }
            if (trace_q) {
                size_t cm = 0; for (Batch *b = cands; b; b = b->next) cm += b->nsets ? b->ends[b->nsets - 1] : 0;
                if (c_threshold > dbg_thr_max) dbg_thr_max = c_threshold;
                if (c_roots.len > dbg_roots_max) dbg_roots_max = c_roots.len;
                if (cm > dbg_cand_max) dbg_cand_max = cm;
                if (q_seen > dbg_qseen_max) dbg_qseen_max = q_seen;
                if (trace_q == 2 && dbg_logs % 8 == 0)
                    fprintf(stderr, "epoch-trace: log=%lld log-cap=%zu live-traced=%lld roots=%zu cand-members=%zu ret=%zu ret-shared=%zu queued=%zu threshold=%zu\n", (long long)dbg_logs, (size_t)atomic_load(&log_cap), (long long)(atomic_load(&t_allocs) - atomic_load(&t_frees)), c_roots.len, cm, c_ret.len, ret_shared.len, q_seen, c_threshold);
            }
            publish_returns();
            pthread_mutex_lock(&mu);
            applied = l->seq;
            /* keep only as many spare logs as the queue may hold again; return the rest after a spike */
            if ((size_t)pool_len > max_queued + 2) { free(l->frees.items); free(l); } else { l->next = log_pool; log_pool = l; pool_len++; }
            if (q_len <= max_queued && atomic_load_explicit(&c_in_major, memory_order_relaxed)) atomic_store(&c_in_major, 0);
            pthread_cond_broadcast(&cv_done);
        } else if (full_req) {
            pthread_mutex_unlock(&mu);
            full_cycle();
            publish_returns();
            pthread_mutex_lock(&mu);
            full_req = 0; full_done++;
            pthread_cond_broadcast(&cv_done);
        } else break;
    }
    pthread_mutex_unlock(&mu);
    return NULL;
}

static void epoch_debug(void) {
    const char *e = getenv("KX_GC_DEBUG");
    if (e && *e) fprintf(stderr, "epoch: peaks boost=%zu threshold=%zu roots=%zu cand-members=%zu queue-seen=%zu minors roots=%lld found=%lld work=%lld\n", (size_t)atomic_load(&log_boost), dbg_thr_max, dbg_roots_max, dbg_cand_max, dbg_qseen_max, (long long)dbg_mn_roots, (long long)dbg_mn_found, (long long)dbg_mn_work);
    if (e && *e) fprintf(stderr, "epoch: deferred-live=%lld flushes=%lld swept=%lld epochs=%lld logs=%lld detections=%lld sets=%lld pass=%lld fail-delta=%lld fail-sigma=%lld dead=%lld majors=%lld stable=%lld deferred=%zu\n",
        (long long)dbg_deferred_live, (long long)dbg_flushes, (long long)dbg_swept, (long long)ep_epochs, (long long)dbg_logs, (long long)ep_detections, (long long)dbg_sets, (long long)dbg_pass, (long long)dbg_fail_delta, (long long)dbg_fail_sigma, (long long)dbg_dead, (long long)dbg_majors, (long long)c_stable_n, c_deferred.len);
    if (e && *e) fprintf(stderr, "epoch: collector apply=%.1fms validate=%.1fms detect=%.1fms (mark %.1f scan %.1f) threads=%d parallel=%lld (ns/visit ser %.1f par %.1f wake %.0f)\n", dbg_t_apply/1e6, dbg_t_valid/1e6, dbg_t_detect/1e6, dbg_t_mark/1e6, dbg_t_scan/1e6, n_threads, (long long)dbg_par_det, ns_ser, ns_par, par_wake_ns);
    if (e && *e) fprintf(stderr, "epoch: roots=%lld minor-visits=%lld major-visits=%lld members=%lld\n", (long long)dbg_roots_k, (long long)dbg_minor_visits, (long long)dbg_major_visits, (long long)dbg_members);
    if (e && *e) fprintf(stderr, "epoch: prom=%lld dem-touch=%lld held=%lld held-max=%lld major-steps=%lld side-minors=%lld side-visits=%lld early ok=%lld hit=%lld skip=%lld qmax=%zu q=%zu\n", (long long)dbg_prom, (long long)dbg_dem_touch, (long long)dbg_held, (long long)dbg_held_max, (long long)im_steps, (long long)dbg_side_minors, (long long)dbg_side_visits, (long long)dbg_early_ok, (long long)dbg_early_hit, (long long)dbg_early_skip, dbg_q_max, max_queued);
    if (e && *e) fprintf(stderr, "epoch: backpressure total=%.3fms max=%.3fms boundary max=%.3fms last collect=%.3fms\n", dbg_bp_ns/1e6, dbg_bp_max/1e6, dbg_bmax/1e6, dbg_exit_ns/1e6);
    if (e && *e) fprintf(stderr, "epoch: freed paced=%lld boundary=%lld keep=%lld madvised=%lld stack-released=%lld\n", (long long)dbg_paced, (long long)dbg_bfreed, (long long)boundary_keep, (long long)dbg_madvised, (long long)dbg_stack_released);
    if (e && *e) fprintf(stderr, "epoch: slabs release=%d released=%lld (%.1f MiB) madvise-calls=%lld reused=%lld pool-resident=%lld\n", slab_release, (long long)dbg_slab_released, dbg_slab_released * (double)PAGE / 1048576.0, (long long)dbg_slab_madv_calls, (long long)dbg_slab_reused, (long long)slab_pool_resident);
    if (e && *e) fprintf(stderr, "epoch: exit live-traced=%lld ret-pending=%zu roots=%zu deferred=%zu cands=%d\n", (long long)(atomic_load(&t_allocs) - atomic_load(&t_frees)), ret_local.len - ret_pos, c_roots.len, c_deferred.len, cands != NULL);
    if (e && *e) {
        size_t wk = 0; for (int i = 0; i < n_threads; i++) wk += workers[i].work.cap + workers[i].black.cap + workers[i].marked.cap;
        fprintf(stderr, "epoch: mem MiB slabs=%.1f logs=%lld(%.1f) batches-peak=%.1f stacks(cap): roots=%.1f deferred=%.1f work=%.1f ret=%.1f ret-shared=%.1f ret-local=%.1f im-seen=%.1f hold=%.1f cw=%.1f dying=%.1f workers=%.1f es=%.1f\n",
            dbg_slab_bytes / 1048576.0, (long long)dbg_log_allocs, dbg_log_allocs * (double)sizeof(Log) / 1048576.0, dbg_batch_peak / 1048576.0,
            c_roots.cap * 8 / 1048576.0, c_deferred.cap * 8 / 1048576.0, c_work.cap * 8 / 1048576.0, c_ret.cap * 8 / 1048576.0, ret_shared.cap * 8 / 1048576.0, ret_local.cap * 8 / 1048576.0,
            im_seen.cap * 8 / 1048576.0, c_hold.cap * 8 / 1048576.0, (cw_m.cap + cw_ends.cap) * 8 / 1048576.0, c_dying.cap * 8 / 1048576.0, wk * 8 / 1048576.0, es.cap * 8 / 1048576.0);
        fprintf(stderr, "epoch: mem MiB side-minor tab=%.1f stacks=%.1f\n", sm_cap * sizeof(SmEnt) / 1048576.0, (sm_work.cap + sm_black.cap + sm_roots.cap + sm_retry.cap) * 8 / 1048576.0);
    }
}
/* Program exit drains the queue only when someone looks at the heap afterwards: --leak-check
 * (RT_LEAKCHECK) and --alloc malloc (ASan / macOS leaks builds), or KX_GC_EXIT_DRAIN=1. Otherwise the
 * process exits with the queue as it is, and the OS reclaims the memory. */
#if defined(RT_LEAKCHECK) || defined(RT_PLAIN_MALLOC)
#define EXIT_DRAIN_DEFAULT 1
#else
#define EXIT_DRAIN_DEFAULT 0
#endif
static int exit_drain(void) {
    const char *e = getenv("KX_GC_EXIT_DRAIN");
    return e && *e ? *e != '0' : EXIT_DRAIN_DEFAULT;
}
/* Stop-the-world: hand off the log, wait for the collector, drain all garbage. Called only at exit. */
void rt_gc_collect(void) {
    if (in_boundary) return;
    if (!exit_drain()) { epoch_debug(); return; }
    in_boundary = 1;
    int64_t t0 = rt_nanos();
    for (int round = 0;; round++) {
        int had_ops = cur && (cur->n || cur->frees.len);
        handoff();
        pthread_mutex_lock(&mu);
        while (q_head) pthread_cond_wait(&cv_done, &mu);
        uint64_t want = full_done + 1; full_req = 1; pthread_cond_signal(&cv_work);
        while (full_done < want) pthread_cond_wait(&cv_done, &mu);
        stack_move(&ret_local, &ret_shared);
        m_applied = applied;
        pthread_mutex_unlock(&mu);
        size_t returned = ret_local.len - ret_pos;
        process_returns(-1, t0, 0);
        if (!had_ops && !returned && !(cur && (cur->n || cur->frees.len))) break;
    }
    free_held(1);   /* the queue is empty and every handed log applied */
    dbg_exit_ns = rt_nanos() - t0;
    note_pause(t0);
    in_boundary = 0;
    epoch_debug();
}
const char *rt_gc_name(void) { return "epoch"; }
void rt_gc_stats(KxGcStats *out) {
    pthread_mutex_lock(&mu);   /* collector-side counters are updated under no lock; read them quiescent */
    *out = gc_st;
    pthread_mutex_unlock(&mu);
}
