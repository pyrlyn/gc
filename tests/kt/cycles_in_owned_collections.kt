// gc-needs: cycles
// GC test: cycles through ArrayList and HashMap fields of possibly cyclic objects, mutated all the time. Under
// epoch the background collector traverses such a collection while the mutator adds (past capacity, so the
// storage moves), sets, removes, overwrites map values and replaces whole collections: every element it reads
// must still be live, live objects reachable only through collections must survive, and garbage cycles through
// them must all be reclaimed (leak-check).
class N(val id: Long) {
    val kids = ArrayList<N>()
    val byId = HashMap<Long, N>()
    var extra: ArrayList<N>? = null
}
// No constructor body: fields are initialized directly from the arguments.
class Bag(val items: ArrayList<Bag>, val m: HashMap<Long, Bag>)
fun next(s: Long): Long = s * 6364136223846793005L + 1442695040888963407L
fun main() {
    val n = 4000
    val live = ArrayList<N>()
    for (i in 0 until n) live.add(N(i.toLong()))
    var s = 99L
    var sum = 0L
    for (k in 0 until 600000) {
        s = next(s)
        val r = ((s ushr 33) % n.toLong()).toInt()
        val x = live[r]
        val y = live[(r * 7 + 1) % n]
        when ((s ushr 20).toInt() and 15) {
            0 -> x.kids.add(y)
            1 -> if (x.kids.size > 0) x.kids.removeAt(((s ushr 40) % x.kids.size.toLong()).toInt())
            2 -> if (x.kids.size > 0) x.kids[((s ushr 40) % x.kids.size.toLong()).toInt()] = y
            3 -> x.byId[(s ushr 50) and 31L] = y
            4 -> { val g = N(k.toLong()); g.kids.add(g); g.byId[1L] = g; x.kids.add(g); x.kids.removeAt(x.kids.size - 1) }
            5 -> { val a = N(k.toLong()); val b = N(1L); a.kids.add(b); b.byId[0L] = a; for (j in 0 until 20) b.kids.add(a) }
            6 -> { val l = ArrayList<N>(); l.add(x); l.add(y); x.extra = l }
            7 -> x.extra = null
            8 -> { val e = x.extra; if (e != null) { e.add(y); if (e.size > 50) e.removeAt(0) } }
            9 -> { val a = Bag(ArrayList<Bag>(), HashMap<Long, Bag>()); a.items.add(a); a.m[k.toLong()] = a }
            10 -> { val g = N(k.toLong()); for (j in 0 until 40) g.byId[j.toLong()] = g }
            11 -> { if (x.kids.size > 30) { while (x.kids.size > 2) x.kids.removeAt(x.kids.size - 1) } }
            12 -> { val g = N(k.toLong()); g.kids.add(x); x.byId[(s ushr 45) and 31L] = g }
            else -> { sum += x.id + x.kids.size.toLong() + x.byId.size.toLong() }
        }
    }
    for (i in 0 until n) {
        val x = live[i]
        for (j in 0 until x.kids.size) sum += x.kids[j].id
        for (j in 0L until 32L) if (x.byId.containsKey(j)) sum += x.byId[j]!!.id
        val e = x.extra
        if (e != null) sum += e.size.toLong()
    }
    println(sum)
}
