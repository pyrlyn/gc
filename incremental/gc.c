// Incremental cycle collector (newkotlinc --gc=incremental): the default GC (Perceus-style RC + Bacon & Rajan
// trial deletion) with the root buffer processed in slices under a per-step time budget.
//
// A step takes buffered roots in slices of CC_SLICE and runs MarkRoots / ScanRoots / CollectRoots on each
// slice (trial deletion is correct for any subset of the candidate roots). After each slice it checks the
// budget (KX_GC_BUDGET_US, default 500 us); unprocessed roots stay buffered for the next step, which runs
// after CC_STEP_ROOTS more candidate roots. A garbage object that is still in the buffer (a later slice's
// root) is released but not freed: it is left black with count zero, exactly like rt_cc_dead, and its
// own slice frees it. Program exit and rt_gc_collect run all slices without a budget.
// Bound: one slice is atomic, so a slice whose roots reach a huge live graph can still exceed the budget;
// when the first slice of a step already does, the step finishes in one pass (as the default GC would),
// because every further slice would re-trace the same graph.
#include <stdint.h>
#include <stdlib.h>
#include "../common/regions.inc"
#include "../common/object.inc"
#define CC_CLAIM_SKIPS_BUFFERED 0   /* later slices' roots are claimed too; their own slice frees them */
#include "../common/trial_deletion.inc"

#define CC_SLICE 64                       /* roots per atomic slice */
#define CC_STEP_ROOTS 2000                /* new roots before an unfinished step resumes */
#define CC_DEFAULT_BUDGET_US 500          /* KX_GC_BUDGET_US default */

static PtrStack cc_roots;                 /* buffered possible roots (each has the buffered bit set) */
static size_t cc_trigger = CC_THRESHOLD;  /* buffer length that starts the next step */
static int cc_running;                    /* re-entrancy guard */
static int64_t cc_budget_ns = -1;         /* per-step budget, read lazily from KX_GC_BUDGET_US */
static KxGcStats gc_stats;

static void collect_step(int full);

void rt_cc_possible_root(void *obj) {
    set_color(obj, PURPLE);
    if (is_buffered(obj)) return;
    set_buffered(obj);
    stack_push(&cc_roots, obj);
    if (cc_roots.len >= cc_trigger && !cc_running && !rt_rel_draining) collect_step(0);
}

/* Count reached zero and the children were released: free now, unless the root buffer still holds it. */
void rt_cc_dead(void *obj) {
    set_color(obj, BLACK);
    if (!is_buffered(obj)) vtab(obj)->freemem(obj);
}

/* MarkRoots for one slice. Keeps (compacted to the front of `roots`) the roots that are still PURPLE
 * with a live count and mark-grays them. Every other root leaves the buffer here: it was either
 * re-blackened by a later increment (still live, nothing to do) or died while buffered (BLACK, count 0),
 * in which case this is the moment it gets freed. Returns the number of roots kept. */
static size_t mark_roots(void **roots, size_t n) {
    size_t kept = 0;
    for (size_t i = 0; i < n; i++) {
        void *root = roots[i];
        if (color(root) == PURPLE && ref_count(root) > 0) {
            mark_gray(root);
            roots[kept++] = root;
            continue;
        }
        clear_buffered(root);
        if (color(root) == BLACK && ref_count(root) == 0) vtab(root)->freemem(root);
    }
    return kept;
}

/* ScanRoots + CollectRoots over the kept roots, in the order of Bacon & Rajan: every root is scanned
 * before any root leaves the buffer, and only then is garbage collected from each root. */
static void scan_and_collect_roots(void **roots, size_t kept) {
    for (size_t i = 0; i < kept; i++) scan(roots[i]);
    for (size_t i = 0; i < kept; i++) clear_buffered(roots[i]);
    for (size_t i = 0; i < kept; i++) collect_white(roots[i]);
}

/* Releases the acyclic children and untraced fields of everything CollectWhite found, then frees it. Garbage
 * that is still buffered (a root of a later slice) is left BLACK with count 0 and freed by that slice's
 * mark_roots. Returns the number of objects freed now. */
static size_t free_garbage(void) {
    release_acyclic_children();
    for (size_t i = 0; i < cc_garbage.len; i++) vtab(cc_garbage.items[i])->relo(cc_garbage.items[i]);
    size_t freed = 0;
    for (size_t i = 0; i < cc_garbage.len; i++) {
        void *obj = cc_garbage.items[i];
        if (is_buffered(obj)) continue;
        vtab(obj)->freemem(obj);
        freed++;
    }
    cc_garbage.len = 0;
    return freed;
}

/* Full trial deletion over one slice roots[0..n) (all buffered, PURPLE or BLACK). Returns objects freed. */
static size_t collect_slice(void **roots, size_t n) {
    size_t kept = mark_roots(roots, n);
    scan_and_collect_roots(roots, kept);
    return free_garbage();
}

static int64_t budget_ns(void) {
    if (cc_budget_ns < 0) {
        const char *env = getenv("KX_GC_BUDGET_US");
        cc_budget_ns = (env && *env ? atoll(env) : CC_DEFAULT_BUDGET_US) * 1000;
    }
    return cc_budget_ns;
}

static inline size_t min_size(size_t a, size_t b) { return a < b ? a : b; }

/* Runs slices over roots[0..len) and returns how many roots were processed.
 * Bounded mode stops after the first slice that ends over budget, with one exception: if the very first
 * slice is already over budget, the cost is a large graph shared by the roots (re-traced by every slice),
 * so slicing would multiply work without shortening the pause; the step then takes all remaining roots
 * as one slice, as does an unbounded step from the start. */
static size_t run_slices(void **roots, size_t len, int unbounded, int64_t start, int64_t budget, size_t *reclaimed) {
    size_t done = 0;
    while (done < len) {
        size_t n = unbounded ? len - done : min_size(len - done, CC_SLICE);
        *reclaimed += collect_slice(roots + done, n);
        done += n;
        if (unbounded || rt_nanos() - start <= budget) continue;
        int first_slice = done == n;
        if (!first_slice) break;
        unbounded = 1;
    }
    return done;
}

/* Puts roots that a bounded step did not reach back into the (fresh) buffer; they keep the buffered bit.
 * A live root that an earlier slice scanned black leaves the buffer now, as its own slice would have done.
 * It must not stay: once the program drops it, a step started while its fields are being released would
 * take the black count-zero object for a dead one (mark_roots) and free it under the release. */
static void requeue_roots(void **roots, size_t from, size_t len) {
    for (size_t i = from; i < len; i++) {
        void *root = roots[i];
        if (color(root) == BLACK && ref_count(root) > 0) clear_buffered(root);
        else stack_push(&cc_roots, root);
    }
}

/* Next trigger: an unfinished step resumes after CC_STEP_ROOTS more roots, otherwise the adaptive threshold. */
static void schedule_next_step(size_t roots_left) {
    cc_trigger = roots_left ? cc_roots.len + CC_STEP_ROOTS : cc_threshold;
}

/* One collector step: slices until the buffer is empty or (unless `full`) the budget is spent.
 * The buffer is detached first, so roots buffered while freeing garbage go to a fresh buffer. */
static void collect_step(int full) {
    if (cc_running || cc_roots.len == 0) return;
    cc_running = 1;
    int64_t budget = budget_ns();
    int64_t start = rt_nanos();
#ifdef RT_LEAKCHECK
    cc_runs++;
#endif
    PtrStack roots = cc_roots; cc_roots = (PtrStack){0};
    size_t reclaimed = 0;
    cc_traced = 0;
    size_t done = run_slices(roots.items, roots.len, full, start, budget, &reclaimed);
    requeue_roots(roots.items, done, roots.len);
    free(roots.items);
    adapt_threshold(reclaimed);
    schedule_next_step(roots.len - done);
    gc_stats.collections++;
    gc_stats.reclaimed += (int64_t)reclaimed;
    stats_add_pause(&gc_stats, rt_nanos() - start);
    cc_running = 0;
}

void rt_gc_collect(void) { while (cc_roots.len && !cc_running) collect_step(1); }
const char *rt_gc_name(void) { return "incremental"; }
void rt_gc_stats(KxGcStats *out) { *out = gc_stats; }
