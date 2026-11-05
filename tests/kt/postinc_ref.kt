// Regression: `x++` / `x--` on a class with `operator fun inc()/dec()` returned the old object after the
// reassignment had already released it (use-after-free; --leak-check: "freed into the wrong region").
class Counter(val n: Int) {
    operator fun inc(): Counter = Counter(n + 1)
    operator fun dec(): Counter = Counter(n - 1)
    override fun toString(): String = "C" + n
}
class Holder { var c = Counter(10) }

fun main() {
    var c = Counter(0)
    var sum = 0L
    for (i in 0 until 1000) {
        val old = c++
        val junk = Counter(-1)            // reuses a freed slot if `old` was freed
        sum += old.n + junk.n
        val back = c--
        c++
        sum += back.n
    }
    println("$c $sum")
    val h = Holder()
    val a = h.c++
    val b = h.c--
    println("$a $b ${h.c}")
}
