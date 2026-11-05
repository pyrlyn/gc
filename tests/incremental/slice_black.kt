// A root scanned black by an earlier slice survives a bounded step in the buffer; its last reference then goes
// away, and releasing its fields buffers enough roots to run the next step while the object is half released.
// Run with a small KX_GC_BUDGET_US under ASan.
class N(var next: N?, var a: N?, val items: ArrayList<N>?, val v: Long)
fun bump(t: N, x: N) { t.a = x; t.a = null }
fun fill(t: N, keep: ArrayList<N>, n: Int) {
    for (i in 0 until n) { val x = N(null, null, null, i.toLong()); keep.add(x); bump(t, x) }
}
fun attach(t: N, r: N, shared: ArrayList<N>) {
    val aa = N(null, null, shared, 9L)
    r.a = aa
    bump(t, aa)
}
fun tree(d: Int): N? = if (d == 0) null else N(tree(d - 1), tree(d - 1), null, d.toLong())
fun main() {
    val t = N(null, null, null, 0L)
    val keep = ArrayList<N>()
    val shared = ArrayList<N>()
    for (i in 0 until 3000) { val s = N(null, null, null, i.toLong()); keep.add(s); shared.add(s) }
    val r = N(tree(19), null, null, 7L)
    fill(t, keep, 64)
    bump(t, r)
    fill(t, keep, 63)
    attach(t, r, shared)
    fill(t, keep, 9871)
    r.a = null
    var s = 0L
    for (i in 0 until keep.size) s += keep[i].v
    println(s + r.v)
}
