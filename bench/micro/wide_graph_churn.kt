// GC micro: wide live graph: 10M nodes with 4 out-edges each to pseudo-random earlier nodes (a wide,
// shallow graph, unlike a list, so trial deletion has parallel work), edges rewired while 2M cyclic
// garbage pairs are created. Large-heap case for the parallel-detection threshold sweep.
class W(val id: Long, var a: W?, var b: W?, var c: W?, var d: W?)
fun main() {
    val n = 10_000_000
    val t0 = kotlin.system.getTimeNanos()
    val all = ArrayList<W>()
    var r = 12345L
    for (i in 0 until n) {
        val w = W(i.toLong(), null, null, null, null)
        if (i > 0) {
            r = (r * 6364136223846793005L + 1442695040888963407L); w.a = all[((r ushr 33) % i).toInt()]
            r = (r * 6364136223846793005L + 1442695040888963407L); w.b = all[((r ushr 33) % i).toInt()]
            r = (r * 6364136223846793005L + 1442695040888963407L); w.c = all[((r ushr 33) % i).toInt()]
            r = (r * 6364136223846793005L + 1442695040888963407L); w.d = all[((r ushr 33) % i).toInt()]
        }
        all.add(w)
    }
    var s = 0L
    for (k in 0 until 2_000_000) {
        val p = W(k.toLong(), null, null, null, null); val q = W(1L, p, null, null, null); p.a = q
        r = (r * 6364136223846793005L + 1442695040888963407L); val x = all[((r ushr 33) % n).toInt()]
        r = (r * 6364136223846793005L + 1442695040888963407L); x.b = all[((r ushr 33) % n).toInt()]
        s += q.id + x.id
    }
    val t1 = kotlin.system.getTimeNanos()
    println("checksum=$s nanos=${t1 - t0}")
}
