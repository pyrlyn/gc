/* Host stubs for symbols declared "provided by the runtime" in kxgc.h.
 * Used only to compile/run the original C collectors and C benches/tests on Linux.
 * This file is NOT part of the GC and does not modify any collector source.
 * KotlinX runtime.c uses clock_gettime_nsec_np(CLOCK_UPTIME_RAW) (macOS); Linux
 * equivalent is clock_gettime(CLOCK_MONOTONIC). Pause-percentile bookkeeping
 * matches runtime.c so KX_GC_STATS=1 output is comparable. */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "kxgc.h"

int rt_rel_draining;
_Thread_local int rt_trav_mode;
int rt_relo_owner;

int64_t rt_nanos(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) abort();
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

void rt_panic(const char *msg) {
    fflush(stdout);
    fprintf(stderr, "Exception in thread \"main\" java.lang.IllegalStateException: %s\n", msg);
    exit(1);
}

static int64_t *gc_pauses;
static size_t gc_pauses_len, gc_pauses_cap;

void rt_gc_note_pause(int64_t pause_ns) {
    if (gc_pauses_len == gc_pauses_cap) {
        size_t cap = gc_pauses_cap ? gc_pauses_cap * 2 : 1024;
        int64_t *p = realloc(gc_pauses, cap * sizeof *p);
        if (!p) return;
        gc_pauses = p;
        gc_pauses_cap = cap;
    }
    gc_pauses[gc_pauses_len++] = pause_ns;
}

static int cmp_i64(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return (x > y) - (x < y);
}

static double gc_pause_pct(double q) {
    if (!gc_pauses_len) return 0;
    size_t i = (size_t)(q * gc_pauses_len + 0.999999);
    if (i < 1) i = 1;
    if (i > gc_pauses_len) i = gc_pauses_len;
    return gc_pauses[i - 1] / 1e6;
}

__attribute__((destructor)) static void rt_exit_flush(void) {
    rt_gc_collect();
    fflush(stdout);
    const char *e = getenv("KX_GC_STATS");
    if (e && *e && *e != '0') {
        KxGcStats st;
        rt_gc_stats(&st);
        qsort(gc_pauses, gc_pauses_len, sizeof *gc_pauses, cmp_i64);
        fprintf(stderr, "gc-stats: gc=%s collections=%lld reclaimed=%lld pause_total=%.3f pause_max=%.3f pause_p50=%.3f pause_p99=%.3f\n",
                rt_gc_name(), (long long)st.collections, (long long)st.reclaimed,
                st.pause_ns_total / 1e6, st.pause_ns_max / 1e6, gc_pause_pct(0.50), gc_pause_pct(0.99));
    }
}
