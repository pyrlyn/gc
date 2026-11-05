// gc-needs: cycles
// GC test: a cycle closed through a local alias of a collection field (`val l = g.kids; l.add(g)`) moves the last
// reference to g into the collection without decrementing g; dropping the alias leaves the field as the only
// reference, which must make its object a possible root. Also through a map, a list returned by a function, and
// a list stored into the field after it was created.
class N(val id: Long) {
    val kids = ArrayList<N>()
    val byId = HashMap<Long, N>()
    var extra: ArrayList<N>? = null
}
fun kidsOf(n: N): ArrayList<N> = n.kids
fun main() {
    val keep = ArrayList<N>()
    var s = 0L
    for (k in 0 until 4000) {
        val g = N(k.toLong()); val l = g.kids; l.add(g); s += l.size
        if (k % 1000 == 0) keep.add(g)
    }
    for (k in 0 until 4000) { val g = N(k.toLong()); val m = g.byId; m[k.toLong()] = g; s += m.size }
    for (k in 0 until 4000) { val g = N(k.toLong()); kidsOf(g).add(g); s += 1 }
    for (k in 0 until 4000) { val l = ArrayList<N>(); val g = N(k.toLong()); g.extra = l; l.add(g); s += l.size }
    for (i in 0 until keep.size) s += keep[i].kids[0].id
    println(s)
}
