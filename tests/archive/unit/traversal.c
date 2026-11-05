/* Include the collector to check traversal scratch space as well as public GC behavior.
 * Build with -DTEST_INCREMENTAL for the other consumer of trial_deletion.inc. */
#ifdef TEST_INCREMENTAL
#include "../../incremental/gc.c"
#else
#include "../../perceus/gc.c"
#endif

#include <assert.h>

enum { FANOUT = 64 };
typedef struct Node { uint64_t hdr; KxVTab *vt; struct Node *edges[FANOUT]; } Node;
static size_t freed, released, visits;
static void node_rel(void *p) { (void)p; abort(); } /* All edges in this test are traced. */
static void node_free(void *p) { freed++; rt_free_trace(p, sizeof(Node)); }
static void node_relo(void *p) { (void)p; released++; }
static void node_trav(void *p, kx_visit_fn visit) {
    visits++;
    Node *n = p;
    for (size_t i = 0; i < FANOUT; i++) visit(n->edges[i]);
}
static KxVTab node_vt = { node_rel, node_trav, node_relo, node_free, (void *)1 };

static Node *node_new(void) {
    Node *n = rt_alloc_trace(sizeof *n);
    *n = (Node){ .vt = &node_vt };
    return n;
}
static void edge(Node *from, size_t slot, Node *to) {
    from->edges[slot] = to;
    to->hdr++;
}

int main(int argc, char **argv) {
    size_t count = argc > 1 ? (size_t)atoll(argv[1]) : 4096;
    assert(count >= 3);
    Node **nodes = malloc(count * sizeof *nodes);
    assert(nodes);
    for (size_t i = 0; i < count; i++) nodes[i] = node_new();
    for (size_t i = 0; i < count; i++)
        for (size_t j = 0; j < FANOUT; j++) edge(nodes[i], j, nodes[(i + 1) % count]);
    /* A late external reference restores every internal edge, including duplicates. */
    nodes[count - 1]->hdr++;
    rt_cc_possible_root(nodes[0]);
    rt_gc_collect();
    assert(!freed && !released && visits == 3 * count - 1);
    for (size_t i = 0; i < count; i++) {
        assert(ref_count(nodes[i]) == FANOUT + (i == count - 1));
        assert(color(nodes[i]) == BLACK && !is_buffered(nodes[i]));
    }
    nodes[count - 1]->hdr--;
    rt_cc_possible_root(nodes[0]);
    rt_gc_collect();
    assert(freed == count && released == count && visits == 6 * count - 1);
    free(nodes);

    /* ScanBlack can restore a sibling that Scan has queued but not yet visited. */
    Node *a = node_new(), *b = node_new(), *c = node_new();
    edge(a, 0, b); edge(a, 1, c); edge(c, 0, b); edge(b, 0, a);
    c->hdr++;
    rt_cc_possible_root(a);
    rt_gc_collect();
    assert(freed == count && ref_count(a) == 1 && ref_count(b) == 2 && ref_count(c) == 2);
    assert(color(a) == BLACK && color(b) == BLACK && color(c) == BLACK);
    c->hdr--;
    rt_cc_possible_root(c);
    rt_gc_collect();
    assert(freed == count + 3 && released == count + 3);

    KxGcStats stats;
    rt_gc_stats(&stats);
    printf("gc=%s work_bytes=%zu pause_total_ns=%lld pause_max_ns=%lld\n", rt_gc_name(),
           cc_work.cap * sizeof(void *), (long long)stats.pause_ns_total, (long long)stats.pause_ns_max);
    fflush(stdout);
    /* Parallel edges must not multiply the pending work (nor its retained allocation). */
    /* An explicit size enables benchmarking the old implementation too. */
    if (argc == 1) assert(cc_work.cap <= PTR_STACK_INITIAL_CAPACITY);
    puts("TRAVERSAL OK");
}
