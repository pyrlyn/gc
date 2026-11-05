//! Object header / vtable accessors and a growable pointer stack.
//! Faithful port of `common/object.inc`.
const std = @import("std");
const kx = @import("kxgc");
const host = @import("host");

pub const BLACK = kx.BLACK;
pub const GRAY = kx.GRAY;
pub const WHITE = kx.WHITE;
pub const PURPLE = kx.PURPLE;
pub const CNT_MASK = kx.CNT_MASK;
pub const COLOR_SHIFT = kx.COLOR_SHIFT;
pub const BUF_BIT = kx.BUF_BIT;
pub const COLOR_MASK = kx.COLOR_MASK;
pub const VTAB_OFFSET = kx.VTAB_OFFSET;
pub const VTab = kx.VTab;
pub const VisitFn = kx.VisitFn;
pub const Stats = kx.Stats;

pub inline fn header(obj: *anyopaque) *u64 {
    return @ptrCast(@alignCast(obj));
}

pub inline fn vtab(obj: *anyopaque) *VTab {
    // C object.inc: `*(VTab **)((char *)obj + VTAB_OFFSET)` — no null check.
    const p: [*]u8 = @ptrCast(obj);
    const slot: **VTab = @ptrCast(@alignCast(p + VTAB_OFFSET));
    return slot.*;
}

pub inline fn isCyclic(obj: *anyopaque) bool {
    return vtab(obj).cyclic != null;
}

pub inline fn refCount(obj: *anyopaque) u64 {
    return header(obj).* & CNT_MASK;
}

pub inline fn color(obj: *anyopaque) u2 {
    return @truncate((header(obj).* & COLOR_MASK) >> COLOR_SHIFT);
}

pub inline fn setColor(obj: *anyopaque, col: u2) void {
    header(obj).* = (header(obj).* & ~COLOR_MASK) | (@as(u64, col) << COLOR_SHIFT);
}

pub inline fn isBuffered(obj: *anyopaque) bool {
    return (header(obj).* & BUF_BIT) != 0;
}

pub inline fn setBuffered(obj: *anyopaque) void {
    header(obj).* |= BUF_BIT;
}

pub inline fn clearBuffered(obj: *anyopaque) void {
    header(obj).* &= ~BUF_BIT;
}

pub const PTR_STACK_INITIAL_CAPACITY: usize = 256;

pub const PtrStack = struct {
    items: [*]?*anyopaque = undefined,
    len: usize = 0,
    cap: usize = 0,
    owned: bool = false,

    pub fn push(self: *PtrStack, obj: ?*anyopaque) void {
        if (self.len == self.cap) {
            const new_cap = if (self.cap == 0) PTR_STACK_INITIAL_CAPACITY else self.cap * 2;
            const bytes = new_cap * @sizeOf(?*anyopaque);
            const raw = if (self.cap == 0)
                host.malloc(bytes)
            else
                host.realloc(@ptrCast(self.items), bytes);
            self.items = @ptrCast(@alignCast(raw));
            self.cap = new_cap;
            self.owned = true;
        }
        self.items[self.len] = obj;
        self.len += 1;
    }

    pub fn pop(self: *PtrStack) ?*anyopaque {
        self.len -= 1;
        return self.items[self.len];
    }

    pub fn at(self: *const PtrStack, i: usize) ?*anyopaque {
        return self.items[i];
    }

    pub fn set(self: *PtrStack, i: usize, obj: ?*anyopaque) void {
        self.items[i] = obj;
    }

    pub fn deinit(self: *PtrStack) void {
        if (self.owned and self.cap != 0) host.free(@ptrCast(self.items));
        self.* = .{};
    }

    pub fn moveFrom(to: *PtrStack, from: *PtrStack) void {
        var i: usize = 0;
        while (i < from.len) : (i += 1) to.push(from.items[i]);
        from.len = 0;
    }
};

pub fn statsAddPause(st: *Stats, pause_ns: i64) void {
    st.pause_ns_total += pause_ns;
    if (pause_ns > st.pause_ns_max) st.pause_ns_max = pause_ns;
    host.rt_gc_note_pause(pause_ns);
}
