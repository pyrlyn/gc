// GC micro: cyclic garbage: 2M self loops and 500k 4-node rings, unreachable right after creation.
class N(val id: Long, var next: N?)
fun main() {
    val t0 = kotlin.system.getTimeNanos()
    var s = 0L
    for (k in 0 until 2_000_000) { val x = N(k.toLong(), null); x.next = x; s += x.id }
    for (k in 0 until 500_000) {
        val a = N(1L, null); val b = N(2L, a); val c = N(3L, b); val d = N(4L, c); a.next = d
        s += a.next!!.id
    }
    val t1 = kotlin.system.getTimeNanos()
    println("checksum=$s nanos=${t1 - t0}")
}
