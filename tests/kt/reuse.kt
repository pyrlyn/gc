// GC test: Perceus reuse / drop at last use: rebuilding a list in place, moves through fields and returns.
class Cell(val v: Long, val next: Cell?)
fun build(n: Long): Cell? { var c: Cell? = null; var i = 0L; while (i < n) { c = Cell(i, c); i++ }; return c }
fun inc(c: Cell?): Cell? = if (c == null) null else Cell(c.v + 1, inc(c.next))
fun total(c: Cell?): Long { var s = 0L; var x = c; while (x != null) { s += x.v; x = x.next }; return s }
class Box(var c: Cell?)
fun main() {
    var c = build(1000L)
    for (k in 0 until 200) c = inc(c)
    println(total(c))
    val b = Box(build(10L))
    for (k in 0 until 1000) b.c = inc(b.c)
    println(total(b.c))
}
