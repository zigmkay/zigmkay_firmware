//! AppKit menu bar item with an NSImage template. All calls are on the UI thread.
const std = @import("std");
const ztray = @import("ztray");

const Object = *anyopaque;
const Selector = *const anyopaque;
const Size = extern struct { width: f64, height: f64 };

extern "c" fn objc_getClass([*:0]const u8) ?Object;
extern "c" fn objc_allocateClassPair(Object, [*:0]const u8, usize) ?Object;
extern "c" fn objc_registerClassPair(Object) void;
extern "c" fn objc_disposeClassPair(Object) void;
extern "c" fn class_addMethod(Object, Selector, *const anyopaque, [*:0]const u8) bool;
extern "c" fn sel_registerName([*:0]const u8) Selector;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_autoreleasePoolPush() Object;
extern "c" fn objc_autoreleasePoolPop(Object) void;

var status_item: ?Object = null;
var menu_target: ?Object = null;
var pending_action: ?i32 = null;

fn send(comptime Signature: type, object: Object, name: [*:0]const u8, args: anytype) @typeInfo(Signature).@"fn".return_type.? {
    const method: *const Signature = @ptrCast(&objc_msgSend);
    return @call(.auto, method, .{ object, sel_registerName(name) } ++ args);
}

fn get(object: Object, name: [*:0]const u8) ?Object {
    return send(fn (Object, Selector) callconv(.c) ?Object, object, name, .{});
}

fn notify(object: Object, name: [*:0]const u8) void {
    send(fn (Object, Selector) callconv(.c) void, object, name, .{});
}

fn set(object: Object, name: [*:0]const u8, value: ?Object) void {
    send(fn (Object, Selector, ?Object) callconv(.c) void, object, name, .{value});
}

fn string(bytes: [*:0]const u8) ?Object {
    return send(fn (Object, Selector, [*:0]const u8) callconv(.c) ?Object, objc_getClass("NSString").?, "stringWithUTF8String:", .{bytes});
}

fn systemStatusBar() ?Object {
    return get(objc_getClass("NSStatusBar").?, "systemStatusBar");
}

fn performAction(_: Object, _: Selector, sender: Object) callconv(.c) void {
    const tag = send(fn (Object, Selector) callconv(.c) isize, sender, "tag", .{});
    pending_action = std.math.cast(i32, tag);
}

fn actionTarget() ?Object {
    const name = "ZigmkayTrayMenuTarget";
    const class = objc_getClass(name) orelse blk: {
        const new = objc_allocateClassPair(objc_getClass("NSObject").?, name, 0) orelse return null;
        if (!class_addMethod(new, sel_registerName("performTrayAction:"), @ptrCast(&performAction), "v@:@")) {
            objc_disposeClassPair(new);
            return null;
        }
        objc_registerClassPair(new);
        break :blk new;
    };
    return get(class, "new");
}

pub fn install(png: []const u8) !void {
    if (status_item != null) return error.TrayAlreadyInstalled;
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);

    const bar = systemStatusBar() orelse return error.TrayInstallFailed;
    const item = send(fn (Object, Selector, f64) callconv(.c) ?Object, bar, "statusItemWithLength:", .{@as(f64, -2)}) orelse return error.TrayInstallFailed; // NSSquareStatusItemLength
    errdefer set(bar, "removeStatusItem:", item);
    const button = get(item, "button") orelse return error.TrayInstallFailed;
    const data = send(fn (Object, Selector, [*]const u8, usize) callconv(.c) ?Object, objc_getClass("NSData").?, "dataWithBytes:length:", .{ png.ptr, png.len }) orelse return error.TrayInstallFailed;
    const allocated = get(objc_getClass("NSImage").?, "alloc") orelse return error.TrayInstallFailed;
    const image = send(fn (Object, Selector, Object) callconv(.c) ?Object, allocated, "initWithData:", .{data}) orelse return error.TrayInstallFailed;
    defer notify(image, "release");
    send(fn (Object, Selector, Size) callconv(.c) void, image, "setSize:", .{Size{ .width = 18, .height = 18 }});
    send(fn (Object, Selector, bool) callconv(.c) void, image, "setTemplate:", .{true});
    set(button, "setImage:", image);
    set(button, "setToolTip:", string("Zigmkay is running"));
    menu_target = actionTarget() orelse return error.TrayInstallFailed;
    status_item = get(item, "retain").?;
}

pub fn setMenu(allocator: std.mem.Allocator, items: []const ztray.Item) !void {
    const status = status_item orelse return error.MenuInstallFailed;
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const menu_class = objc_getClass("NSMenu").?;
    const item_class = objc_getClass("NSMenuItem").?;
    const menu = get(menu_class, "new") orelse return error.MenuInstallFailed;
    defer notify(menu, "release");
    send(fn (Object, Selector, bool) callconv(.c) void, menu, "setAutoenablesItems:", .{false});
    for (items) |entry| switch (entry) {
        .separator => set(menu, "addItem:", get(item_class, "separatorItem") orelse return error.MenuInstallFailed),
        .action => |action| {
            const title_z = try allocator.dupeSentinel(u8, action.title, 0);
            defer allocator.free(title_z);
            const title = string(title_z) orelse return error.MenuInstallFailed;
            const key = string("") orelse return error.MenuInstallFailed;
            const command = sel_registerName("performTrayAction:");
            const item = send(fn (Object, Selector, Object, Selector, Object) callconv(.c) ?Object, menu, "addItemWithTitle:action:keyEquivalent:", .{ title, command, key }) orelse return error.MenuInstallFailed;
            set(item, "setTarget:", menu_target);
            send(fn (Object, Selector, isize) callconv(.c) void, item, "setTag:", .{@as(isize, action.action_id)});
            send(fn (Object, Selector, bool) callconv(.c) void, item, "setEnabled:", .{action.enabled});
        },
    };
    set(status, "setMenu:", menu);
}

pub fn poll() ?i32 {
    const action = pending_action;
    pending_action = null;
    return action;
}

pub fn shutdown() void {
    const item = status_item orelse return;
    set(item, "setMenu:", null);
    if (systemStatusBar()) |bar| set(bar, "removeStatusItem:", item);
    notify(item, "release");
    if (menu_target) |target| notify(target, "release");
    status_item = null;
    menu_target = null;
    pending_action = null;
}
