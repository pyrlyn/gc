// gc-needs: cycles
// GC test: a collection held by two objects is not traversed while both hold it. Once one of them drops it (dies
// or overwrites its field), the other is the only holder and must be found again: it becomes the collection's
// owner and a possible root. Two dead holders of one collection must release its elements.
class N(val id: Long) {
    val kids = ArrayList<N>()
    val byId = HashMap<Long, N>()
    var extra: ArrayList<N>? = null
    var tab: HashMap<Long, N>? = null
}
fun main() {
    val keep = ArrayList<N>()
    var s = 0L
    // g (a self-cycle) dies first; x keeps the list that holds x
    for (k in 0 until 3000) {
        val x = N(1L); val y = N(2L)
        val l = ArrayList<N>(); l.add(x); l.add(y)
        val g = N(k.toLong()); g.extra = l; x.extra = l; g.kids.add(g)
        s += g.extra!!.size
        if (k % 1000 == 0) keep.add(x)
    }
    // the first holder overwrites its field
    for (k in 0 until 3000) {
        val x = N(1L); val l = ArrayList<N>(); l.add(x)
        val g = N(k.toLong()); g.extra = l; x.extra = l; g.extra = null
        s += l.size
    }
    // the same through a map
    for (k in 0 until 3000) {
        val x = N(1L); val m = HashMap<Long, N>(); m[1L] = x
        val g = N(k.toLong()); g.tab = m; x.tab = m; g.kids.add(g)
        s += m.size
    }
    // both holders are garbage of one cycle; the list's only reference to y is released
    for (k in 0 until 3000) {
        val a = N(1L); val b = N(2L); val y = N(3L)
        val l = ArrayList<N>(); l.add(y)
        a.extra = l; b.extra = l; a.kids.add(b); b.kids.add(a)
        s += l.size
    }
    for (i in 0 until keep.size) s += keep[i].extra!!.size
    println(s)
}
