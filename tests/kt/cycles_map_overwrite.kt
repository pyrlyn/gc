// gc-needs: cycles
// GC test: overwriting a map value releases the old one, and that release can run the cycle collector. The map
// must already hold the new value then: traversed with the old one, the collector frees g (still referenced by
// the local) and the new value, stored into freed memory, leaks. Enough iterations to collect mid-run.
class N(val id: Long) {
    val kids = ArrayList<N>()
    val byId = HashMap<Long, N>()
}
fun main() {
    var s = 0L
    for (k in 0 until 30000) {
        val g = N(k.toLong())
        for (j in 0 until 40) g.byId[j.toLong()] = g
        g.byId[3L] = N(5L)
        s += g.byId[3L]!!.id + g.byId.size + g.byId[7L]!!.id
    }
    println(s)
}
