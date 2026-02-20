const std = @import("std");

pub const MemoryRegion = struct {
    base: u64,
    size: u64,
    protection: u32,
    max_protection: u32,
};

pub const VmStats = struct {
    active: u64 = 0,
    compressed: u64 = 0,
    wired: u64 = 0,
};

pub const ScannerStatus = enum(u8) {
    idle = 0,
    scanning = 1,
    target_lost = 2,
    permission_denied = 3,
};

pub const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    front_regions: std.ArrayListUnmanaged(MemoryRegion) = .{},

    resident_deltas: [512]f64 = undefined,
    resident_count: usize = 0,

    virtual_deltas: [512]f64 = undefined,
    virtual_count: usize = 0,

    vm_stats: VmStats = .{},
    status: std.atomic.Value(ScannerStatus) = std.atomic.Value(ScannerStatus).init(.idle),
    page_size: u32 = 0,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) SharedState {
        return SharedState{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SharedState) void {
        self.front_regions.deinit(self.allocator);
    }

    pub fn updateRegions(self: *SharedState, new_regions: *const std.ArrayListUnmanaged(MemoryRegion)) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.front_regions.resize(self.allocator, new_regions.items.len) catch return;
        @memcpy(self.front_regions.items, new_regions.items);
    }

    pub fn pushResidentDelta(self: *SharedState, val: f64) void {
        if (self.resident_count < self.resident_deltas.len) {
            self.resident_deltas[self.resident_count] = val;
            self.resident_count += 1;
        }
    }

    pub fn pushVirtualDelta(self: *SharedState, val: f64) void {
        if (self.virtual_count < self.virtual_deltas.len) {
            self.virtual_deltas[self.virtual_count] = val;
            self.virtual_count += 1;
        }
    }

    pub fn drainResidentDeltas(self: *SharedState, out: []f64) usize {
        const to_read = @min(self.resident_count, out.len);
        for (0..to_read) |i| {
            out[i] = self.resident_deltas[i];
        }
        const remaining = self.resident_count - to_read;
        for (0..remaining) |i| {
            self.resident_deltas[i] = self.resident_deltas[i + to_read];
        }
        self.resident_count = remaining;
        return to_read;
    }

    pub fn drainVirtualDeltas(self: *SharedState, out: []f64) usize {
        const to_read = @min(self.virtual_count, out.len);
        for (0..to_read) |i| {
            out[i] = self.virtual_deltas[i];
        }
        const remaining = self.virtual_count - to_read;
        for (0..remaining) |i| {
            self.virtual_deltas[i] = self.virtual_deltas[i + to_read];
        }
        self.virtual_count = remaining;
        return to_read;
    }
};
