// Unit tests of the KotlinX GC interface (kxgc.h), linked with the runtime and one implementation:
//   clang -I compiler/gc [-DKX_CAP_CYCLES] [-DKX_CAP_PRECISE] gc_unit.c runtime.c gc/<name>/gc.c
// Objects are hand-built the way generated code lays them out: { header, vtable, fields... }.
#include <stdio.h>
#include <string.h>
#include "kxgc.h"

static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

typedef struct Obj { uint64_t hdr; KxVTab *vt; struct Obj *next; int64_t val; } Obj;
static int64_t freed, released_other;
static void obj_free(void *p) { freed++; rt_free_trace(p, sizeof(Obj)); }
static void obj_trav(void *p, kx_visit_fn f) { f(((Obj *)p)->next); }
static void obj_relo(void *p) { (void)p; released_other++; }
static void obj_rel(void *p);
static KxVTab cyc_vt = { obj_rel, obj_trav, obj_relo, obj_free, (void *)1 };
/* Generated-code release path for a cyclic class (NativeBackend.kt @rel.C / @relz.C). */
static void obj_rel(void *p) {
    if (!p) return;
    Obj *o = p; uint64_t c1 = o->hdr - 1;
    if ((c1 & KX_CNT_MASK) != 0) {
        if (c1 & KX_BUF_BIT) { o->hdr = c1 | (3ULL << KX_COLOR_SHIFT); return; }
        o->hdr = c1; rt_cc_possible_root(p); return;
    }
    o->hdr = c1;
    obj_rel(o->next); obj_relo(p);
    if (o->hdr & KX_BUF_BIT) { o->hdr &= ~(3ULL << KX_COLOR_SHIFT); return; }
    obj_free(p);
}
static Obj *new_obj(int64_t v) { Obj *o = rt_alloc_trace(sizeof(Obj)); o->hdr = 1; o->vt = &cyc_vt; o->next = NULL; o->val = v; return o; }

int main(void) {
    printf("gc=%s\n", rt_gc_name());
    /* acyclic region */
    for (int i = 0; i < 100000; i++) { int64_t *p = rt_alloc(48); p[0] = 1; p[5] = i; CHECK(p[5] == i); rt_free(p, 48); }
    /* acyclic chain freed by RC */
    freed = 0;
    { Obj *a = new_obj(1), *b = new_obj(2); a->next = b; obj_rel(a); CHECK(freed == 2); }
    /* shared object survives until the last reference */
    freed = 0;
    { Obj *a = new_obj(1); a->hdr++; obj_rel(a); CHECK(freed == 0); CHECK(a->val == 1); obj_rel(a); rt_gc_collect(); CHECK(freed == 1); }
    /* reachable cycle survives a collection */
    { Obj *a = new_obj(10), *b = new_obj(20); a->next = b; b->next = a; b->hdr++; /* a: 1 (b), +1 local */ a->hdr++;
      obj_rel(a); /* drop local: a reachable only from b, b from a and a local */
      rt_gc_collect(); CHECK(a->val == 10 && b->val == 20 && a->next == b);
#ifdef KX_CAP_CYCLES
      freed = 0; released_other = 0;
      obj_rel(b); /* last outside reference: a<->b is garbage */
      for (int i = 0; i < 3; i++) rt_gc_collect();
      KxGcStats st; rt_gc_stats(&st);
      CHECK(st.collections > 0);
#ifdef KX_CAP_PRECISE /* a conservative collector may still see a or b in a dead stack slot */
      CHECK(released_other >= 2 || freed >= 2);
#endif
#endif
    }
    /* runtime storage hooks */
    { int64_t *m = rt_gc_mem_calloc(64); for (int i = 0; i < 8; i++) CHECK(m[i] == 0);
      m[7] = 42; m = rt_gc_mem_realloc(m, 4096); CHECK(m[7] == 42); rt_gc_mem_free(m);
      void *z = rt_gc_mem_realloc(NULL, 16); CHECK(z != NULL); rt_gc_mem_free(z); }
#ifdef KX_CAP_CYCLES
    /* no collection starts while deferred releases run, however many roots are buffered */
    { enum { N = 300000 }; static Obj *objs[N]; KxGcStats before, during;
      for (int i = 0; i < N; i++) { objs[i] = new_obj(i); objs[i]->hdr++; }
      rt_gc_stats(&before);
      rt_rel_draining = 1;
      for (int i = 0; i < N; i++) obj_rel(objs[i]);
      rt_rel_draining = 0;
      rt_gc_stats(&during); CHECK(during.collections == before.collections);
      for (int i = 0; i < N; i++) { obj_rel(objs[i]); objs[i] = NULL; } /* bdwgc would scan a dangling pointer */
      rt_gc_collect(); }
#endif
    /* stress: many self cycles */
#ifdef KX_CAP_CYCLES
    for (int i = 0; i < 200000; i++) { Obj *s = new_obj(i); s->next = s; s->hdr++; obj_rel(s); }
    rt_gc_collect();
    { KxGcStats s1; rt_gc_stats(&s1); CHECK(s1.reclaimed >= 190000); }
#endif
    KxGcStats st; rt_gc_stats(&st);
    printf("collections=%lld reclaimed=%lld pause_max_us=%lld\n", (long long)st.collections, (long long)st.reclaimed, (long long)(st.pause_ns_max / 1000));
    if (fails) { printf("UNIT FAILED (%d)\n", fails); return 1; }
    printf("UNIT OK\n");
    return 0;
}
