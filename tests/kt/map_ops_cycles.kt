// gc-needs: cycles
// GC test: cycles through HashMap fields of possibly cyclic objects while the map removes, clears, compacts and
// grows its dense entry arrays (insertion-ordered map). Under epoch the collector reads the entries concurrently;
// live values must survive and garbage cycles through the maps must all be reclaimed (leak-check).
class N(val id: Long) {
    val byId = HashMap<Long, N>()
}
fun next(s: Long): Long = s * 6364136223846793005L + 1442695040888963407L
fun main() {
    val n = 3000
    val live = ArrayList<N>()
    for (i in 0 until n) live.add(N(i.toLong()))
    var s = 7L
    var sum = 0L
    for (k in 0 until 800000) {
        s = next(s)
        val r = ((s ushr 33) % n.toLong()).toInt()
        val x = live[r]
        val y = live[(r * 7 + 1) % n]
        when ((s ushr 20).toInt() and 7) {
            0 -> x.byId[(s ushr 50) and 63L] = y
            1 -> { val v = x.byId.remove((s ushr 50) and 63L); if (v != null) sum += v.id }
            2 -> if (((s ushr 40) and 15L) == 0L) x.byId.clear()
            3 -> { val g = N(k.toLong()); for (j in 0 until 30) g.byId[j.toLong()] = g; for (j in 0 until 25) g.byId.remove(j.toLong()); for (j in 30 until 60) g.byId[j.toLong()] = g }
            4 -> { val g = N(k.toLong()); g.byId[0L] = x; x.byId[(s ushr 45) and 63L] = g }
            5 -> { val g = N(k.toLong()); g.byId[1L] = g; g.byId.clear(); g.byId[2L] = g }
            else -> { for (e in x.byId) sum += e.value.id + e.key }
        }
    }
    for (i in 0 until n) for (e in live[i].byId) sum += e.value.id
    println(sum)
}
