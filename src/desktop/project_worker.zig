//! Frozen file request specialization of the joined owned worker.
const files = @import("project_files.zig");
const workers = @import("owned_worker.zig");
pub const Ticket = workers.Ticket;
pub const Owner = workers.Owner(files.Request, files.Prepared, error.InvalidProjectGeneration);
pub const Event = Owner.Event;
