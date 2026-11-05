// Object header and vtable accessors plus a growable pointer stack, shared by the cycle-collecting
// RC implementations (default, incremental). Included by exactly one gc.c, after regions.inc, and by the
// runtime for its release stack (rt_rel_defer).
//
// Header word (word 0 of every object, see kxgc.h):
//
//   63            35   34        33  32   31                      0
//   +---------------+----------+-------+-------------------------+
//   | unused (0)    | buffered | color |    reference count      |
//   +---------------+----------+-------+-------------------------+
//
// Invariants the collector relies on:
//   * Only objects of possibly cyclic classes (vtable->cyclic != NULL) are ever colored or buffered.
//   * buffered == 1  <=>  the object is in the root buffer (or in the root array of a running
//     collection). A buffered object is never freed by generated code or rt_cc_dead; whoever removes
//     it from the buffer (MarkRoots) clears the bit and becomes responsible for freeing it.
//   * Outside a collection every object is BLACK (in use / free candidate) or PURPLE (possible root).
//     GRAY and WHITE exist only while a collection runs.
#include <stdint.h>
#include <stdlib.h>

/* Colors of the Bacon & Rajan synchronous cycle collector (header bits 32-33). */
enum {
    BLACK = 0,  /* in use, or freed by RC; the color generated code leaves on a fresh object */
    GRAY = 1,   /* MarkGray visited it: internal references have been trial-deleted */
    WHITE = 2,  /* Scan found count 0 after trial deletion: member of a garbage cycle */
    PURPLE = 3, /* possible root: decremented to a non-zero count */
};
#define COLOR_MASK (3ULL << KX_COLOR_SHIFT)
#define VTAB_OFFSET 8 /* byte offset of the vtable pointer (word 1) */

typedef kx_visit_fn visit_fn;
typedef KxVTab VTab;

static inline VTab *vtab(void *obj) { return *(VTab **)((char *)obj + VTAB_OFFSET); }
static inline uint64_t *header(void *obj) { return (uint64_t *)obj; }
static inline int is_cyclic(void *obj) { return vtab(obj)->cyclic != NULL; }
static inline uint64_t ref_count(void *obj) { return *header(obj) & KX_CNT_MASK; }
static inline int color(void *obj) { return (int)((*header(obj) & COLOR_MASK) >> KX_COLOR_SHIFT); }
static inline void set_color(void *obj, int c) { *header(obj) = (*header(obj) & ~COLOR_MASK) | ((uint64_t)c << KX_COLOR_SHIFT); }
static inline int is_buffered(void *obj) { return (*header(obj) & KX_BUF_BIT) != 0; }
static inline void set_buffered(void *obj) { *header(obj) |= KX_BUF_BIT; }
static inline void clear_buffered(void *obj) { *header(obj) &= ~KX_BUF_BIT; }

/* Growable LIFO of object pointers (root buffer, traversal work lists, garbage list). */
#define PTR_STACK_INITIAL_CAPACITY 256
typedef struct { void **items; size_t len, cap; } PtrStack;
static void stack_push(PtrStack *s, void *obj) {
    if (s->len == s->cap) {
        s->cap = s->cap ? s->cap * 2 : PTR_STACK_INITIAL_CAPACITY;
        s->items = realloc(s->items, s->cap * sizeof *s->items);
        if (!s->items) rt_panic("OutOfMemoryError");
    }
    s->items[s->len++] = obj;
}
static inline void *stack_pop(PtrStack *s) { return s->items[--s->len]; }

/* Adds one collector pause to the statistics. */
static inline void stats_add_pause(KxGcStats *st, int64_t pause_ns) {
    st->pause_ns_total += pause_ns;
    if (pause_ns > st->pause_ns_max) st->pause_ns_max = pause_ns;
    rt_gc_note_pause(pause_ns);
}
