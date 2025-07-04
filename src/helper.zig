const std = @import("std");
const math = std.math;

const vszip = @import("vszip.zig");
const vapoursynth = vszip.vapoursynth;
const vs = vapoursynth.vapoursynth4;
const vsh = vapoursynth.vshelper;
const ZAPI = vapoursynth.ZAPI;

pub const BPSType = enum {
    U8,
    U9,
    U10,
    U12,
    U14,
    U16,
    U32,
    F16,
    F32,

    pub fn select(map: ZAPI.ZMap(?*vs.Map), node: ?*vs.Node, vi: *const vs.VideoInfo, comptime name: []const u8) !BPSType {
        var err_msg: ?[:0]const u8 = null;
        errdefer {
            map.setError(err_msg.?);
            map.api.freeNode(node);
        }

        if (vi.format.sampleType == .Integer) {
            switch (vi.format.bitsPerSample) {
                8 => return .U8,
                9 => return .U9,
                10 => return .U10,
                12 => return .U12,
                14 => return .U14,
                16 => return .U16,
                32 => return .U32,
                else => return {
                    err_msg = name ++ ": not supported Int format.";
                    return error.format;
                },
            }
        } else {
            switch (vi.format.bitsPerSample) {
                16 => return .F16,
                32 => return .F32,
                else => return {
                    err_msg = name ++ ": not supported Float format.";
                    return error.format;
                },
            }
        }
    }
};

pub const DataType = enum {
    U8,
    U16,
    F16,
    F32,

    pub fn select(map: ZAPI.ZMap(?*vs.Map), node: ?*vs.Node, vi: *const vs.VideoInfo, comptime name: []const u8) !DataType {
        var err_msg: ?[:0]const u8 = null;
        errdefer {
            map.setError(err_msg.?);
            map.api.freeNode(node);
        }

        if (vi.format.sampleType == .Integer) {
            switch (vi.format.bytesPerSample) {
                1 => return .U8,
                2 => return .U16,
                else => return {
                    err_msg = name ++ ": not supported Int format.";
                    return error.format;
                },
            }
        } else {
            switch (vi.format.bytesPerSample) {
                2 => return .F16,
                4 => return .F32,
                else => return {
                    err_msg = name ++ ": not supported Float format.";
                    return error.format;
                },
            }
        }
    }
};

pub fn absDiff(x: anytype, y: anytype) @TypeOf(x) {
    return if (x > y) (x - y) else (y - x);
}

pub fn mapGetPlanes(in: ZAPI.ZMap(?*const vs.Map), out: ZAPI.ZMap(?*vs.Map), nodes: []const ?*vs.Node, process: []bool, num_planes: c_int, comptime name: []const u8, zapi: *const ZAPI) !void {
    const num_e = in.numElements("planes") orelse return;
    @memset(process, false);

    var err_msg: ?[:0]const u8 = null;
    errdefer {
        out.setError(err_msg.?);
        for (nodes) |node| {
            if (node) |n| {
                zapi.freeNode(n);
            }
        }
    }

    var i: u32 = 0;
    while (i < num_e) : (i += 1) {
        const e = in.getInt2(i32, "planes", i).?;
        if ((e < 0) or (e >= num_planes)) {
            err_msg = name ++ ": plane index out of range";
            return error.ValidationError;
        }

        const ue: u32 = @intCast(e);
        if (process[ue]) {
            err_msg = name ++ ": plane specified twice.";
            return error.ValidationError;
        }

        process[ue] = true;
    }
}

pub const ClipLen = enum {
    SAME_LEN,
    BIGGER_THAN,
    MISMATCH,
};

pub fn compareNodes(out: ZAPI.ZMap(?*vs.Map), nodes: []const ?*vs.Node, len: ClipLen, comptime name: []const u8, zapi: *const ZAPI) !void {
    const vi0 = zapi.getVideoInfo(nodes[0]);
    var err_msg: ?[:0]const u8 = null;
    errdefer {
        out.setError(err_msg.?);
        for (nodes) |node| {
            if (node) |n| {
                zapi.freeNode(n);
            }
        }
    }

    for (nodes[1..]) |node| {
        const vi = zapi.getVideoInfo(node);
        if (!vsh.isConstantVideoFormat(vi)) {
            err_msg = name ++ ": all input clips must have constant format.";
            return error.constant_format;
        }
        if ((vi0.width != vi.width) or (vi0.height != vi.height)) {
            err_msg = name ++ ": all input clips must have the same width and height.";
            return error.width_height;
        }
        if (vi0.format.colorFamily != vi.format.colorFamily) {
            err_msg = name ++ ": all input clips must have the same color family.";
            return error.color_family;
        }
        if ((vi0.format.subSamplingW != vi.format.subSamplingW) or (vi0.format.subSamplingH != vi.format.subSamplingH)) {
            err_msg = name ++ ": all input clips must have the same subsampling.";
            return error.subsampling;
        }
        if (vi0.format.bitsPerSample != vi.format.bitsPerSample) {
            err_msg = name ++ ": all input clips must have the same bit depth.";
            return error.bit_depth;
        }

        switch (len) {
            .SAME_LEN => if (vi0.numFrames != vi.numFrames) {
                err_msg = name ++ ": all input clips must have the same length.";
                return error.length;
            },
            .BIGGER_THAN => if (vi0.numFrames > vi.numFrames) {
                err_msg = name ++ ": second clip has less frames than input clip.";
                return error.length;
            },
            .MISMATCH => {},
        }
    }
}

pub fn getPeak(vi: *const vs.VideoInfo) u16 {
    if (vi.format.sampleType == .Integer) {
        return @intCast(math.shl(u32, 1, vi.format.bitsPerSample) - 1);
    } else {
        return math.maxInt(u16);
    }
}

pub fn toRGBS(node: ?*vs.Node, core: ?*vs.Core, zapi: *const ZAPI) ?*vs.Node {
    const vi = zapi.getVideoInfo(node);
    if ((vi.format.colorFamily == .RGB) and (vi.format.sampleType == .Float)) {
        return node;
    }

    const matrix: i32 = if (vi.height > 650) 1 else 6;
    const args = zapi.createZMap();
    _ = args.consumeNode("clip", node, .Replace);
    args.setInt("matrix_in", matrix, .Replace);
    args.setInt("format", @intFromEnum(vs.PresetVideoFormat.RGBS), .Replace);

    const vsplugin = zapi.getPluginByID2(.Resize, core);
    const ret = args.invoke(vsplugin, "Bicubic");
    const out = args.getNode("clip");
    ret.free();
    args.free();
    return out;
}

pub fn getVal(comptime T: type, ptr: anytype, dist: isize) T {
    const adr: isize = @intCast(@intFromPtr(ptr));
    const uadr: usize = @intCast(adr + dist);
    const ptr2: [*]const T = @ptrFromInt(uadr);
    return ptr2[0];
}

pub fn getVal2(comptime T: type, ptr: anytype, x: u32, y: u32) T {
    const ix: i32 = @intCast(x);
    const iy: i32 = @intCast(y);
    const adr: isize = @intCast(@intFromPtr(ptr));
    const uadr: usize = @intCast(adr + ix - iy);
    const ptr2: [*]const T = @ptrFromInt(uadr);
    return ptr2[0];
}
