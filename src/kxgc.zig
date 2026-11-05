//! Native Zig mirror of `kxgc.h` (KXGC_API_VERSION 1).
//! Layout and function signatures are the C ABI contract with KotlinX.
pub const api_version: u32 = 1;

pub const CNT_MASK: u64 = 0xffffffff;
pub const COLOR_SHIFT: u6 = 32;
pub const BUF_BIT: u64 = 1 << 34;
pub const COLOR_MASK: u64 = 3 << COLOR_SHIFT;

pub const BLACK: u2 = 0;
pub const GRAY: u2 = 1;
pub const WHITE: u2 = 2;
pub const PURPLE: u2 = 3;

pub const TRAV_SCAN: c_int = 0;
pub const TRAV_RELEASE: c_int = 1;
pub const TRAV_FREE: c_int = 2;

pub const VisitFn = *const fn (?*anyopaque) callconv(.c) void;

pub const VTab = extern struct {
    rel: ?*const fn (?*anyopaque) callconv(.c) void,
    trav: ?*const fn (?*anyopaque, ?VisitFn) callconv(.c) void,
    relo: ?*const fn (?*anyopaque) callconv(.c) void,
    freemem: ?*const fn (?*anyopaque) callconv(.c) void,
    cyclic: ?*anyopaque,
};

pub const Stats = extern struct {
    collections: i64 = 0,
    reclaimed: i64 = 0,
    pause_ns_total: i64 = 0,
    pause_ns_max: i64 = 0,
};

pub const VTAB_OFFSET: usize = 8;
