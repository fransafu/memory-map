const std = @import("std");
const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("mach/mach_vm.h");
    @cInclude("unistd.h");
});

pub const GatekeeperError = error{
    InsufficientPrivileges,
    SipBlocked,
    InvalidTarget,
    KernelFailure,
};

pub const TaskPort = struct {
    port: c.mach_port_t,
};

pub fn testAccess(pid: i32) GatekeeperError!TaskPort {
    if (c.geteuid() != 0) return error.InsufficientPrivileges;

    var task: c.mach_port_t = 0;
    const kern_return = c.task_for_pid(c.mach_task_self(), pid, &task);

    if (kern_return != c.KERN_SUCCESS) {
        if (kern_return == c.KERN_FAILURE) return error.SipBlocked;
        if (kern_return == c.KERN_INVALID_ARGUMENT) return error.InvalidTarget;
        return error.KernelFailure;
    }

    return TaskPort{ .port = task };
}

pub fn errorMessage(err: GatekeeperError) []const u8 {
    return switch (err) {
        error.InsufficientPrivileges => "Error: requires root. Run with: sudo ./memory-map <PID>\n",
        error.SipBlocked => "Error: task_for_pid() denied. Target may be SIP-protected.\n",
        error.InvalidTarget => "Error: invalid PID. Process not found.\n",
        error.KernelFailure => "Error: kernel failure. Check codesign entitlements.\n",
    };
}
