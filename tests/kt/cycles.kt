// gc-needs: cycles
// GC test: unreachable reference cycles are reclaimed (self loops, pairs through an interface, rings that
// own acyclic objects and lists), reachable cycles survive collections.
class Leaf(val v: Long)
class Node(val id: Long, var next: Node?, val leaf: Leaf, val tags: ArrayList<Leaf>)
interface Peer { fun id(): Long }
class A(val n: Long, var peer: Peer?) : Peer { override fun id(): Long = n }
class B(val n: Long, var peer: Peer?) : Peer { override fun id(): Long = n * 10 }
fun ring(size: Long): Long {
    val first = Node(0L, null, Leaf(1L), ArrayList<Leaf>())
    var cur = first
    var i = 1L
    while (i < size) { val t = ArrayList<Leaf>(); t.add(Leaf(i)); val n = Node(i, null, Leaf(i), t); cur.next = n; cur = n; i++ }
    cur.next = first
    return cur.id + first.leaf.v
}
fun main() {
    var sum = 0L
    val keep = Node(7L, null, Leaf(7L), ArrayList<Leaf>())
    keep.next = Node(8L, keep, Leaf(8L), ArrayList<Leaf>())
    for (k in 0 until 50000) {
        val s = Node(k.toLong(), null, Leaf(2L), ArrayList<Leaf>()); s.next = s
        val a = A(k.toLong(), null); val b = B(k.toLong(), a); a.peer = b
        sum += s.id + a.id() + b.id() + ring(4L)
    }
    var n: Node? = keep
    var hops = 0L
    while (hops < 10L) { sum += n!!.id + n.leaf.v; n = n.next; hops++ }
    println(sum)
}
