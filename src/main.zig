const std = @import("std");
const c = @import("c");

const vendor_id = 0x2022;
const product_id = 0x0522;
const endpoint_out = 0x03;

var cpu_vendor_id: ?u16 = 0x1022;
var cpu_product_id: ?u16 = 0x14e3;

var gpu_vendor_id: ?u16 = 0x1002;
var gpu_product_id: ?u16 = 0x7550;

const hwmon_path = "/sys/class/hwmon";

const amd_cpu_temp_driver = "k10temp";
const amd_gpu_temp_driver = "amdgpu";
const amd_cpu_temp_label = "Tctl";
const amd_gpu_temp_label = "edge";

const Device = struct {
    vid: u16,
    pid: u16,
    name: []const u8,
    hwmon: []const u8,
};

fn writeTemperature(writer: *std.Io.Writer, temp: f32) !void {
    const tens: u8 = @intFromFloat(temp / 10.0);
    const ones: u8 = @intFromFloat(@mod(temp, 10.0));
    const tenths: u8 = @intFromFloat(@mod(temp * 10.0, 10.0));

    try writer.writeByte(tens);
    try writer.writeByte(ones);
    try writer.writeByte(tenths);
}

fn writePayload(writer: *std.Io.Writer, cpu_temp: f32, gpu_temp: f32) !void {
    // hardcoded header
    try writer.writeAll(&.{ 85, 170, 1, 1, 6 });

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
    var name_buf: [64]u8 = undefined;
    while (try walker.next(io)) |entry| {
        const name_path = try std.fmt.bufPrint(&buf, "{s}/{s}/name", .{ hwmon_path, entry.basename });
        const name = try readFileAndTrimWhitespaces(io, dir, name_path, &name_buf);

        if (std.mem.eql(u8, name, driver_name)) {
            const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ hwmon_path, entry.basename });
            const dupe = try allocator.dupe(u8, path);
            try result.append(allocator, dupe);
        }
    }

    return result;
}

fn readFileAndTrimWhitespaces(io: std.Io, dir: std.Io.Dir, path: []const u8, buf: []u8) ![]const u8 {
    const raw = try dir.readFile(io, path, buf);
    return std.mem.trim(u8, raw, &std.ascii.whitespace);
}

fn extractNumber(str: []const u8) !?u32 {
    const numbers = "0123456789";
    const start = std.mem.findAny(u8, str, numbers) orelse return null;
    const end = std.mem.findLastAny(u8, str, numbers) orelse return null;

    const result = try std.fmt.parseInt(u32, str[start .. end + 1], 10);
    return result;
}

fn getAmdTemperaturePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    temperature_name: []const u8,
) !?[]const u8 {
    const dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);

    var buf: [64]u8 = undefined;
    while (try walker.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.basename, "temp")) continue;
        if (!std.mem.endsWith(u8, entry.basename, "_label")) continue;
        const num = try extractNumber(entry.basename) orelse continue;

        const name = try readFileAndTrimWhitespaces(io, dir, entry.basename, &buf);
        if (!std.mem.eql(u8, name, temperature_name)) continue;

        const temperature_path = try std.fmt.allocPrint(allocator, "{s}/temp{d}_input", .{ dir_path, num });
        return temperature_path;
    }

    return null;
}

fn getDeviceVendorIdAndProductId(io: std.Io, hwpath: []const u8) !struct { u16, u16 } {
    const dir = try std.Io.Dir.openDirAbsolute(io, hwpath, .{});
    defer dir.close(io);

    var buf: [32]u8 = undefined;

    const v_str = try readFileAndTrimWhitespaces(io, dir, "device/vendor", &buf);
    const vid = try std.fmt.parseInt(u16, v_str, 0);

    const p_str = try readFileAndTrimWhitespaces(io, dir, "device/device", &buf);
    const pid = try std.fmt.parseInt(u16, p_str, 0);

    return .{ vid, pid };
}

fn getDeviceName(allocator: std.mem.Allocator, pacc: ?*c.pci_access, vid: u16, pid: u16) !?[]const u8 {
    var name_buf: [512]u8 = @splat(0);
    const name_ptr = c.pci_lookup_name(pacc, &name_buf, name_buf.len, c.PCI_LOOKUP_DEVICE, vid, pid) orelse return null;
    const name = std.mem.span(name_ptr);

    return try allocator.dupe(u8, name);
}

fn getTemperature(io: std.Io, path: []const u8) !f32 {
    var buf: [16]u8 = undefined;
    const temperature_str = try readFileAndTrimWhitespaces(io, std.Io.Dir.cwd(), path, &buf);
    const temperature_milli_c = try std.fmt.parseInt(u32, temperature_str, 10);
    const temperature_f32: f32 = @floatFromInt(temperature_milli_c);
    return temperature_f32 / 1000.0;
}

fn getDeviceInfo(allocator: std.mem.Allocator, io: std.Io, pacc: ?*c.pci_access, hwmon: []const u8) !Device {
    const vid, const pid = try getDeviceVendorIdAndProductId(io, hwmon);
    const name = try getDeviceName(allocator, pacc, vid, pid) orelse "unknown";

    return .{ .vid = vid, .pid = pid, .name = name, .hwmon = hwmon };
}

fn selectDevice(devices: []const Device, vid: ?u16, pid: ?u16) ?Device {
    if (vid == null or pid == null) {
        return null;
    }

    for (devices) |device| {
        if (vid.? == device.vid and pid.? == device.pid) {
            return device;
        }
    }

    std.log.warn("wanted device not found", .{});

    return null;
}

fn parseConfig(config: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, config, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const key = it.next().?;
        const value = it.next().?;

        if (std.mem.eql(u8, key, "cpu_vid")) {
            cpu_vendor_id = try std.fmt.parseInt(u16, value, 0);
        } else if (std.mem.eql(u8, key, "cpu_pid")) {
            cpu_product_id = try std.fmt.parseInt(u16, value, 0);
        } else if (std.mem.eql(u8, key, "gpu_vid")) {
            gpu_vendor_id = try std.fmt.parseInt(u16, value, 0);
        } else if (std.mem.eql(u8, key, "gpu_pid")) {
            gpu_product_id = try std.fmt.parseInt(u16, value, 0);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const config = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, "/etc/flux-pro-display/config", allocator, .limited(128)) catch null;
    if (config) |conf| try parseConfig(conf);

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

    const claim_result = c.libusb_claim_interface(handle, 0);
    if (claim_result < 0) {
        std.log.err("cannot claim interface 0 (err: {d})", .{claim_result});
        return error.LibUsbClaimInterfaceFailed;
    }

    std.log.info("claimed interface 0", .{});

    const amd_cpus_hwmon = try getHwmonPaths(allocator, io, amd_cpu_temp_driver);
    const amd_gpus_hwmon = try getHwmonPaths(allocator, io, amd_gpu_temp_driver);

    var cpus: std.ArrayList(Device) = .empty;
    var gpus: std.ArrayList(Device) = .empty;

    {
        const pacc = c.pci_alloc();
        c.pci_init(pacc);
        defer c.pci_cleanup(pacc);

        for (amd_cpus_hwmon.items) |cpu| {
            const device = try getDeviceInfo(allocator, io, pacc, cpu);
            try cpus.append(allocator, device);
        }

        for (amd_gpus_hwmon.items) |gpu| {
            const device = try getDeviceInfo(allocator, io, pacc, gpu);
            try gpus.append(allocator, device);
        }

        // TODO: intel cpus and nvidia gpus
    }

    for (cpus.items, 0..) |cpu, i| {
        std.log.info("cpu {d}: {x:0>4}:{x:0>4} {s}", .{ i, cpu.vid, cpu.pid, cpu.name });
    }
    for (gpus.items, 0..) |gpu, i| {
        std.log.info("gpu {d}: {x:0>4}:{x:0>4} {s}", .{ i, gpu.vid, gpu.pid, gpu.name });
    }

    if (cpu_vendor_id == null or cpu_product_id == null) {
        std.log.warn("wanted cpu not configured", .{});
    }

    if (gpu_vendor_id == null or gpu_product_id == null) {
        std.log.warn("wanted gpu not configured", .{});
    }

    const selected_cpu = selectDevice(cpus.items, cpu_vendor_id, cpu_product_id) orelse cpus.items[0];
    std.log.info("selected cpu: {x:0>4}:{x:0>4} {s}", .{ selected_cpu.vid, selected_cpu.pid, selected_cpu.name });

    const selected_gpu = selectDevice(gpus.items, gpu_vendor_id, gpu_product_id) orelse gpus.items[0];
    std.log.info("selected gpu: {x:0>4}:{x:0>4} {s}", .{ selected_gpu.vid, selected_gpu.pid, selected_gpu.name });

    const cpu_path = try getAmdTemperaturePath(allocator, io, selected_cpu.hwmon, amd_cpu_temp_label) orelse return error.SensorNotFound;
    const gpu_path = try getAmdTemperaturePath(allocator, io, selected_gpu.hwmon, amd_gpu_temp_label) orelse return error.SensorNotFound;

    var data_buf: [16]u8 = undefined;
    while (true) {
        var writer = std.Io.Writer.fixed(&data_buf);

        const cpu_temp = try getTemperature(io, cpu_path);
        const gpu_temp = try getTemperature(io, gpu_path);

        try writePayload(&writer, @round(cpu_temp * 10.0) / 10.0, @round(gpu_temp * 10.0) / 10.0);
        const data = writer.buffered();

        var transfered: c_int = 0;
        const result = c.libusb_bulk_transfer(handle, endpoint_out, data.ptr, @intCast(data.len), &transfered, 1000);
        if (result == 0) {
            std.log.debug("transfered {d} bytes, expected {d} bytes", .{ transfered, data.len });
        } else {
            std.log.err("transfer failed (err: {d})", .{result});
        }

        try std.Io.sleep(io, .fromSeconds(1), .real);
    }
}
