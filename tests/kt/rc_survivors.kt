// GC test: objects shared by several owners are freed only after the last owner drops them.
class Shared(val v: Long)
class Owner(var s: Shared?)
fun main() {
    var total = 0L
    for (k in 0 until 20000) {
        val sh = Shared(k.toLong())
        val a = Owner(sh); val b = Owner(sh); val c = Owner(sh)
        a.s = null; b.s = null
        total += c.s!!.v
    }
    println(total)
}
