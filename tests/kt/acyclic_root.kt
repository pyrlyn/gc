// gc-needs: cycles
// GC test: a garbage cycle owns an acyclic object that holds the last reference to a root of the same collection,
// so releasing it during CollectRoots would free (or re-buffer) that root while the collector still reads it.
class C(var o: C?, val v: Long)
class H(val c: C)
class A(var self: A?, val h: H?)
fun touch(c: C): Long = c.v
fun one(k: Long): Long {
    val c = C(null, k)
    val h = H(c)
    val a = A(null, h)
    a.self = a
    val s = a.self!!.h!!.c.v
    return s + touch(c)
}
fun main() {
    println(one(1L))
}
