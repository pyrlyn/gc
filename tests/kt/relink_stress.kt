// gc-needs: cycles
// GC test: a large live graph relinked all the time, with garbage cycles through it. Many objects are held by
// nothing but the list, so a store into one of them can race with a concurrent collector looking at it: under
// epoch, a live object wrongly proposed as a candidate cycle must not pass validation on a store whose
// reference operations are still queued (the queued log would be applied to freed memory).
class Leaf(val v: Long)
class H(val c: D?)
class D(val id: Long, var a: D?, var b: D?, var h: H?, val leaf: Leaf, val tags: ArrayList<Leaf>?)
fun mk(i: Long): D = D(i, null, null, null, Leaf(i), null)
fun next(s: Long): Long = s * 6364136223846793005L + 1442695040888963407L
fun main() {
    val n = 60000
    val live = ArrayList<D>()
    for (i in 0 until n) live.add(mk(i.toLong()))
    for (i in 0 until n) { val d = live[i]; d.a = live[(i * 7 + 3) % n]; d.b = live[(i * 13 + 5) % n] }
    var s = 12345L
    var sum = 0L
    for (k in 0 until 2500000) {
        s = next(s)
        val r = ((s ushr 33) % n.toLong()).toInt()
        val x = live[r]
        when ((s ushr 20).toInt() and 7) {
            0 -> { val y = mk(k.toLong()); val z = mk(1L); y.a = z; z.a = y; x.b = y }
            1 -> { x.a = live[(r + 1) % n] }
            2 -> { val y = mk(k.toLong()); y.a = x; y.b = y }
            3 -> { val y = mk(k.toLong()); x.h = H(y); y.h = H(x) }
            4 -> { val y = D(k.toLong(), x, null, null, Leaf(2L), ArrayList<Leaf>()); y.tags!!.add(Leaf(3L)); x.b = y; x.b = live[r] }
            5 -> { val y = mk(k.toLong()); x.a = y; y.a = x; x.a = null }
            6 -> { val old = live[(r + 2) % n]; live[(r + 2) % n] = mk(k.toLong()); old.a = old }
            else -> { sum += x.id + x.leaf.v }
        }
    }
    for (i in 0 until n) { sum += live[i].id; val a = live[i].a; if (a != null) sum += a.leaf.v }
    println(sum)
}
