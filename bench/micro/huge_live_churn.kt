// GC micro: live_heap_churn at 10M live doubly linked nodes (50x), relinked while 2M cyclic garbage
// pairs are created. Large-heap case for the parallel-detection threshold sweep.
class D(val id: Long, var prev: D?, var next: D?)
fun main() {
    val n = 10_000_000
    val t0 = kotlin.system.getTimeNanos()
    val live = ArrayList<D>()
    var prev: D? = null
    for (i in 0 until n) { val d = D(i.toLong(), prev, null); if (prev != null) prev.next = d; live.add(d); prev = d }
    var s = 0L
    for (k in 0 until 2_000_000) {
        val a = D(k.toLong(), null, null); val b = D(1L, a, a); a.next = b; a.prev = b
        val x = live[((k.toLong() * 5L) % n).toInt()]
        x.prev = live[((k.toLong() * 7919L) % n).toInt()]
        s += b.id + x.id
    }
    val t1 = kotlin.system.getTimeNanos()
    println("checksum=$s nanos=${t1 - t0}")
}
