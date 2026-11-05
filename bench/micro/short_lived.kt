// GC micro: many short-lived object graphs: 20k binary trees of depth 8, built and dropped.
class T(val l: T?, val r: T?, val v: Long)
fun make(d: Long): T = if (d == 0L) T(null, null, 1L) else T(make(d - 1), make(d - 1), d)
fun sum(t: T?): Long = if (t == null) 0L else t.v + sum(t.l) + sum(t.r)
fun main() {
    val t0 = kotlin.system.getTimeNanos()
    var s = 0L
    for (i in 0 until 20_000) s += sum(make(8L))
    val t1 = kotlin.system.getTimeNanos()
    println("checksum=$s nanos=${t1 - t0}")
}
