//! The Flash request of the editor toolbar.
const desktop = @import("desktop-core");

/// Routes toolbar clicks and offline state-machine tests through the same
/// captured editor request. This only authorizes an intent; it never starts a
/// build, discovers a device or transfers firmware.
pub fn dispatch(owner: *desktop.editor_dispatch.State, model: *desktop.model.Model) !desktop.editor_dispatch.Effect {
    return owner.request(model, try desktop.editor_dispatch.Request.capture(model, .flash));
}

pub fn accept(model: *const desktop.model.Model, captured: desktop.editor_dispatch.Request) !void {
    if (captured.intent != .flash) return error.NotFlashRequest;
    try captured.validate(model);
}
