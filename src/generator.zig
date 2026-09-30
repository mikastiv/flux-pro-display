const std = @import("std");
const assert = std.debug.assert;

const EntryType = enum {
    vendor,
    device,
    subvendor,
};

const Vendor = struct {
    id: u16,
    name: []const u8,
    devices: std.ArrayList(Device),
};

const Device = struct {
    id: u16,
    name: []const u8,
};

fn getEntryType(line: []const u8) EntryType {
    if (std.mem.startsWith(u8, line, "\t\t")) {
        return .subvendor;
    }

    if (std.mem.startsWith(u8, line, "\t")) {
        return .device;
    }

    return .vendor;
}

fn escapeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '"') == null) return name;

    var escaped: std.ArrayList(u8) = .empty;

    for (name) |char| {
        if (char == '"') {
            try escaped.append(allocator, '\\');
        }

        try escaped.append(allocator, char);
    }

    return try escaped.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.cutPrefix(u8, arg, "--input-file=")) |path| {
            input_path = path;
        } else if (std.mem.cutPrefix(u8, arg, "--output-file=")) |path| {
            output_path = path;
        }
    }

    const input = try std.Io.Dir.cwd().openFile(io, input_path.?, .{});
    defer input.close(io);

    var read_buffer: [2048]u8 = undefined;
    var file_reader = input.reader(io, &read_buffer);
    const reader = &file_reader.interface;

    var vendors: std.ArrayList(Vendor) = .empty;
    var current_vendor: ?Vendor = null;
    while (try reader.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        const ty = getEntryType(line);

        var it = std.mem.tokenizeAny(u8, line, &std.ascii.whitespace);
        const id_str = it.next().?;
        const name = it.rest();

        switch (ty) {
            .vendor => {
                if (current_vendor) |vendor| {
                    try vendors.append(allocator, vendor);
                }

                current_vendor = .{
                    .id = try std.fmt.parseInt(u16, id_str, 16),
                    .name = try allocator.dupe(u8, name),
                    .devices = .empty,
                };
            },
            .device => {
                try current_vendor.?.devices.append(allocator, .{
                    .id = try std.fmt.parseInt(u16, id_str, 16),
                    .name = try allocator.dupe(u8, name),
                });
            },
            .subvendor => {},
        }
    }

    const output = try std.Io.Dir.cwd().createFile(io, output_path.?, .{});
    defer output.close(io);

    var write_buffer: [2048]u8 = undefined;
    var file_writer = output.writer(io, &write_buffer);
    const writer = &file_writer.interface;

    try writer.writeAll(
        \\pub const Vendor = struct {
        \\    id: u16,
        \\    name: []const u8,
        \\    devices: []const Device,
        \\};
        \\
        \\pub const Device = struct {
        \\    id: u16,
        \\    name: []const u8,
        \\};
        \\
        \\pub const vendors: []const Vendor = &.{
        \\
    );

    for (vendors.items) |vendor| {
        try writer.print(
            \\    .{{
            \\        .id = 0x{x:0>4},
            \\        .name = "{s}",
            \\        .devices = &.{{
            \\
        , .{
            vendor.id,
            try escapeName(allocator, vendor.name),
        });

        for (vendor.devices.items) |device| {
            try writer.print(
                \\            .{{ .id = 0x{x:0>4}, .name = "{s}" }},
                \\
            , .{
                device.id,
                try escapeName(allocator, device.name),
            });
        }

        try writer.writeAll(
            \\        },
            \\    },
            \\
        );
    }

    try writer.writeAll(
        \\};
        \\
    );

    try writer.flush();
}
