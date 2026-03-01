const std = @import("std");
const os = std.os;
const fs = std.fs;
const path = fs.path;
const win = os.windows;

fn readPathAlloc(allocator: std.mem.Allocator, file_path: []const u8, max_size: usize) ![]u8 {
    const maybe_absolute = path.isAbsolute(file_path) or std.mem.startsWith(u8, file_path, "\\\\");
    if (maybe_absolute) {
        var f = try fs.openFileAbsolute(file_path, .{});
        defer f.close();
        return try f.readToEndAlloc(allocator, max_size);
    }
    return fs.cwd().readFileAlloc(allocator, file_path, max_size);
}

fn readFromAnyWslDistro(allocator: std.mem.Allocator, sc_path: []const u8, max_size: usize) !?[]u8 {
    if (sc_path.len == 0 or sc_path[0] != '/') {
        return null;
    }

    var root = fs.openDirAbsolute("\\\\wsl.localhost\\", .{ .iterate = true }) catch {
        return null;
    };
    defer root.close();

    var it = root.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "\\\\wsl.localhost\\");
        try out.appendSlice(allocator, entry.name);
        try out.append(allocator, '\\');
        for (sc_path[1..]) |ch| {
            try out.append(allocator, if (ch == '/') '\\' else ch);
        }
        const candidate = try out.toOwnedSlice(allocator);
        defer allocator.free(candidate);

        if (readPathAlloc(allocator, candidate, max_size)) |data| {
            return data;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    return null;
}

fn posixToWindowsViaWslpath(allocator: std.mem.Allocator, sc_path: []const u8) !?[]u8 {
    if (sc_path.len == 0 or sc_path[0] != '/') {
        return null;
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "wsl.exe", "wslpath", "-w", sc_path },
        .max_output_bytes = 4096,
    }) catch {
        return null;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    const converted = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (converted.len == 0) {
        return null;
    }
    return try allocator.dupe(u8, converted);
}

fn posixToWindowsDrivePath(allocator: std.mem.Allocator, sc_path: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, sc_path, "/mnt/")) {
        return null;
    }
    if (sc_path.len < 7 or sc_path[6] != '/') {
        return null;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, std.ascii.toUpper(sc_path[5]));
    try out.appendSlice(allocator, ":\\");
    for (sc_path[7..]) |ch| {
        try out.append(allocator, if (ch == '/') '\\' else ch);
    }
    return try out.toOwnedSlice(allocator);
}

fn posixToWslUncPathWithPrefix(allocator: std.mem.Allocator, sc_path: []const u8, prefix: []const u8) !?[]u8 {
    if (sc_path.len == 0 or sc_path[0] != '/') {
        return null;
    }

    const distro = std.process.getEnvVarOwned(allocator, "WSL_DISTRO_NAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(distro);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, distro);
    try out.append(allocator, '\\');
    for (sc_path[1..]) |ch| {
        try out.append(allocator, if (ch == '/') '\\' else ch);
    }
    return try out.toOwnedSlice(allocator);
}

fn readShellcode(allocator: std.mem.Allocator, sc_path: []const u8) ![]u8 {
    const max_size = 1024 * 1024 * 1024;

    if (readPathAlloc(allocator, sc_path, max_size)) |data| {
        return data;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (try posixToWindowsDrivePath(allocator, sc_path)) |win_path| {
        defer allocator.free(win_path);
        if (readPathAlloc(allocator, win_path, max_size)) |data| {
            return data;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (try posixToWslUncPathWithPrefix(allocator, sc_path, "\\\\wsl$\\")) |unc_path| {
        defer allocator.free(unc_path);
        if (readPathAlloc(allocator, unc_path, max_size)) |data| {
            return data;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (try posixToWslUncPathWithPrefix(allocator, sc_path, "\\\\wsl.localhost\\")) |unc_path| {
        defer allocator.free(unc_path);
        if (readPathAlloc(allocator, unc_path, max_size)) |data| {
            return data;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (try posixToWindowsViaWslpath(allocator, sc_path)) |wslpath_win| {
        defer allocator.free(wslpath_win);
        if (readPathAlloc(allocator, wslpath_win, max_size)) |data| {
            return data;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    if (readFromAnyWslDistro(allocator, sc_path, max_size) catch null) |data| {
        return data;
    }

    return error.FileNotFound;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len == 1) {
        std.log.err("usage: {s} scpath", .{path.basename(args[0])});
        return;
    }
    const data = readShellcode(allocator, args[1]) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("shellcode file not found: {s}", .{args[1]});
        }
        return err;
    };
    const ptr = try win.VirtualAlloc(
        null,
        data.len,
        win.MEM_COMMIT | win.MEM_RESERVE,
        win.PAGE_EXECUTE_READWRITE,
    );
    defer win.VirtualFree(ptr, 0, win.MEM_RELEASE);
    const buf: [*c]u8 = @ptrCast(ptr);
    @memcpy(buf[0..data.len], data);
    @as(*const fn () void, @ptrCast(@alignCast(ptr)))();
}
