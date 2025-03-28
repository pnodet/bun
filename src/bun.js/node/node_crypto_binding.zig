const std = @import("std");
const bun = @import("root").bun;
const Environment = bun.Environment;
const JSC = bun.JSC;
const string = bun.string;
const Output = bun.Output;
const ZigString = JSC.ZigString;
const Crypto = JSC.API.Bun.Crypto;
const BoringSSL = bun.BoringSSL.c;
const assert = bun.assert;
const EVP = Crypto.EVP;
const PBKDF2 = EVP.PBKDF2;
const JSValue = JSC.JSValue;
const validators = @import("./util/validators.zig");
const JSGlobalObject = JSC.JSGlobalObject;
const JSError = bun.JSError;
const String = bun.String;
const UUID = bun.UUID;

fn ExternCryptoJob(
    comptime name: []const u8,
    comptime externRunTask: fn (*anyopaque, *JSGlobalObject) callconv(.c) void,
    comptime externRunFromJS: fn (*anyopaque, *JSGlobalObject) callconv(.c) void,
    comptime externDeinit: fn (*anyopaque) callconv(.c) void,
) type {
    return struct {
        vm: *JSC.VirtualMachine,
        task: JSC.WorkPoolTask,
        any_task: JSC.AnyTask,

        ctx: *anyopaque,

        pub fn create(global: *JSGlobalObject, ctx: *anyopaque) callconv(.c) *@This() {
            const vm = global.bunVM();
            const job = bun.new(@This(), .{
                .vm = vm,
                .task = .{
                    .callback = &runTask,
                },
                .any_task = undefined,
                .ctx = ctx,
            });
            job.any_task = JSC.AnyTask.New(@This(), &runFromJS).init(job);
            return job;
        }

        pub fn createAndSchedule(global: *JSGlobalObject, ctx: *anyopaque) callconv(.c) void {
            var job = create(global, ctx);
            job.schedule();
        }

        pub fn runTask(task: *JSC.WorkPoolTask) void {
            const job: *@This() = @fieldParentPtr("task", task);
            var vm = job.vm;
            defer vm.enqueueTaskConcurrent(JSC.ConcurrentTask.create(job.any_task.task()));

            externRunTask(job.ctx, vm.global);
        }

        pub fn runFromJS(this: *@This()) void {
            defer this.deinit();
            const vm = this.vm;

            if (vm.isShuttingDown()) {
                return;
            }

            externRunFromJS(this.ctx, vm.global);
        }

        fn deinit(this: *@This()) void {
            externDeinit(this.ctx);
            bun.destroy(this);
        }

        pub fn schedule(this: *@This()) callconv(.c) void {
            JSC.WorkPool.schedule(&this.task);
        }

        comptime {
            @export(&create, .{ .name = "Bun__" ++ name ++ "__create" });
            @export(&schedule, .{ .name = "Bun__" ++ name ++ "__schedule" });
            @export(&createAndSchedule, .{ .name = "Bun__" ++ name ++ "__createAndSchedule" });
        }
    };
}

extern fn Bun__CheckPrimeJobCtx__runTask(ctx: *anyopaque, global: *JSGlobalObject) void;
extern fn Bun__CheckPrimeJobCtx__runFromJS(ctx: *anyopaque, global: *JSGlobalObject) void;
extern fn Bun__CheckPrimeJobCtx__deinit(ctx: *anyopaque) void;

const CheckPrimeJob = ExternCryptoJob(
    "CheckPrimeJob",
    Bun__CheckPrimeJobCtx__runTask,
    Bun__CheckPrimeJobCtx__runFromJS,
    Bun__CheckPrimeJobCtx__deinit,
);

extern fn Bun__GeneratePrimeJobCtx__runTask(ctx: *anyopaque, global: *JSGlobalObject) void;
extern fn Bun__GeneratePrimeJobCtx__runFromJS(ctx: *anyopaque, global: *JSGlobalObject) void;
extern fn Bun__GeneratePrimeJobCtx__deinit(ctx: *anyopaque) void;

const GeneratePrimeJob = ExternCryptoJob(
    "GeneratePrimeJob",
    Bun__GeneratePrimeJobCtx__runTask,
    Bun__GeneratePrimeJobCtx__runFromJS,
    Bun__GeneratePrimeJobCtx__deinit,
);

comptime {
    _ = CheckPrimeJob;
    _ = GeneratePrimeJob;
}

const random = struct {
    const max_possible_length = @min(JSC.ArrayBuffer.max_size, std.math.maxInt(i32));
    const max_range = 0xffff_ffff_ffff;

    fn randomInt(global: *JSC.JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        var min_value, var max_value, var callback = callFrame.argumentsAsArray(3);

        var min_specified = true;
        if (max_value.isUndefined() or max_value.isCallable()) {
            callback = max_value;
            max_value = min_value;
            min_value = JSValue.jsNumber(0);
            min_specified = false;
        }

        if (!callback.isUndefined()) {
            _ = try validators.validateFunction(global, "callback", callback);
        }

        if (!min_value.isSafeInteger()) {
            return global.throwInvalidArgumentTypeValue2("min", "a safe integer", min_value);
        }
        if (!max_value.isSafeInteger()) {
            return global.throwInvalidArgumentTypeValue2("max", "a safe integer", max_value);
        }

        const min: i64 = @intFromFloat(@trunc(min_value.asNumber()));
        const max: i64 = @intFromFloat(@trunc(max_value.asNumber()));

        if (max <= min) {
            return global.ERR_OUT_OF_RANGE("The value of \"max\" is out of range. It must be greater than the value of \"min\" ({d}). Received {d}", .{
                min,
                max,
            }).throw();
        }

        if (max - min > max_range) {
            if (min_specified) {
                return global.ERR_OUT_OF_RANGE("The value of \"max - min\" is out of range. It must be <= {d}. Received {d}", .{ max_range, max - min }).throw();
            }
            return global.ERR_OUT_OF_RANGE("The value of \"max\" is out of range. It must be <= {d}. Received {d}", .{ max_range, max - min }).throw();
        }

        const res = std.crypto.random.intRangeLessThan(i64, min, max);

        if (!callback.isUndefined()) {
            callback.callNextTick(global, [2]JSValue{ .undefined, JSValue.jsNumber(res) });
            return JSValue.jsUndefined();
        }

        return JSValue.jsNumber(res);
    }

    fn randomUUID(global: *JSGlobalObject, callFrame: *JSC.CallFrame) JSError!JSValue {
        const args = callFrame.arguments();

        var disable_entropy_cache = false;
        if (args.len > 0) {
            const options = args[0];
            if (options != .undefined) {
                try validators.validateObject(global, options, "options", .{}, .{});
                if (try options.get(global, "disableEntropyCache")) |disable_entropy_cache_value| {
                    disable_entropy_cache = try validators.validateBoolean(global, disable_entropy_cache_value, "options.disableEntropyCache", .{});
                }
            }
        }

        var str, var bytes = String.createUninitialized(.latin1, 36);

        const uuid = if (disable_entropy_cache)
            UUID.init()
        else
            global.bunVM().rareData().nextUUID();

        uuid.print(bytes[0..36]);
        return str.transferToJS(global);
    }

    fn assertOffset(global: *JSGlobalObject, offset_value: JSValue, element_size: u8, length: usize) JSError!u32 {
        if (!offset_value.isNumber()) {
            return global.throwInvalidArgumentTypeValue("offset", "number", offset_value);
        }
        const offset = offset_value.asNumber() * @as(f32, @floatFromInt(element_size));

        const max_length = @min(length, max_possible_length);
        if (std.math.isNan(offset) or offset > @as(f64, @floatFromInt(max_length)) or offset < 0) {
            return global.throwRangeError(offset, .{ .field_name = "offset", .min = 0, .max = max_length });
        }

        return @intFromFloat(offset);
    }
    fn assertSize(global: *JSGlobalObject, size_value: JSValue, element_size: u8, offset: u32, length: usize) JSError!u32 {
        var size = try validators.validateNumber(global, size_value, "size", null, null);
        size *= @as(f32, @floatFromInt(element_size));

        if (std.math.isNan(size) or size > max_possible_length or size < 0) {
            return global.throwRangeError(size, .{ .field_name = "size", .min = 0, .max = max_possible_length });
        }

        if (size + @as(f32, @floatFromInt(offset)) > @as(f64, @floatFromInt(length))) {
            return global.throwRangeError(size + @as(f32, @floatFromInt(offset)), .{ .field_name = "size + offset", .max = @intCast(length) });
        }

        return @intFromFloat(size);
    }

    pub const Job = struct {
        vm: *JSC.VirtualMachine,
        task: JSC.WorkPoolTask,
        any_task: JSC.AnyTask,

        callback: JSValue,
        value: JSValue,
        bytes: [*]u8,
        offset: u32,
        length: usize,

        pub fn runTask(task: *JSC.WorkPoolTask) void {
            const job: *Job = @fieldParentPtr("task", task);
            defer job.vm.enqueueTaskConcurrent(JSC.ConcurrentTask.create(job.any_task.task()));

            bun.csprng(job.bytes[job.offset..][0..job.length]);
        }

        pub fn runFromJS(this: *Job) void {
            defer this.deinit();
            const vm = this.vm;

            if (vm.isShuttingDown()) {
                return;
            }

            vm.eventLoop().runCallback(this.callback, vm.global, .undefined, &.{ .null, this.value });
        }

        pub fn create(global: *JSGlobalObject, value: JSValue, bytes: [*]u8, offset: u32, length: usize, callback: JSValue) *Job {
            const vm = global.bunVM();

            const job = bun.new(Job, .{
                .vm = vm,
                .task = .{
                    .callback = &Job.runTask,
                },
                .any_task = undefined,

                .callback = callback,
                .value = value,
                .bytes = bytes,
                .offset = offset,
                .length = length,
            });
            job.callback.protect();
            job.value.protect();
            job.any_task = JSC.AnyTask.New(Job, &Job.runFromJS).init(job);
            return job;
        }

        fn schedule(this: *Job) void {
            JSC.WorkPool.schedule(&this.task);
        }

        fn deinit(this: *Job) void {
            this.value.unprotect();
            this.callback.unprotect();
            bun.destroy(this);
        }
    };

    fn randomBytes(global: *JSGlobalObject, callFrame: *JSC.CallFrame) JSError!JSValue {
        const size_value, const callback = callFrame.argumentsAsArray(2);

        const size = try assertSize(global, size_value, 1, 0, max_possible_length + 1);

        if (!callback.isUndefined()) {
            _ = try validators.validateFunction(global, "callback", callback);
        }

        const result, const bytes = try JSC.ArrayBuffer.alloc(global, .ArrayBuffer, size);

        if (callback.isUndefined()) {
            bun.csprng(bytes);
            return result;
        }

        const job = Job.create(global, result, bytes.ptr, 0, size, callback);
        job.schedule();
        return .undefined;
    }

    fn randomFillSync(global: *JSGlobalObject, callFrame: *JSC.CallFrame) JSError!JSValue {
        const buf_value, const offset_value, const size_value = callFrame.argumentsAsArray(3);

        const buf = buf_value.asArrayBuffer(global) orelse {
            return global.throwInvalidArgumentTypeValue("buf", "ArrayBuffer or ArrayBufferView", buf_value);
        };

        const element_size = buf.bytesPerElement() orelse 1;

        const offset = try assertOffset(
            global,
            if (offset_value.isUndefined()) JSC.jsNumber(0) else offset_value,
            element_size,
            buf.byte_len,
        );

        const size = if (size_value.isUndefined())
            buf.byte_len - offset
        else
            try assertSize(global, size_value, element_size, offset, buf.byte_len);

        if (size == 0) {
            return buf_value;
        }

        bun.csprng(buf.slice()[offset..][0..size]);

        return buf_value;
    }

    fn randomFill(global: *JSGlobalObject, callFrame: *JSC.CallFrame) JSError!JSValue {
        const buf_value, var offset_value, var size_value, var callback =
            callFrame.argumentsAsArray(4);

        const buf = buf_value.asArrayBuffer(global) orelse {
            return global.throwInvalidArgumentTypeValue("buf", "ArrayBuffer or ArrayBufferView", buf_value);
        };

        const element_size = buf.bytesPerElement() orelse 1;

        var offset: u32 = 0;
        if (offset_value.isCallable()) {
            callback = offset_value;
            offset = try assertOffset(global, JSValue.jsNumber(0), element_size, buf.byte_len);
            size_value = JSValue.jsNumber(buf.len);
        } else if (size_value.isCallable()) {
            callback = size_value;
            offset = try assertOffset(global, offset_value, element_size, buf.byte_len);
            size_value = JSValue.jsNumber(buf.len - offset);
        } else {
            _ = try validators.validateFunction(global, "callback", callback);
            offset = try assertOffset(global, offset_value, element_size, buf.byte_len);
        }

        const size = if (size_value.isUndefined())
            buf.byte_len - offset
        else
            try assertSize(global, size_value, element_size, offset, buf.byte_len);

        if (size == 0) {
            _ = try callback.call(global, .undefined, &.{ .null, JSValue.jsNumber(0) });
            return .undefined;
        }

        const job = Job.create(global, buf_value, buf.slice().ptr, offset, size, callback);
        job.schedule();
        return .undefined;
    }
};

fn pbkdf2(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSC.JSValue {
    const arguments = callframe.arguments_old(6);

    const data = try PBKDF2.fromJS(globalThis, arguments.slice(), true);

    const job = PBKDF2.Job.create(JSC.VirtualMachine.get(), globalThis, &data);
    return job.promise.value();
}

fn pbkdf2Sync(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSC.JSValue {
    const arguments = callframe.arguments_old(5);

    var data = try PBKDF2.fromJS(globalThis, arguments.slice(), false);
    defer data.deinit();
    var out_arraybuffer = JSC.JSValue.createBufferFromLength(globalThis, @intCast(data.length));
    if (out_arraybuffer == .zero or globalThis.hasException()) {
        data.deinit();
        return .zero;
    }

    const output = out_arraybuffer.asArrayBuffer(globalThis) orelse {
        data.deinit();
        return globalThis.throwOutOfMemory();
    };

    if (!data.run(output.slice())) {
        const err = Crypto.createCryptoError(globalThis, BoringSSL.ERR_get_error());
        BoringSSL.ERR_clear_error();
        return globalThis.throwValue(err);
    }

    return out_arraybuffer;
}

pub fn timingSafeEqual(global: *JSGlobalObject, callFrame: *JSC.CallFrame) JSError!JSValue {
    const l_value, const r_value = callFrame.argumentsAsArray(2);

    const l_buf = l_value.asArrayBuffer(global) orelse {
        return global.ERR_INVALID_ARG_TYPE("The \"buf1\" argument must be an instance of ArrayBuffer, Buffer, TypedArray, or DataView.", .{}).throw();
    };
    const l = l_buf.byteSlice();

    const r_buf = r_value.asArrayBuffer(global) orelse {
        return global.ERR_INVALID_ARG_TYPE("The \"buf2\" argument must be an instance of ArrayBuffer, Buffer, TypedArray, or DataView.", .{}).throw();
    };
    const r = r_buf.byteSlice();

    if (l.len != r.len) {
        return global.ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH("Input buffers must have the same byte length", .{}).throw();
    }

    return JSC.jsBoolean(BoringSSL.CRYPTO_memcmp(l.ptr, r.ptr, l.len) == 0);
}

pub fn createNodeCryptoBindingZig(global: *JSC.JSGlobalObject) JSC.JSValue {
    const crypto = JSC.JSValue.createEmptyObject(global, 8);

    crypto.put(global, String.init("pbkdf2"), JSC.JSFunction.create(global, "pbkdf2", pbkdf2, 5, .{}));
    crypto.put(global, String.init("pbkdf2Sync"), JSC.JSFunction.create(global, "pbkdf2Sync", pbkdf2Sync, 5, .{}));
    crypto.put(global, String.init("randomInt"), JSC.JSFunction.create(global, "randomInt", random.randomInt, 2, .{}));
    crypto.put(global, String.init("randomFill"), JSC.JSFunction.create(global, "randomFill", random.randomFill, 4, .{}));
    crypto.put(global, String.init("randomFillSync"), JSC.JSFunction.create(global, "randomFillSync", random.randomFillSync, 3, .{}));
    crypto.put(global, String.init("randomUUID"), JSC.JSFunction.create(global, "randomUUID", random.randomUUID, 1, .{}));
    crypto.put(global, String.init("randomBytes"), JSC.JSFunction.create(global, "randomBytes", random.randomBytes, 2, .{}));
    crypto.put(global, String.init("timingSafeEqual"), JSC.JSFunction.create(global, "timingSafeEqual", timingSafeEqual, 2, .{}));

    return crypto;
}
