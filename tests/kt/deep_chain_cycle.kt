// gc-needs: cycles
// GC test: a million-node acyclic chain dies inside the collector, held only by a garbage cycle.
class Plain(val next: Plain?, val v: Long)
class Ring(var other: Ring?, val chain: Plain?, val v: Long)

fun ring(n: Long): Long {
    var head: Plain? = null
    var i = 0L
    while (i < n) { head = Plain(head, i); i++ }
    val a = Ring(null, head, 1L)
    val b = Ring(a, null, 2L)
    a.other = b
    return a.v + b.v
}

fun main() {
    println(ring(1000000L))
}
