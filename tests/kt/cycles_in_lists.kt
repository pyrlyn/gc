// gc-needs: cycles
// GC test: possibly cyclic objects referenced only from ArrayList storage must stay alive across
// collections (a tracing GC has to see list storage), and become garbage once the list is dropped.
class G(val id: Long, var other: G?)
fun main() {
    val live = ArrayList<G>()
    for (i in 0 until 1000) { val g = G(i.toLong(), null); g.other = g; live.add(g) }
    var junk = 0L
    for (k in 0 until 100000) { val x = G(k.toLong(), null); val y = G(1L, x); x.other = y; junk += y.id }
    var s = 0L
    for (i in 0 until live.size) s += live[i].other!!.id
    println(s)
    println(junk)
}
