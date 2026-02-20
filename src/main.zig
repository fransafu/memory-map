const std = @import("std");
const gatekeeper = @import("gatekeeper.zig");
const state = @import("state.zig");
const scanner_mod = @import("scanner.zig");
const renderer_mod = @import("cli/renderer.zig");

const usage =
    \\memory-map
    \\
    \\Usage: sudo ./memory-map <PID>
    \\
    \\  <PID>  Target process ID to monitor
    \\
    \\To generate a signed binary, then run:
    \\  zig build sign
    \\  sudo ./zig-out/bin/memory-map <PID>
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return;
    }

    const pid = std.fmt.parseInt(i32, args[1], 10) catch {
        std.debug.print("[ERROR] '{s}' is not a valid PID.\n", .{args[1]});
        return;
    };

    std.debug.print("[INFO] memory-map starting for PID {d}\n", .{pid});

    const task_port = gatekeeper.testAccess(pid) catch |err| {
        std.debug.print("{s}", .{gatekeeper.errorMessage(err)});
        return;
    };
    std.debug.print("[INFO] Task port acquired (port: {d})\n", .{task_port.port});

    var shared = state.SharedState.init(allocator);
    defer shared.deinit();

    var scanner = scanner_mod.Scanner.init(task_port.port, &shared);
    std.debug.print("[INFO] Scanner initialized (page size: {d} bytes)\n", .{shared.page_size});

    const scanner_thread = std.Thread.spawn(.{}, scanner_mod.Scanner.run, .{&scanner}) catch |err| {
        std.debug.print("[ERROR] Failed to spawn scanner thread: {any}\n", .{err});
        return;
    };
    std.debug.print("[INFO] Scanner thread started\n", .{});

    var renderer = renderer_mod.TerminalRenderer.init(&shared, pid);
    std.debug.print("[INFO] CLI dashboard starting\n", .{});
    renderer.run();

    std.debug.print("[INFO] Shutting down\n", .{});
    shared.should_stop.store(true, .release);
    scanner_thread.join();
    std.debug.print("[INFO] Done\n", .{});
}
