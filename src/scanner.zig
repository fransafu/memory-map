const std = @import("std");
const state = @import("state.zig");
const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_vm.h");
    @cInclude("mach/host_info.h");
});

pub const Scanner = struct {
    task_port: c.mach_port_t,
    shared: *state.SharedState,
    prev_rss: u64 = 0,
    prev_vms: u64 = 0,

    prev_regions: std.ArrayListUnmanaged(state.MemoryRegion) = .{},
    next_regions: std.ArrayListUnmanaged(state.MemoryRegion) = .{},

    pub fn init(task_port: c.mach_port_t, shared: *state.SharedState) Scanner {
        var page_size: c.vm_size_t = 0;
        _ = c.host_page_size(c.mach_host_self(), &page_size);
        shared.page_size = @intCast(page_size);

        return Scanner{
            .task_port = task_port,
            .shared = shared,
        };
    }

    pub fn scanMemoryRegions(self: *Scanner) void {
        self.next_regions.clearRetainingCapacity();

        var address: c.mach_vm_address_t = 0;
        const now: i64 = @intCast(std.time.nanoTimestamp());
        var depth: c.natural_t = 1;
        var prev_i: usize = 0;

        while (true) {
            var size: c.mach_vm_size_t = 0;
            var info: c.vm_region_submap_info_data_64_t = undefined;
            var info_count: c.mach_msg_type_number_t = @intCast(@sizeOf(c.vm_region_submap_info_data_64_t) / @sizeOf(c.natural_t));

            const kern_return = c.mach_vm_region_recurse(
                self.task_port,
                &address,
                &size,
                &depth,
                @ptrCast(&info),
                &info_count,
            );

            if (kern_return != c.KERN_SUCCESS) {
                if (kern_return == c.KERN_INVALID_ADDRESS) break;
                self.shared.status.store(.target_lost, .release);
                return;
            }

            if (info.is_submap != 0) {
                depth += 1;
                continue;
            }

            var changed_at: i64 = now;
            while (prev_i < self.prev_regions.items.len) {
                const prev = self.prev_regions.items[prev_i];
                if (prev.base == address) {
                    if (prev.size == size and prev.protection == info.protection) {
                        changed_at = prev.changed_at;
                    }
                    break;
                } else if (prev.base > address) {
                    break;
                }
                prev_i += 1;
            }

            self.next_regions.append(self.shared.allocator, state.MemoryRegion{
                .base = address,
                .size = size,
                .protection = @intCast(info.protection),
                .max_protection = @intCast(info.max_protection),
                .changed_at = changed_at,
            }) catch |err| {
                std.debug.print("OOM error in scanner: {}\n", .{err});
                break;
            };

            address += size;
        }

        const temp_prev = self.prev_regions;
        self.prev_regions = self.next_regions;
        self.next_regions = temp_prev;

        self.shared.updateRegions(&self.prev_regions);
    }

    pub fn scanSystemVmStats(self: *Scanner) void {
        var vm_info: c.vm_statistics64_data_t = undefined;
        var count: c.mach_msg_type_number_t = @intCast(@sizeOf(c.vm_statistics64_data_t) / @sizeOf(c.natural_t));

        const kern_return = c.host_statistics64(
            c.mach_host_self(),
            c.HOST_VM_INFO64,
            @ptrCast(&vm_info),
            &count,
        );

        if (kern_return == c.KERN_SUCCESS) {
            const page: u64 = @intCast(self.shared.page_size);
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            self.shared.vm_stats = state.VmStats{
                .active = @as(u64, @intCast(vm_info.active_count)) * page,
                .inactive = @as(u64, @intCast(vm_info.inactive_count)) * page,
                .compressed = @as(u64, @intCast(vm_info.compressor_page_count)) * page,
                .wired = @as(u64, @intCast(vm_info.wire_count)) * page,
                .free = @as(u64, @intCast(vm_info.free_count)) * page,
            };
        }
    }

    pub fn scanTaskMemoryVelocity(self: *Scanner) void {
        var task_info_data: c.mach_task_basic_info_data_t = undefined;
        var count: c.mach_msg_type_number_t = @intCast(@sizeOf(c.mach_task_basic_info_data_t) / @sizeOf(c.natural_t));

        const kern_return = c.task_info(
            self.task_port,
            c.MACH_TASK_BASIC_INFO,
            @ptrCast(&task_info_data),
            &count,
        );

        if (kern_return == c.KERN_SUCCESS) {
            const rss: u64 = @intCast(task_info_data.resident_size);
            const vms: u64 = @intCast(task_info_data.virtual_size);

            if (self.prev_rss != 0) {
                const rss_delta: f64 = @as(f64, @floatFromInt(rss)) - @as(f64, @floatFromInt(self.prev_rss));
                const vms_delta: f64 = @as(f64, @floatFromInt(vms)) - @as(f64, @floatFromInt(self.prev_vms));

                self.shared.mutex.lock();
                defer self.shared.mutex.unlock();
                self.shared.pushRssDelta(rss_delta);
                self.shared.pushVmsDelta(vms_delta);
            }

            self.prev_rss = rss;
            self.prev_vms = vms;
        } else {
            self.shared.status.store(.target_lost, .release);
        }
    }

    pub fn run(self: *Scanner) void {
        self.shared.status.store(.scanning, .release);
        while (!self.shared.should_stop.load(.acquire)) {
            self.scanMemoryRegions();

            if (self.shared.status.load(.acquire) == .target_lost) {
                break;
            }

            self.scanTaskMemoryVelocity();
            self.scanSystemVmStats();
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }

        if (self.shared.status.load(.acquire) != .target_lost) {
            self.shared.status.store(.idle, .release);
        }

        self.prev_regions.deinit(self.shared.allocator);
        self.next_regions.deinit(self.shared.allocator);
    }
};
