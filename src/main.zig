const std = @import("std");
const c = @import("c");

const vendor_id = 0x2022;
const product_id = 0x0522;
const endpoint_out = 0x3;

const hwmon_path = "/sys/class/hwmon";
const amd_cpu_temp_driver = "k10temp";
const amd_gpu_temp_driver = "amdgpu";

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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var ctx: ?*c.libusb_context = null;

    if (c.libusb_init(&ctx) < 0) return error.LibUsbInitFailed;
    defer c.libusb_exit(ctx);

    _ = c.libusb_set_option(ctx, c.LIBUSB_OPTION_LOG_LEVEL, c.LIBUSB_LOG_LEVEL_INFO);

    const handle = c.libusb_open_device_with_vid_pid(ctx, vendor_id, product_id) orelse return error.LibUsbOpenFailed;
    defer c.libusb_close(handle);

    std.log.info("opened usb device {x:0>4}:{x:0>4}", .{ vendor_id, product_id });

    if (c.libusb_kernel_driver_active(handle, 0) == 1) {
        std.log.info("kernel driver active on interface 0", .{});
        std.log.info("detaching...", .{});
        if (c.libusb_detach_kernel_driver(handle, 0) == 0) {
            std.log.info("kernel driver detached", .{});
        }
    }

    var result = c.libusb_claim_interface(handle, 0);
    if (result < 0) {
        std.log.err("cannot claim interface 0 (err: {d})", .{result});
        return error.LibUsbClaimInterfaceFailed;
    }

    std.log.info("claimed interface 0", .{});

    const amd_cpus = try getHwmonPaths(allocator, io, amd_cpu_temp_driver);
    const amd_gpus = try getHwmonPaths(allocator, io, amd_gpu_temp_driver);

    for (amd_cpus.items) |cpu| {
        std.log.info("cpu: {s}", .{cpu});
    }
    for (amd_gpus.items) |gpu| {
        std.log.info("gpu: {s}", .{gpu});
    }

    var data_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&data_buf);

    try writePayload(&writer, 42.0, 64.1);

    const data = writer.buffered();

    while (true) {
        var transfered: c_int = 0;
        result = c.libusb_bulk_transfer(handle, endpoint_out, data.ptr, @intCast(data.len), &transfered, 1000);
        if (result == 0) {
            std.log.info("transfered {d} bytes, expected {d} bytes", .{ transfered, data.len });
        } else {
            std.log.err("transfer failed (err: {d})", .{result});
        }

        try std.Io.sleep(io, .fromMilliseconds(1000), .real);
    }
}
