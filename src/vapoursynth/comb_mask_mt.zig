const std = @import("std");
const math = std.math;

const filter = @import("../filters/comb_mask_mt.zig");
const helper = @import("../helper.zig");
const vszip = @import("../vszip.zig");

const vapoursynth = vszip.vapoursynth;
const vs = vapoursynth.vapoursynth4;
const ZAPI = vapoursynth.ZAPI;

const allocator = std.heap.c_allocator;
pub const filter_name = "CombMaskMT";

const Data = struct {
    node: ?*vs.Node = null,
    vi: *const vs.VideoInfo = undefined,
    thy1: i16 = 0,
    thy2: i16 = 0,
};

fn combMaskMTGetFrame(n: c_int, activation_reason: vs.ActivationReason, instance_data: ?*anyopaque, frame_data: ?*?*anyopaque, frame_ctx: ?*vs.FrameContext, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) ?*const vs.Frame {
    _ = frame_data;
    const d: *Data = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi);

    if (activation_reason == .Initial) {
        zapi.requestFrameFilter(n, d.node, frame_ctx);
    } else if (activation_reason == .AllFramesReady) {
        const src = zapi.initZFrame(d.node, n, frame_ctx, core);

        defer src.deinit();

        const dst = src.newVideoFrame();

        var plane: u32 = 0;
        while (plane < d.vi.format.numPlanes) : (plane += 1) {
            const srcp = src.getReadSlice(plane);
            const dstp = dst.getWriteSlice(plane);
            const w, const h, const stride = src.getDimensions(plane);
            filter.process(srcp, dstp, stride, w, h, d.thy1, d.thy2);
        }

        return dst.frame;
    }

    return null;
}

export fn combMaskMTFree(instance_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = core;
    const d: *Data = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi);

    zapi.freeNode(d.node);
    allocator.destroy(d);
}

pub export fn combMaskMTCreate(in: ?*const vs.Map, out: ?*vs.Map, user_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = user_data;
    var d: Data = .{};

    const zapi = ZAPI.init(vsapi);
    const map_in = zapi.initZMap(in);
    const map_out = zapi.initZMap(out);
    d.node, d.vi = map_in.getNodeVi("clip");
    if ((d.vi.format.sampleType != .Integer) or (d.vi.format.bitsPerSample != 8)) {
        map_out.setError(filter_name ++ ": only 8 bit int format supported.");
        zapi.freeNode(d.node);
        return;
    }

    d.thy1 = map_in.getInt(i16, "thY1") orelse 30;
    d.thy2 = map_in.getInt(i16, "thY2") orelse 30;

    if (d.thy1 > 255 or d.thy1 < 0) {
        map_out.setError(filter_name ++ ": thY1 value should be in range [0;255]");
        zapi.freeNode(d.node);
        return;
    }

    if (d.thy2 > 255 or d.thy2 < 0) {
        map_out.setError(filter_name ++ ": thY2 value should be in range [0;255]");
        zapi.freeNode(d.node);
        return;
    }

    if (d.thy1 > d.thy2) {
        map_out.setError(filter_name ++ ": thY1 can't be greater than thY2");
        zapi.freeNode(d.node);
        return;
    }

    const data: *Data = allocator.create(Data) catch unreachable;
    data.* = d;

    var deps = [_]vs.FilterDependency{
        .{ .source = d.node, .requestPattern = .StrictSpatial },
    };

    zapi.createVideoFilter(out, filter_name, d.vi, combMaskMTGetFrame, combMaskMTFree, .Parallel, &deps, data, core);
}
