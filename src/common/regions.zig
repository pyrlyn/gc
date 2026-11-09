//! RC and tracing regions. Port of `common/regions.inc` (non-leak-check path) with another pool.
//! C bump-allocates every size class from one shared 64 KiB slab and reuses a freed block only for its
//! own class, so memory freed by one class never serves another. Here each 16 KiB page holds a single
//! class, and a page whose blocks are all free goes back to a stock that every class takes pages from:
//! compaction without moving objects (kxgc.h visitors receive child values, not field addresses, and
//! generated code holds raw pointers, so an object can never be relocated).
//! Allocation and free stay C's: a free-list pop or a bump, and a push onto the class's free list.
//! Pages are counted only when the stock runs dry, by walking the free lists (`Pages`).
//! Counting on every free (the epoch collector's slab scheme) touched the page header of each block
//! freed outside the current page, and each allocation then switched pages: freeing and replacing
//! objects in random order, as an LRU cache does, was 3-8 times slower natively and 1.8 times in wasm.
//! On wasm the RC region (`rt_alloc`) has a pool of its own instead of malloc; both pools take pages
//! from the same stock.
const std = @import("std");
const builtin = @import("builtin");
const kx = @import("kxgc");
const host = @import("host");

const RT_CLASSES: usize = 32;
const RT_SIZE_CLASS_SHIFT: u6 = 3;
const is_wasm = builtin.cpu.arch.isWasm();

/// Pool page: blocks of one size class after a header. Aligned to its size, so a block finds its
/// page by masking its address.
pub const PAGE: usize = 16 << 10;
/// Pages come from the system in chunks. Natively, a 1 MiB mapping, which becomes resident only as its
/// pages are used. On wasm, `memory.grow` (through malloc, the allocator's 16-byte header made a 64 KiB
/// request a 128 KiB block), by an eighth of the pages carved so far, from one 64 KiB wasm page up to
/// 1 MiB: once JS has read `memory.buffer`, each grow costs 4-90 us under V8 and about 1 ms under Bun,
/// so a heap that keeps growing grows in fewer steps, while a small one stays small.
const CHUNK: usize = 1 << 20;
const WASM_PAGE: usize = 64 << 10;

const PageHdr = struct {
    /// The next page of the stock, or of the pages a walk found blocks of.
    next: ?*PageHdr,
    /// Walk scratch (`Pages.step`): the page's free blocks found in walk `walk`, first and last, and
    /// their count.
    head: ?*anyopaque,
    tail: ?*anyopaque,
    walk: u32,
    cls: u16,
    nfree: u16,
};
/// Blocks start after the header, at 8-byte granularity like C's slab blocks.
const HDR: usize = std.mem.alignForward(usize, @sizeOf(PageHdr), 16);

inline fn classOf(size: i64) usize {
    return (@as(usize, @intCast(size)) + 7) >> RT_SIZE_CLASS_SHIFT;
}

inline fn pageOf(p: *anyopaque) *PageHdr {
    return @ptrFromInt(@intFromPtr(p) & ~(PAGE - 1));
}

/// A free block's first word: the next free block of its class.
inline fn link(p: *anyopaque) *?*anyopaque {
    return @ptrCast(@alignCast(p));
}

fn capacity(cls: usize) u16 {
    return @intCast((PAGE - HDR) / (cls << RT_SIZE_CLASS_SHIFT));
}

/// Returns the start of a new chunk of `size` bytes.
fn newChunk(size: usize) usize {
    if (comptime is_wasm) {
        const page = @wasmMemoryGrow(0, size / WASM_PAGE);
        if (page < 0) host.oom();
        return @as(usize, @intCast(page)) * WASM_PAGE;
    }
    const p = std.heap.page_allocator.rawAlloc(size, .fromByteUnits(PAGE), @returnAddress()) orelse host.oom();
    return @intFromPtr(p);
}

fn chunkSize(carved: usize) usize {
    if (comptime !is_wasm) return CHUNK;
    const eighth = std.mem.alignForward(usize, carved * PAGE / 8, WASM_PAGE);
    return std.math.clamp(eighth, WASM_PAGE, CHUNK);
}

const no_page: [*]u8 = @ptrFromInt(PAGE);

const Class = struct {
    /// Free blocks, then the bump range of the current page: empty when there is none. Pointers, not
    /// addresses: a block made from an integer may alias anything to the compiler (see `Pages.class`).
    free: ?*anyopaque = null,
    ptr: [*]u8 = no_page,
    end: [*]u8 = no_page,
    /// The page being bumped through, which a walk leaves to its class.
    page: ?*PageHdr = null,
    /// `free` and `page` as the last walk left them: while both are unchanged, no page of the class
    /// can have become free since, and walks skip it.
    walked_free: ?*anyopaque = null,
    walked_page: ?*PageHdr = null,
};

/// Free blocks a walk sorts per page taken: a walk never stalls an allocation for long (4096 blocks
/// scattered over a large heap take about 0.25 ms), and still sorts more blocks than a page holds.
const WALK_STEP: usize = 4096;
/// Bytes handed out between two walks at least.
const WALK_GAP: usize = 4 * PAGE;

/// Pages for every pool: those walks found free, then the rest of the newest chunk.
/// A walk goes over the classes one at a time. It takes a class's free list, sorts its blocks by
/// page `WALK_STEP` at a time whenever a page is needed and the stock is empty, then moves the pages
/// with every block free to the stock and gives the rest back to the class, grouped by page.
const Pages = struct {
    empty: ?*PageHdr = null,
    chunk_ptr: usize = 0,
    chunk_end: usize = 0,
    /// Pages carved from chunks (memory is never returned to the system).
    carved: usize = 0,
    /// Bytes of the pages taken since the last walk began, and bytes of the free blocks that walk gave
    /// back to their classes, plus pages a class took back from the stock (the walk gained nothing
    /// for those). The next walk waits until as many bytes, and `WALK_GAP` more, were handed out, so
    /// walking costs at most one block per 8 bytes allocated; and walks skip classes whose lists did
    /// not change.
    handed: usize = 0,
    kept: usize = 0,
    /// The walk's number (never 0, which marks pages no walk has counted), the next class it goes
    /// to, and the class it is in (`classAt` index, `NO_CLASS` between classes): blocks still to sort
    /// and pages already found. Classes are kept as indexes, never pointers stored in memory: a pool
    /// whose address escapes may alias every object, and the compiler then reloads its free lists
    /// around each object store on the inlined fast paths.
    walk: u32 = 0,
    walking: bool = false,
    next_class: usize = 0,
    class: usize = NO_CLASS,
    unsorted: ?*anyopaque = null,
    found: ?*PageHdr = null,

    fn take(self: *Pages, cls: usize) *PageHdr {
        if (self.empty == null) {
            if (!self.walking and self.handed >= self.kept + WALK_GAP) self.begin();
            if (self.walking) self.step();
        }
        self.handed += PAGE;
        if (self.empty) |pg| {
            self.empty = pg.next;
            if (pg.cls == cls) self.kept += PAGE;
            return pg;
        }
        if (self.chunk_ptr == self.chunk_end) {
            const size = chunkSize(self.carved);
            const c = newChunk(size);
            self.chunk_ptr = c;
            self.chunk_end = c + size;
        }
        const pg = self.chunk_ptr;
        self.chunk_ptr = pg + PAGE;
        self.carved += 1;
        return @ptrFromInt(pg);
    }

    fn begin(self: *Pages) void {
        self.walk +%= 1;
        if (self.walk == 0) self.walk = 1;
        self.walking = true;
        self.next_class = 0;
        self.handed = 0;
        self.kept = 0;
    }

    /// Sorts up to `WALK_STEP` blocks, finishing and entering classes on the way.
    noinline fn step(self: *Pages) void {
        var budget = WALK_STEP;
        while (true) {
            if (self.class == NO_CLASS) {
                if (self.next_class == POOLS * RT_CLASSES) {
                    self.walking = false;
                    return;
                }
                const i = self.next_class;
                self.next_class += 1;
                const next = classAt(i);
                if (next.free == null or (next.free == next.walked_free and next.page == next.walked_page)) continue;
                self.class = i;
                self.unsorted = next.free;
                self.found = null;
                next.free = null;
                continue;
            }
            while (self.unsorted) |b| {
                if (budget == 0) return;
                budget -= 1;
                self.unsorted = link(b).*;
                const pg = pageOf(b);
                if (pg.walk != self.walk) {
                    pg.* = .{ .next = self.found, .head = null, .tail = b, .walk = self.walk, .cls = pg.cls, .nfree = 0 };
                    self.found = pg;
                }
                link(b).* = pg.head;
                pg.head = b;
                pg.nfree += 1;
            }
            self.finish(classAt(self.class), self.class % RT_CLASSES + 1);
            self.class = NO_CLASS;
        }
    }

    /// Pages whose blocks were all on the list go to the stock (unless the class still bumps through
    /// it), the rest back to the class, in front of the blocks it freed meanwhile.
    fn finish(self: *Pages, c: *Class, cls: usize) void {
        const cap = capacity(cls);
        var next = self.found;
        while (next) |pg| {
            next = pg.next;
            pg.walk = 0;
            if (pg.nfree == cap and pg != c.page) {
                pg.next = self.empty;
                self.empty = pg;
            } else {
                link(pg.tail.?).* = c.free;
                c.free = pg.head;
                self.kept += @as(usize, pg.nfree) * (cls << RT_SIZE_CLASS_SHIFT);
            }
        }
        c.walked_free = c.free;
        c.walked_page = c.page;
    }
};

var pages = Pages{};

const POOLS: usize = if (rc_pooled) 2 else 1;
const NO_CLASS = std.math.maxInt(usize);

/// Class `i % RT_CLASSES + 1` of pool `i / RT_CLASSES` (0 tracing, 1 RC).
fn classAt(i: usize) *Class {
    const cls = i % RT_CLASSES + 1;
    if (rc_pooled and i >= RT_CLASSES) return &rc_pool.classes[cls];
    return &trace_pool.classes[cls];
}

const Pool = struct {
    classes: [RT_CLASSES + 1]Class = @splat(.{}),
    /// The pool's `classAt` index base: 0 tracing, 1 RC.
    id: usize,

    inline fn alloc(self: *Pool, size: i64) *anyopaque {
        const cls = classOf(size);
        if (cls > RT_CLASSES) return host.malloc(@intCast(size));
        const c = &self.classes[cls];
        const bytes = cls << RT_SIZE_CLASS_SHIFT;
        std.debug.assert(bytes != 0); // objects have a header: size 0 is not an object
        while (true) {
            if (c.free) |p| {
                c.free = link(p).*;
                return p;
            }
            if (@intFromPtr(c.end) - @intFromPtr(c.ptr) >= bytes) {
                const p = c.ptr;
                c.ptr = p + bytes;
                return @ptrCast(@alignCast(p));
            }
            refill(self.id, cls);
        }
    }

    inline fn free(self: *Pool, p: *anyopaque, size: i64) void {
        const cls = classOf(size);
        if (cls > RT_CLASSES) {
            host.free(p);
            return;
        }
        std.debug.assert(pageOf(p).cls == cls); // freed with the size it was allocated with
        const c = &self.classes[cls];
        link(p).* = c.free;
        c.free = p;
    }

    /// The class has neither a free block nor room for another in its page (the rest, less than one
    /// block, is abandoned as in C pool_alloc): it gets a free block, or a page from the stock or a
    /// chunk to bump through. It takes the pool's index rather than its address and returns nothing:
    /// the compiler cannot tell what a call returns or keeps from an object (see `Pages.class`).
    noinline fn refill(id: usize, cls: usize) void {
        const i = id * RT_CLASSES + cls - 1;
        const c = classAt(i);
        // A walk holds this class's free blocks: use those it has not sorted yet. A block taken
        // there is live when the walk counts its page.
        if (pages.class == i) if (pages.unsorted) |p| {
            pages.unsorted = link(p).*;
            link(p).* = null;
            c.free = p;
            return;
        };
        const pg = pages.take(cls);
        pg.* = .{ .next = null, .head = null, .tail = null, .walk = 0, .cls = @intCast(cls), .nfree = 0 };
        const base: [*]u8 = @ptrCast(pg);
        c.page = pg;
        c.ptr = base + HDR;
        c.end = base + PAGE;
    }
};

/// The tracing region (C `trace_pool`).
var trace_pool = Pool{ .id = 0 };

/// The RC region on wasm, as with C's `RT_POOL`. Zig's wasm32 libc malloc (std.heap.BrkAllocator)
/// keeps a 16-byte header and rounds every block to a power of two: a 40-byte object took a 64-byte
/// slot. Its own pool keeps traced objects apart from short-lived acyclic ones, as in C, while
/// taking pages from the same stock. Natively it stays libc malloc, one of C's object allocators
/// (C defaults to mimalloc).
var rc_pool = Pool{ .id = 1 };
const rc_pooled = is_wasm;

pub fn rtAlloc(size: i64) *anyopaque {
    if (comptime rc_pooled) return rc_pool.alloc(size);
    return host.malloc(@intCast(size));
}

pub fn rtFree(p: ?*anyopaque, size: i64) void {
    if (comptime rc_pooled) {
        if (p) |q| rc_pool.free(q, size);
        return;
    }
    host.free(p);
}

pub inline fn rtAllocTrace(size: i64) *anyopaque {
    return trace_pool.alloc(size);
}

pub inline fn rtFreeTrace(p: ?*anyopaque, size: i64) void {
    if (p) |q| trace_pool.free(q, size);
}

/// For tests and benches: pool pages carved from the system so far.
pub fn debugPoolPages() usize {
    return pages.carved;
}

// C regions.inc: NULL is a valid result for n == 0 (malloc(0) / realloc(p, 0) may return
// it); only a failed non-empty request is OutOfMemoryError.
pub fn memAlloc(n: usize) ?*anyopaque {
    const p = std.c.malloc(n);
    if (p == null and n != 0) host.oom();
    return p;
}

pub fn memCalloc(n: usize) ?*anyopaque {
    const p = std.c.calloc(1, n);
    if (p == null and n != 0) host.oom();
    return p;
}

pub fn memRealloc(p: ?*anyopaque, n: usize) ?*anyopaque {
    const q = std.c.realloc(p, n);
    if (q == null and n != 0) host.oom();
    return q;
}

pub fn memFree(p: ?*anyopaque) void {
    host.free(p);
}

pub fn notDeferred(what: [*:0]const u8) noreturn {
    host.rt_panic(what);
}
