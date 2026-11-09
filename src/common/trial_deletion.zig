//! Bacon & Rajan trial-deletion passes. Port of `common/trial_deletion.inc`.
const host = @import("host");
const obj = @import("object.zig");

pub const CC_THRESHOLD: usize = 10000;
pub const CC_MAX_THRESHOLD: usize = 1 << 18;
pub const CC_PRODUCTIVE_RATIO: usize = 4;

/// `track_buffered_black`: count the buffered objects `scanBlack` blackens (`blackened_buffered`), so
/// a collector that runs trial deletion over a subset of its buffer rescans the rest of the buffer
/// for live black roots only when there can be any (see `incremental.zig`).
pub fn TrialDeletion(comptime claim_skips_buffered: bool, comptime track_buffered_black: bool) type {
    return struct {
        const Self = @This();

        work: obj.PtrStack = .{},
        blacken: obj.PtrStack = .{},
        garbage: obj.PtrStack = .{},
        acyclic: obj.PtrStack = .{},
        blackened_buffered: usize = 0,
        traced: usize = 0,
        threshold: usize = CC_THRESHOLD,

        /// C visitors close over file-scope stacks; Zig visitors are C pointers.
        /// A plain global like C's statics (the synchronous collectors run on the mutator
        /// and are not reentrant across threads); `threadlocal` cost a `_tlv_get_addr`
        /// call per visited edge on Darwin.
        pub var current: ?*Self = null;

        pub fn activate(self: *Self) void {
            current = self;
        }

        pub fn markGray(self: *Self, root: *anyopaque) void {
            self.markGrayClaim(root);
            while (self.work.len != 0) {
                const o = self.work.pop().?;
                self.traced += 1;
                if (obj.vtab(o).trav) |trav| trav(o, markGrayChild);
            }
        }

        fn markGrayClaim(self: *Self, o: *anyopaque) void {
            if (obj.color(o) == obj.GRAY) return;
            obj.setColor(o, obj.GRAY);
            self.work.push(o);
        }

        fn markGrayChild(child: ?*anyopaque) callconv(.c) void {
            const self = current.?;
            if (child) |ch| {
                if (obj.isCyclic(ch)) {
                    obj.header(ch).* -= 1;
                    self.markGrayClaim(ch);
                }
            }
        }

        pub fn scanBlack(self: *Self, o: *anyopaque) void {
            obj.setColor(o, obj.BLACK);
            if (track_buffered_black and obj.isBuffered(o)) self.blackened_buffered += 1;
            self.blacken.push(o);
            while (self.blacken.len != 0) {
                const x = self.blacken.pop().?;
                if (obj.vtab(x).trav) |trav| trav(x, scanBlackChild);
            }
        }

        fn scanBlackChild(child: ?*anyopaque) callconv(.c) void {
            const self = current.?;
            const ch = child orelse return;
            if (!obj.isCyclic(ch)) return;
            obj.header(ch).* += 1;
            if (obj.color(ch) != obj.BLACK) {
                obj.setColor(ch, obj.BLACK);
                if (track_buffered_black and obj.isBuffered(ch)) self.blackened_buffered += 1;
                self.blacken.push(ch);
            }
        }

        fn scanClaim(self: *Self, o: *anyopaque) void {
            if (obj.color(o) != obj.GRAY) return;
            obj.setColor(o, obj.WHITE);
            self.work.push(o);
        }

        pub fn scan(self: *Self, root: *anyopaque) void {
            self.scanClaim(root);
            while (self.work.len != 0) {
                const o = self.work.pop().?;
                if (obj.color(o) != obj.WHITE) continue;
                if (obj.refCount(o) > 0) self.scanBlack(o) else if (obj.vtab(o).trav) |trav| trav(o, scanChild);
            }
        }

        fn scanChild(child: ?*anyopaque) callconv(.c) void {
            const self = current.?;
            if (child) |ch| {
                if (obj.isCyclic(ch)) self.scanClaim(ch);
            }
        }

        fn collectWhiteClaim(self: *Self, o: *anyopaque) bool {
            if (obj.color(o) != obj.WHITE) return false;
            if (claim_skips_buffered and obj.isBuffered(o)) return false;
            obj.setColor(o, obj.BLACK);
            self.work.push(o);
            return true;
        }

        pub fn collectWhite(self: *Self, root: *anyopaque) void {
            if (!self.collectWhiteClaim(root)) return;
            host.rt_trav_mode = 1; // RT_TRAV_RELEASE
            while (self.work.len != 0) {
                const o = self.work.pop().?;
                if (obj.vtab(o).trav) |trav| trav(o, collectWhiteChild);
                self.garbage.push(o);
            }
            host.rt_trav_mode = 0; // RT_TRAV_SCAN
        }

        fn collectWhiteChild(child: ?*anyopaque) callconv(.c) void {
            const self = current.?;
            const ch = child orelse return;
            if (obj.isCyclic(ch)) {
                _ = self.collectWhiteClaim(ch);
            } else {
                self.acyclic.push(ch);
            }
        }

        pub fn releaseAcyclicChildren(self: *Self) void {
            while (self.acyclic.len != 0) {
                const child = self.acyclic.pop().?;
                if (obj.vtab(child).rel) |rel| rel(child);
            }
        }

        pub fn adaptThreshold(self: *Self, reclaimed: usize) void {
            if (reclaimed * CC_PRODUCTIVE_RATIO < self.traced) {
                if (self.threshold < CC_MAX_THRESHOLD) self.threshold *= 2;
            } else {
                self.threshold = CC_THRESHOLD;
            }
        }
    };
}

