const std = @import("std");
const c = @import("c");

const vendor_id = 0x2022;
const product_id = 0x0522;
const endpoint_out = 0x3;

const hwmon_path = "/sys/class/hwmon";
const amd_cpu_temp_driver = "k10temp";
const amd_gpu_temp_driver = "amdgpu";
const cpu_temp_label = "Tctl";
const gpu_temp_label = "edge";

fn writeTemperature(writer: *std.Io.Writer, temp: f32) !void {
    const tens: u8 = @intFromFloat(temp / 10.0);
    const ones: u8 = @intFromFloat(@mod(temp, 10.0));
    const tenths: u8 = @intFromFloat(@mod(temp * 10.0, 10.0));

    try writer.writeByte(tens);
    try writer.writeByte(ones);
    try writer.writeByte(tenths);
}

fn writePayload(writer: *std.Io.Writer, cpu_temp: f32, gpu_temp: f32) !void {
    try writer.writeByte(85);
    try writer.writeByte(170);
    try writer.writeByte(1);
    try writer.writeByte(1);
    try writer.writeByte(6);

    try writeTemperature(writer, cpu_temp);
    try writeTemperature(writer, gpu_temp);

    var sum: u8 = 0;
    for (writer.buffered()) |byte| {
        sum +%= byte;
    }

    try writer.writeByte(sum);
}

fn getHwmonPaths(allocator: std.mem.Allocator, io: std.Io, driver_name: []const u8) !std.ArrayList([]const u8) {
    const dir = try std.Io.Dir.openDirAbsolute(io, hwmon_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var result: std.ArrayList([]const u8) = .empty;

    var buf: [std.os.linux.PATH_MAX]u8 = undefined;
    while (try walker.next(io)) |entry| {
        const name_path = try std.fmt.bufPrint(&buf, "{s}/{s}/name", .{ hwmon_path, entry.basename });

        const name_raw = try dir.readFileAlloc(io, name_path, allocator, .limited(64));
        const name = std.mem.trim(u8, name_raw, &std.ascii.whitespace);

        if (std.mem.eql(u8, name, driver_name)) {
            const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ hwmon_path, entry.basename });
            const dupe = try allocator.dupe(u8, path);
            try result.append(allocator, dupe);
        }
    }

    return result;
}

fn getTemperaturePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    temperature_name: []const u8,
    comptime max_temperature_index: usize,
) !?[]const u8 {
    const dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);

    var buf: [std.os.linux.PATH_MAX]u8 = undefined;
    for (1..max_temperature_index + 1) |i| {
        const label_path = try std.fmt.bufPrint(&buf, "temp{d}_label", .{i});
        const name_raw = dir.readFileAlloc(io, label_path, allocator, .limited(64)) catch continue;
        const name = std.mem.trim(u8, name_raw, &std.ascii.whitespace);
        if (!std.mem.eql(u8, name, temperature_name)) continue;

        const temperature_path = try std.fmt.allocPrint(allocator, "{s}/temp{d}_input", .{ dir_path, i });
        return temperature_path;
    }

    return null;
}

fn getTemperature(io: std.Io, path: []const u8) !f32 {
    var buf: [32]u8 = undefined;
    const temperature_raw = try std.Io.Dir.cwd().readFile(io, path, &buf);
    const temperature_str = std.mem.trim(u8, temperature_raw, &std.ascii.whitespace);
    const temperature_milli_c = try std.fmt.parseInt(u32, temperature_str, 10);
    const temperature_f32: f32 = @floatFromInt(temperature_milli_c);
    return temperature_f32 / 1000.0;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var ctx: ?*c.libusb_context = null;

    if (c.libusb_init(&ctx) < 0) return error.LibUsbInitFailed;
    defer c.libusb_exit(ctx);

    _ = c.libusb_set_option(ctx, c.LIBUSB_OPTION_LOG_LEVEL, c.LIBUSB_LOG_LEVEL_INFO);

    const handle = c.libusb_open_device_with_vid_pid(ctx, vendor_id, product_id) orelse return error.LibUsbOpenFailed;
    defer c.libusb_close(handle);

    std.log.debug("opened usb device {x:0>4}:{x:0>4}", .{ vendor_id, product_id });

    if (c.libusb_kernel_driver_active(handle, 0) == 1) {
        std.log.debug("kernel driver active on interface 0", .{});
        std.log.debug("detaching...", .{});
        if (c.libusb_detach_kernel_driver(handle, 0) == 0) {
            std.log.debug("kernel driver detached", .{});
        }
    }

    var result = c.libusb_claim_interface(handle, 0);
    if (result < 0) {
        std.log.err("cannot claim interface 0 (err: {d})", .{result});
        return error.LibUsbClaimInterfaceFailed;
    }

    std.log.debug("claimed interface 0", .{});

    const amd_cpus = try getHwmonPaths(allocator, io, amd_cpu_temp_driver);
    const amd_gpus = try getHwmonPaths(allocator, io, amd_gpu_temp_driver);

    const cpu_path = try getTemperaturePath(allocator, io, amd_cpus.items[0], cpu_temp_label, 8) orelse return error.SensorNotFound;
    const gpu_path = try getTemperaturePath(allocator, io, amd_gpus.items[0], gpu_temp_label, 8) orelse return error.SensorNotFound;

    var data_buf: [256]u8 = undefined;
    while (true) {
        var writer = std.Io.Writer.fixed(&data_buf);

        const cpu_temp = try getTemperature(io, cpu_path);
        const gpu_temp = try getTemperature(io, gpu_path);

        try writePayload(&writer, @round(cpu_temp * 10.0) / 10.0, @round(gpu_temp * 10.0) / 10.0);
        const data = writer.buffered();

        var transfered: c_int = 0;
        result = c.libusb_bulk_transfer(handle, endpoint_out, data.ptr, @intCast(data.len), &transfered, 1000);
        if (result == 0) {
            std.log.debug("transfered {d} bytes, expected {d} bytes", .{ transfered, data.len });
        } else {
            std.log.err("transfer failed (err: {d})", .{result});
        }

        try std.Io.sleep(io, .fromMilliseconds(2000), .real);
    }
}
