// Boehm-Demers-Weiser conservative collector (bdwgc) as a KotlinX GC backend (newkotlinc --gc=boehm).
// Reference counting stays on (generated fast paths free objects at count zero with GC_FREE); bdwgc
// reclaims what RC cannot: unreachable cycles of possibly cyclic objects. Acyclic objects and runtime
// storage that may hold references are uncollectable but scanned, so every reference to a traced object
// is visible to bdwgc. A finalizer on each traced object releases its untraced (acyclic) fields when
// bdwgc reclaims it. bdwgc comes from mise (conda:bdw-gc, see mise.toml); gc/boehm/config.sh finds it.
#include <gc.h>
#include "kxgc.h"

static KxGcStats gc_st;

/* Every bdwgc collection (implicit or explicit) is timed through the collection event callback. */
static int64_t collection_start_ns;
static void on_collection_event(GC_EventType e) {
    if (e == GC_EVENT_START) collection_start_ns = rt_nanos();
    else if (e == GC_EVENT_END) {
        int64_t dt = rt_nanos() - collection_start_ns;
        gc_st.pause_ns_total += dt; if (dt > gc_st.pause_ns_max) gc_st.pause_ns_max = dt;
        rt_gc_note_pause(dt);
    }
}
__attribute__((constructor(101))) static void boehm_init(void) { GC_INIT(); GC_set_on_collection_event(on_collection_event); }

/* Panics on allocation failure, like every other allocator in the runtime. */
static void *check_alloc(void *p) { if (!p) rt_panic("OutOfMemoryError"); return p; }
/* vtable pointer: word 1 of every object (kxgc.h). */
static inline KxVTab *vtab(void *p) { return *(KxVTab **)((char *)p + 8); }

/* Acyclic objects: uncollectable (freed only by RC via rt_free) but scanned, so references from them
 * keep traced objects alive. */
void *rt_alloc(int64_t size) {
#ifdef RT_LEAKCHECK
    rt_leak_obj(1);
#endif
    return check_alloc(GC_MALLOC_UNCOLLECTABLE((size_t)size));
}
void rt_free(void *p, int64_t size) {
    (void)size;
#ifdef RT_LEAKCHECK
    rt_leak_obj(-1);
#endif
    GC_FREE(p);
}
/* Acyclic child of an unreachable object: drop that object's reference (traced children die with it). */
static void release_acyclic(void *t) { if (t && !vtab(t)->cyclic) vtab(t)->rel(t); }
/* Unreachable cycle member: release the acyclic objects and other fields it still owns; bdwgc frees the memory. */
static void on_unreachable(void *p, void *cd) {
    (void)cd;
    rt_trav_mode = RT_TRAV_RELEASE;   /* a list traversed here gives its elements up: relo frees only memory */
    vtab(p)->trav(p, release_acyclic);
    rt_trav_mode = RT_TRAV_SCAN;
    vtab(p)->relo(p);
    gc_st.reclaimed++;
#ifdef RT_LEAKCHECK
    rt_leak_obj(-1);
#endif
}
/* Possibly cyclic objects: collectable. If RC frees one first, rt_free_trace unregisters the finalizer;
 * otherwise bdwgc found it unreachable and on_unreachable runs before the memory is reused. */
void *rt_alloc_trace(int64_t size) {
#ifdef RT_LEAKCHECK
    rt_leak_obj(1);
#endif
    void *p = check_alloc(GC_MALLOC((size_t)size));
    GC_REGISTER_FINALIZER_NO_ORDER(p, on_unreachable, NULL, NULL, NULL);
    return p;
}
void rt_free_trace(void *p, int64_t size) {
    (void)size;
#ifdef RT_LEAKCHECK
    rt_leak_obj(-1);
#endif
    GC_REGISTER_FINALIZER_NO_ORDER(p, NULL, NULL, NULL, NULL);
    GC_FREE(p);
}
/* Never sets the buffered bit: generated code frees every traced object at count zero. */
void rt_cc_possible_root(void *p) { (void)p; }
void rt_cc_dead(void *p) { vtab(p)->freemem(p); }

void *rt_gc_mem_alloc(size_t n) { return check_alloc(GC_MALLOC_UNCOLLECTABLE(n ? n : 1)); }
void *rt_gc_mem_calloc(size_t n) { return check_alloc(GC_MALLOC_UNCOLLECTABLE(n ? n : 1)); } /* bdwgc zeroes */
void *rt_gc_mem_realloc(void *p, size_t n) {
    if (!p) return rt_gc_mem_alloc(n);
    return check_alloc(GC_REALLOC(p, n ? n : 1)); /* keeps the uncollectable kind */
}
void rt_gc_mem_free(void *p) { if (p) GC_FREE(p); }

void rt_gc_collect(void) {
    GC_gcollect();
    GC_invoke_finalizers();
}
const char *rt_gc_name(void) { return "boehm"; }
void rt_gc_stats(KxGcStats *out) { *out = gc_st; out->collections = (int64_t)GC_get_gc_no(); }

/* Deferred-RC hooks (kxgc.h): never called for this implementation (its caps do not list "deferred"). */
void rt_gc_log_inc(void *p) { (void)p; rt_panic("rt_gc_log_inc without deferred RC"); }
void rt_gc_log_dec(void *p) { (void)p; rt_panic("rt_gc_log_dec without deferred RC"); }
void rt_gc_write_barrier(void *obj) { (void)obj; }
void rt_gc_root_hint(void *p) { (void)p; }   /* bdwgc finds unreachable cycles by tracing */
void rt_gc_free_later(void *p) { (void)p; rt_panic("rt_gc_free_later without deferred RC"); }
