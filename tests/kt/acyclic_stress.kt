// GC test: many short-lived acyclic objects (trees, lists, strings) freed by reference counting.
class T(val l: T?, val r: T?, val v: Long)
fun make(d: Long): T = if (d == 0L) T(null, null, 1L) else T(make(d - 1), make(d - 1), d)
fun sum(t: T?): Long = if (t == null) 0L else t.v + sum(t.l) + sum(t.r)
fun main() {
    var s = 0L
    for (i in 0 until 2000) s += sum(make(8L))
    val names = ArrayList<String>()
    for (i in 0 until 10000) { names.add("n" + i); if (names.size > 100) names.removeAt(0) }
    println(s)
    println(names.size)
    println(names[0])
}
