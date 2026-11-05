// Run with KX_GC_BUDGET_US=0: every step is over budget on its first slice and must finish in one pass.
// The roots are garbage cycles that all point into one live ring. A live root is dropped once a slice has
// scanned it black, but these stay PURPLE, so each further 64-root slice would re-trace the whole ring.
#include <stdio.h>
#include <stdlib.h>
#include "kxgc.h"

enum { RING = 20000, ROOTS = 12000, MAX_TRAV = 10 * RING };

typedef struct Obj { uint64_t hdr; KxVTab *vt; struct Obj *a, *b; } Obj;
static int64_t trav_calls, freed;
static void obj_trav(void *p, kx_visit_fn f) { trav_calls++; f(((Obj *)p)->a); f(((Obj *)p)->b); }
static void obj_relo(void *p) { (void)p; }
static void obj_free(void *p) { freed++; rt_free_trace(p, sizeof(Obj)); }
static KxVTab vt = { NULL, obj_trav, obj_relo, obj_free, (void *)1 };
static Obj *new_obj(uint64_t count) { Obj *o = rt_alloc_trace(sizeof(Obj)); o->hdr = count; o->vt = &vt; o->a = o->b = NULL; return o; }

int main(void) {
    static Obj *ring[RING];
    for (int i = 0; i < RING; i++) ring[i] = new_obj(2);   /* the array's reference + the previous node's */
    for (int i = 0; i < RING; i++) ring[i]->a = ring[(i + 1) % RING];
    for (int i = 0; i < ROOTS; i++) {
        Obj *g = new_obj(2);                               /* the local reference + its own a */
        g->a = g; g->b = ring[0]; ring[0]->hdr++;
        g->hdr--; rt_cc_possible_root(g);
    }
    rt_gc_collect();
    if (freed != ROOTS || (ring[0]->hdr & KX_CNT_MASK) != 2 || trav_calls > MAX_TRAV) {
        fprintf(stderr, "freed=%lld of %d, ring[0] count=%llu, trav=%lld (max %d)\n", (long long)freed, ROOTS,
                (unsigned long long)(ring[0]->hdr & KX_CNT_MASK), (long long)trav_calls, MAX_TRAV);
        return 1;
    }
    return 0;
}
