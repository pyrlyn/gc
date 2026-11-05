// gc-needs: cycles
// GC test: garbage cycle -> acyclic holder -> second garbage cycle. The second cycle only becomes visible when
// the first one is freed, so the collection at exit has to run until the root buffer stays empty.
class C(var o: C?, val v: Long)
class H(val c: C)
class A(var self: A?, val h: H?)
fun one(k: Long): Long {
    val c = C(null, k)
    val d = C(c, k)
    c.o = d
    val h = H(c)
    val a = A(null, h)
    a.self = a
    return a.self!!.h!!.c.o!!.v
}
fun main() {
    println(one(2L))
}
