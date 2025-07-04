const std = @import("std");
const math = std.math;

const filter = @import("../filters/planeminmax.zig");
const helper = @import("../helper.zig");
const vszip = @import("../vszip.zig");

const vapoursynth = vszip.vapoursynth;
const vs = vapoursynth.vapoursynth4;
const ZAPI = vapoursynth.ZAPI;

const allocator = std.heap.c_allocator;
pub const filter_name = "PlaneMinMax";

pub const Data = struct {
    node1: ?*vs.Node = null,
    node2: ?*vs.Node = null,
    vi: *const vs.VideoInfo = undefined,
    peak: u16 = 0,
    minthr: f32 = 0,
    maxthr: f32 = 0,
    hist_size: u32 = 0,
    planes: [3]bool = .{ true, false, false },
    prop: StringProp = undefined,
};

const StringProp = struct {
    d: [:0]u8,
    ma: [:0]u8,
    mi: [:0]u8,
};

fn PlaneMinMax(comptime T: type, comptime refb: bool) type {
    return struct {
        pub fn getFrame(n: c_int, activation_reason: vs.ActivationReason, instance_data: ?*anyopaque, frame_data: ?*?*anyopaque, frame_ctx: ?*vs.FrameContext, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) ?*const vs.Frame {
            _ = frame_data;
            const d: *Data = @ptrCast(@alignCast(instance_data));
            const zapi = ZAPI.init(vsapi);

            if (activation_reason == .Initial) {
                zapi.requestFrameFilter(n, d.node1, frame_ctx);
                if (refb) {
                    zapi.requestFrameFilter(n, d.node2, frame_ctx);
                }
            } else if (activation_reason == .AllFramesReady) {
                const src = zapi.initZFrame(d.node1, n, frame_ctx, core);
                const ref = if (refb) zapi.initZFrame(d.node2, n, frame_ctx, core);
                const dst = src.copyFrame();
                const props = dst.getPropertiesRW();
                props.deleteKey(d.prop.d);
                props.deleteKey(d.prop.ma);
                props.deleteKey(d.prop.mi);

                var plane: u32 = 0;
                while (plane < d.vi.format.numPlanes) : (plane += 1) {
                    if (!(d.planes[plane])) {
                        continue;
                    }

                    const srcp = src.getReadSlice2(T, plane);
                    const w, const h, const stride = src.getDimensions2(T, plane);
                    var stats: filter.Stats = undefined;
                    if (refb) {
                        const refp = ref.getReadSlice2(T, plane);
                        stats = if (@typeInfo(T) == .int) filter.minMaxIntRef(T, srcp, refp, stride, w, h, d) else filter.minMaxFloatRef(T, srcp, refp, stride, w, h, d);

                        _ = switch (stats) {
                            .i => props.setFloat(d.prop.d, stats.i.diff, .Append),
                            .f => props.setFloat(d.prop.d, stats.f.diff, .Append),
                        };
                    } else {
                        stats = if (@typeInfo(T) == .int) filter.minMaxInt(T, srcp, stride, w, h, d) else filter.minMaxFloat(T, srcp, stride, w, h, d);
                    }

                    switch (stats) {
                        .i => {
                            props.setInt(d.prop.ma, stats.i.max, .Append);
                            props.setInt(d.prop.mi, stats.i.min, .Append);
                        },
                        .f => {
                            props.setFloat(d.prop.ma, stats.f.max, .Append);
                            props.setFloat(d.prop.mi, stats.f.min, .Append);
                        },
                    }
                }

                src.deinit();
                if (refb) ref.deinit();

                return dst.frame;
            }

            return null;
        }
    };
}

export fn planeMinMaxFree(instance_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = core;
    const d: *Data = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi);

    allocator.free(d.prop.d);
    allocator.free(d.prop.ma);
    allocator.free(d.prop.mi);

    if (d.node2) |node| zapi.freeNode(node);
    zapi.freeNode(d.node1);
    allocator.destroy(d);
}

pub export fn planeMinMaxCreate(in: ?*const vs.Map, out: ?*vs.Map, user_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = user_data;
    var d: Data = .{};

    const zapi = ZAPI.init(vsapi);
    const map_in = zapi.initZMap(in);
    const map_out = zapi.initZMap(out);
    d.node1, d.vi = map_in.getNodeVi("clipa");
    const dt = helper.DataType.select(map_out, d.node1, d.vi, filter_name) catch return;

    d.node2 = map_in.getNode("clipb");
    const refb = d.node2 != null;
    const nodes = [_]?*vs.Node{ d.node1, d.node2 };
    if (refb) {
        helper.compareNodes(map_out, &nodes, .BIGGER_THAN, filter_name, &zapi) catch return;
    }

    helper.mapGetPlanes(map_in, map_out, &nodes, &d.planes, d.vi.format.numPlanes, filter_name, &zapi) catch return;
    d.hist_size = if (d.vi.format.sampleType == .Float) 65536 else math.shl(u32, 1, d.vi.format.bitsPerSample);
    d.peak = @intCast(d.hist_size - 1);
    d.maxthr = getThr(map_in, map_out, &nodes, "maxthr", &zapi) catch return;
    d.minthr = getThr(map_in, map_out, &nodes, "minthr", &zapi) catch return;

    const prop_in = map_in.getData("prop", 0) orelse "psm";
    d.prop = .{
        .d = std.fmt.allocPrintZ(allocator, "{s}Diff", .{prop_in}) catch unreachable,
        .ma = std.fmt.allocPrintZ(allocator, "{s}Max", .{prop_in}) catch unreachable,
        .mi = std.fmt.allocPrintZ(allocator, "{s}Min", .{prop_in}) catch unreachable,
    };

    const data: *Data = allocator.create(Data) catch unreachable;
    data.* = d;

    const rp2: vs.RequestPattern = if (refb and (d.vi.numFrames <= zapi.getVideoInfo(d.node2).numFrames)) .StrictSpatial else .FrameReuseLastOnly;
    const deps = [_]vs.FilterDependency{
        .{ .source = d.node1, .requestPattern = .StrictSpatial },
        .{ .source = d.node2, .requestPattern = rp2 },
    };

    const getFrame = switch (dt) {
        .U8 => if (refb) &PlaneMinMax(u8, true).getFrame else &PlaneMinMax(u8, false).getFrame,
        .U16 => if (refb) &PlaneMinMax(u16, true).getFrame else &PlaneMinMax(u16, false).getFrame,
        .F16 => if (refb) &PlaneMinMax(f16, true).getFrame else &PlaneMinMax(f16, false).getFrame,
        .F32 => if (refb) &PlaneMinMax(f32, true).getFrame else &PlaneMinMax(f32, false).getFrame,
    };

    const ndeps: usize = if (refb) 2 else 1;
    zapi.createVideoFilter(out, filter_name, d.vi, getFrame, planeMinMaxFree, .Parallel, deps[0..ndeps], data, core);
}

pub fn getThr(in: ZAPI.ZMap(?*const vs.Map), out: ZAPI.ZMap(?*vs.Map), nodes: []const ?*vs.Node, comptime key: [:0]const u8, zapi: *const ZAPI) !f32 {
    var err_msg: ?[:0]const u8 = null;
    errdefer {
        out.setError(err_msg.?);
        for (nodes) |node| {
            if (node) |n| {
                zapi.freeNode(n);
            }
        }
    }

    const thr = in.getFloat(f32, key) orelse 0;
    if (thr < 0 or thr > 1) {
        err_msg = filter_name ++ ": " ++ key ++ " should be a float between 0.0 and 1.0";
        return error.ValidationError;
    }

    return thr;
}
