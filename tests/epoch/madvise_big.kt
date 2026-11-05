// Epoch GC: freed big objects (> 256 bytes, one 64 KiB block each) hand their memory past the first OS page
// back with madvise(MADV_FREE) (run by tests/run.sh with KX_GC_DEBUG=1; KX_GC_MADVISE=0 must give the same
// checksum with madvised=0). Cyclic pairs, so the collector frees them.
class Big(var other: Big?, val f0: Long = 0L, val f1: Long = 1L, val f2: Long = 2L, val f3: Long = 3L, val f4: Long = 4L, val f5: Long = 5L, val f6: Long = 6L, val f7: Long = 7L, val f8: Long = 8L, val f9: Long = 9L, val f10: Long = 10L, val f11: Long = 11L, val f12: Long = 12L, val f13: Long = 13L, val f14: Long = 14L, val f15: Long = 15L, val f16: Long = 16L, val f17: Long = 17L, val f18: Long = 18L, val f19: Long = 19L, val f20: Long = 20L, val f21: Long = 21L, val f22: Long = 22L, val f23: Long = 23L, val f24: Long = 24L, val f25: Long = 25L, val f26: Long = 26L, val f27: Long = 27L, val f28: Long = 28L, val f29: Long = 29L, val f30: Long = 30L, val f31: Long = 31L, val f32: Long = 32L, val f33: Long = 33L, val f34: Long = 34L, val f35: Long = 35L, val f36: Long = 36L, val f37: Long = 37L, val f38: Long = 38L, val f39: Long = 39L)
fun main() {
    var s = 0L
    for (k in 0 until 20_000) {
        val a = Big(null); val b = Big(a); a.other = b
        s += a.f39 + b.f1
    }
    println("checksum=$s")
}
