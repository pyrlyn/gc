// Epoch GC regression: dead objects are freed by allocation pacing, not at epoch boundaries
// (run by tests/run.sh with KX_GC_DEBUG=1). 2M cyclic garbage pairs next to a 100K live list.
class P(val id: Long, var other: P?)
fun main() {
    val live = ArrayList<P>()
    for (i in 0 until 100_000) live.add(P(i.toLong(), null))
    var s = 0L
    for (k in 0 until 2_000_000) {
        val a = P(k.toLong(), null); val b = P(1L, a); a.other = b
        live[k % 100_000].other = live[(k * 13) % 100_000]
        s += a.id + b.id
    }
    println("checksum=$s")
}
