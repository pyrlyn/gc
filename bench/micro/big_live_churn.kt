// GC micro: scaled live_heap_churn: 2M live doubly linked nodes (about 10x the live heap), relinked
// while 2M cyclic garbage pairs are created. Covers large heaps for the parallel-detection threshold sweep.
class D(val id: Long, var prev: D?, var next: D?)
fun main() {
    val t0 = kotlin.system.getTimeNanos()
    val live = ArrayList<D>()
    var prev: D? = null
    for (i in 0 until 2_000_000) { val d = D(i.toLong(), prev, null); if (prev != null) prev.next = d; live.add(d); prev = d }
    var s = 0L
    for (k in 0 until 2_000_000) {
        val a = D(k.toLong(), null, null); val b = D(1L, a, a); a.next = b; a.prev = b
        val x = live[k % 2_000_000]
        x.prev = live[(k * 7) % 2_000_000]
        s += b.id + x.id
    }
    val t1 = kotlin.system.getTimeNanos()
    println("checksum=$s nanos=${t1 - t0}")
}
