const std = @import("std");
const state = @import("../state.zig");
const c = @cImport({
    @cInclude("ncurses.h");
});

pub const Renderer = struct {
    shared: *state.SharedState,
    target_pid: i32,

    pub fn init(shared: *state.SharedState, target_pid: i32) Renderer {
        return Renderer{
            .shared = shared,
            .target_pid = target_pid,
        };
    }

    pub fn run(self: *Renderer) void {
        _ = c.initscr();
        defer _ = c.endwin();

        _ = c.noecho();
        _ = c.cbreak();
        _ = c.curs_set(0);
        _ = c.timeout(16);

        if (c.has_colors()) {
            _ = c.start_color();
            _ = c.init_pair(1, c.COLOR_GREEN, c.COLOR_BLACK);
            _ = c.init_pair(2, c.COLOR_CYAN, c.COLOR_BLACK);
            _ = c.init_pair(3, c.COLOR_RED, c.COLOR_BLACK);
        }

        while (!self.shared.should_stop.load(.acquire)) {
            if (self.shared.status.load(.acquire) == .target_lost) break;

            self.drawDashboard();

            const ch = c.getch();
            if (ch == 'q' or ch == 3) {
                self.shared.should_stop.store(true, .release);
                break;
            }
        }
    }

    fn drawDashboard(self: *Renderer) void {
        _ = c.erase();

        var out_resident: [512]f64 = undefined;
        var out_virtual: [512]f64 = undefined;

        self.shared.mutex.lock();
        const region_count = self.shared.front_regions.items.len;
        const vm = self.shared.vm_stats;
        const resident_drained = self.shared.drainResidentDeltas(&out_resident);
        const virtual_drained = self.shared.drainVirtualDeltas(&out_virtual);
        self.shared.mutex.unlock();

        const latest_resident_delta: f64 = if (resident_drained > 0) out_resident[resident_drained - 1] else 0;
        const latest_virtual_delta: f64 = if (virtual_drained > 0) out_virtual[virtual_drained - 1] else 0;

        var buf: [256]u8 = undefined;
        const mb: f64 = 1024.0 * 1024.0;

        _ = c.attron(c.COLOR_PAIR(2) | c.A_BOLD);
        _ = c.mvaddstr(0, 0, fmt(&buf, "memory-map (PID: {d})", .{self.target_pid}));
        _ = c.attroff(c.COLOR_PAIR(2) | c.A_BOLD);

        _ = c.mvaddstr(2, 0, "Target Process Metrics:");
        _ = c.attron(c.COLOR_PAIR(1));
        _ = c.mvaddstr(3, 2, fmt(&buf, "Mapped Regions\t: {d}", .{region_count}));
        _ = c.mvaddstr(4, 2, fmt(&buf, "Resident Delta\t: {d:.2} MB/s", .{latest_resident_delta * 60.0 / mb}));
        _ = c.mvaddstr(5, 2, fmt(&buf, "Virtual Delta\t: {d:.2} MB/s", .{latest_virtual_delta * 60.0 / mb}));
        _ = c.attroff(c.COLOR_PAIR(1));

        _ = c.mvaddstr(7, 0, "macOS VM Stats:");
        _ = c.attron(c.COLOR_PAIR(1));
        _ = c.mvaddstr(8, 2, fmt(&buf, "Active\t\t: {d:.2} MB", .{@as(f64, @floatFromInt(vm.active)) / mb}));
        _ = c.attroff(c.COLOR_PAIR(1));
        _ = c.attron(c.COLOR_PAIR(2));
        _ = c.mvaddstr(9, 2, fmt(&buf, "Compressed\t: {d:.2} MB", .{@as(f64, @floatFromInt(vm.compressed)) / mb}));
        _ = c.attroff(c.COLOR_PAIR(2));
        _ = c.attron(c.COLOR_PAIR(3));
        _ = c.mvaddstr(10, 2, fmt(&buf, "Wired\t\t: {d:.2} MB", .{@as(f64, @floatFromInt(vm.wired)) / mb}));
        _ = c.attroff(c.COLOR_PAIR(3));

        _ = c.mvaddstr(12, 0, "Press 'q' to exit.");
        _ = c.refresh();
    }

    fn fmt(buf: []u8, comptime f: []const u8, args: anytype) [*c]const u8 {
        return (std.fmt.bufPrintZ(buf, f, args) catch "FMT_ERR").ptr;
    }
};
