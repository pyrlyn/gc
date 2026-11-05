// Per-operation mutator cost of the GC interface (kxgc.h), as generated code issues it for a possibly cyclic
// class. Isolates what the lru benchmark does per get(): retain/release of a live object, a reference store
// with its barrier, allocate + drop, and an LRU move-to-front. Build/run: ./ops.sh (epoch perceus boehm).
//   -DDEFERRED: epoch code shape (rt_gc_log_inc / rt_gc_log_dec / release store + rt_gc_write_barrier);
//   otherwise inline RC as for default/boehm (NativeBackend.kt @rel.C).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kxgc.h"

typedef struct Obj { uint64_t hdr; KxVTab *vt; struct Obj *prev, *next; int64_t val; } Obj;
static void obj_free(void *p) { rt_free_trace(p, sizeof(Obj)); }
static void obj_trav(void *p, kx_visit_fn f) { f(((Obj *)p)->prev); f(((Obj *)p)->next); }
static void obj_relo(void *p) { (void)p; }
static void obj_rel(void *p);
static KxVTab vt = { obj_rel, obj_trav, obj_relo, obj_free, (void *)1 };
#ifdef DEFERRED
#define RETAIN(p) rt_gc_log_inc(p)
#define RELEASE(p) rt_gc_log_dec(p)
static void obj_rel(void *p) { rt_gc_log_dec(p); }
#define STORE(o, f, v) do { Obj *_v = (v), *_o = (o); RETAIN(_v); Obj *_old = _o->f; \
    __atomic_store_n(&_o->f, _v, __ATOMIC_RELEASE); rt_gc_write_barrier(_o); RELEASE(_old); } while (0)
#else
static __attribute__((noinline)) void obj_rel(void *p) {
    if (!p) return;
    Obj *o = p; uint64_t c1 = o->hdr - 1;
    if ((c1 & KX_CNT_MASK) != 0) {
        if (c1 & KX_BUF_BIT) { o->hdr = c1 | (3ULL << KX_COLOR_SHIFT); return; }
        o->hdr = c1 | (3ULL << KX_COLOR_SHIFT); rt_cc_possible_root(p); return;
    }
    o->hdr = c1; obj_rel(o->prev); obj_rel(o->next); obj_relo(p);
    if (o->hdr & KX_BUF_BIT) { o->hdr &= ~(3ULL << KX_COLOR_SHIFT); return; }
    obj_free(p);
}
#define RETAIN(p) do { Obj *_r = (p); if (_r) _r->hdr++; } while (0)
#define RELEASE(p) obj_rel(p)
#define STORE(o, f, v) do { Obj *_v = (v), *_o = (o); RETAIN(_v); Obj *_old = _o->f; _o->f = _v; RELEASE(_old); } while (0)
#endif
static Obj *new_obj(int64_t v) { Obj *o = rt_alloc_trace(sizeof(Obj)); o->hdr = 1; o->vt = &vt; o->prev = o->next = NULL; o->val = v; return o; }

static volatile int64_t sink;
static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }

/* 1: retain + release of a live object (a local copy of a field) */
static void op_rc(int64_t n, Obj **live, int nl) { for (int64_t i = 0; i < n; i++) { Obj *o = live[i & (nl - 1)]; RETAIN(o); sink += o->val; RELEASE(o); } }
/* 2: reference store into a live object's field (retain new, barrier, release old) */
static void op_store(int64_t n, Obj **live, int nl) { for (int64_t i = 0; i < n; i++) { Obj *o = live[i & (nl - 1)]; STORE(o, next, live[(i * 7 + 3) & (nl - 1)]); } }
/* 3: allocate and drop an object (young garbage, acyclic shape) */
static void op_alloc(int64_t n, Obj **live, int nl) { (void)live; (void)nl; for (int64_t i = 0; i < n; i++) { Obj *o = new_obj(i); sink += o->val; RELEASE(o); } }
/* 4: LRU move-to-front of a random node in a live doubly linked list (2 locals + 4..6 stores) */
static Obj *head, *tail;
static void unlink_(Obj *e) { Obj *p = e->prev, *n = e->next; RETAIN(p); RETAIN(n);
    if (!p) { Obj *old = head; RETAIN(n); head = n; RELEASE(old); } else STORE(p, next, n);
    if (!n) { Obj *old = tail; RETAIN(p); tail = p; RELEASE(old); } else STORE(n, prev, p);
    RELEASE(p); RELEASE(n); }
static void front(Obj *e) { STORE(e, prev, (Obj *)NULL); STORE(e, next, head); Obj *h = head; if (!h) { RETAIN(e); tail = e; } else STORE(h, prev, e); RETAIN(e); Obj *old = head; head = e; RELEASE(old); }
static void op_lru(int64_t n, Obj **live, int nl) { uint64_t x = 1; for (int64_t i = 0; i < n; i++) { x = x * 6364136223846793005ULL + 1442695040888963407ULL; Obj *e = live[(x >> 33) & (nl - 1)]; if (e->prev) { unlink_(e); front(e); } } }

typedef void (*op_fn)(int64_t, Obj **, int);
int main(int argc, char **argv) {
    int64_t n = argc > 1 ? atoll(argv[1]) : 4000000; int nl = 1 << 16;
    Obj **live = rt_gc_mem_alloc(sizeof(Obj *) * nl);   /* scanned by boehm */
    const char *only = argc > 2 ? argv[2] : NULL;
    for (int i = 0; i < nl; i++) live[i] = new_obj(i);   /* each held by `live` (count 1) */
    for (int i = 0; i < nl; i++) front(live[i]);
    struct { const char *name; op_fn f; } ops[] = { {"rc_pair", op_rc}, {"field_store", op_store}, {"alloc_drop", op_alloc}, {"lru_move", op_lru} };
    for (size_t k = 0; k < sizeof ops / sizeof *ops; k++) {
        if (only && strcmp(only, ops[k].name)) continue;
        double r[5];
        for (int rep = 0; rep < 5; rep++) { int64_t t0 = rt_nanos(); ops[k].f(n, live, nl); r[rep] = (double)(rt_nanos() - t0) / (double)n; }
        qsort(r, 5, sizeof *r, cmp);
        printf("%s %s %.2f\n", rt_gc_name(), ops[k].name, r[2]);
    }
    KxGcStats st; rt_gc_stats(&st);
    printf("%s pause_ms %.1f\n", rt_gc_name(), st.pause_ns_total / 1e6);
    return 0;
}
