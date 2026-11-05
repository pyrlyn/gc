// GC test: a chain of a million objects dies at once. Releasing it must not recurse once per node on the
// C stack, however the nodes link up: acyclic class, possibly cyclic class, interface, list.
class Plain(val next: Plain?, val v: Long)
class Node(var next: Node?, var side: Node?, val v: Long)
interface Link { fun value(): Long }
class Linked(val next: Link?, val v: Long) : Link { override fun value(): Long = v }
class Branch(val kids: ArrayList<Branch>, val v: Long)

fun plainChain(n: Long): Long {
    var head: Plain? = null
    var i = 0L
    while (i < n) { head = Plain(head, i); i++ }
    return head!!.v
}

fun nodeChain(n: Long): Long {
    var head: Node? = null
    var i = 0L
    while (i < n) { head = Node(head, null, i); i++ }
    return head!!.v
}

// Walking the chain drops every node to a non-zero count first, so the collector's buffer holds them when
// they die, and the collector runs during the walk.
fun walkedChain(n: Long): Long {
    var head: Node? = null
    var i = 0L
    while (i < n) { head = Node(head, null, i); i++ }
    var s = 0L
    var cur = head
    while (cur != null) { s += cur.v; cur = cur.next }
    return s
}

// Each dying node drops a survivor to a non-zero count, so its possible roots pile up during the release.
fun sideChain(n: Long): Long {
    val survivors = ArrayList<Node>()
    var head: Node? = null
    var i = 0L
    while (i < n) {
        val side = Node(null, null, i)
        survivors.add(side)
        head = Node(head, side, i)
        i++
    }
    head = null
    var s = 0L
    for (x in survivors) s += x.v
    return s
}

fun linkChain(n: Long): Long {
    var head: Link? = null
    var i = 0L
    while (i < n) { head = Linked(head, i); i++ }
    return head!!.value()
}

// Lists sit between the nodes, and every node also has a leaf child beside the spine.
fun branchChain(n: Long): Long {
    var head = Branch(ArrayList<Branch>(), 0L)
    var i = 1L
    while (i < n) {
        val kids = ArrayList<Branch>()
        kids.add(Branch(ArrayList<Branch>(), i))
        kids.add(head)
        head = Branch(kids, i)
        i++
    }
    return head.v
}

fun main() {
    val n = 1000000L
    println(plainChain(n))
    println(nodeChain(n))
    println(walkedChain(n))
    println(sideChain(n))
    println(linkChain(n))
    println(branchChain(n))
}
