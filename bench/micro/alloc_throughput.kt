// GC micro: allocation throughput: 20M small heap objects (each stored into a holder, so it escapes and is
// heap allocated), each one freed when the next replaces it.
class P(val x: Long, val y: Long)
class H(var p: P?)
fun main() {
    val t0 = kotlin.system.getTimeNanos()
    val h = H(null)
    var s = 0L
    var i = 0L
    while (i < 20_000_000L) { h.p = P(i, i + 1); s += h.p!!.x; i++ }
    val t1 = kotlin.system.getTimeNanos()
    println("checksum=$s nanos=${t1 - t0}")
}
