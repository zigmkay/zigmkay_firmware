//! UI-thread correlation around the process-lifetime native chooser slot.
const std = @import("std");
pub const Target = enum { project, export_directory, callback_source, onboarding_source, onboarding_location, onboarding_open };
pub const Ticket = struct { generation: u64, owner: u64, snapshot: [32]u8, target: Target };
pub const State = struct {
    generation: u64 = 0,
    pending: ?Ticket = null,
    pub fn begin(self: *State, owner: u64, snapshot: [32]u8, target: Target) !Ticket {
        if (self.pending != null) return error.DialogAlreadyOpen;
        if (self.generation == std.math.maxInt(u64)) return error.DialogGenerationExhausted;
        self.generation += 1;
        const ticket = Ticket{ .generation = self.generation, .owner = owner, .snapshot = snapshot, .target = target };
        self.pending = ticket;
        return ticket;
    }
    /// Discards delivery without claiming to close the OS dialog.
    pub fn discard(self: *State, ticket: Ticket) bool {
        if (self.pending) |pending| if (std.meta.eql(ticket, pending)) {
            self.pending = null;
            return true;
        };
        return false;
    }
    /// A late old callback must not consume the newer pending request.
    pub fn accept(self: *State, ticket: Ticket, owner: u64, snapshot: [32]u8) bool {
        const pending = self.pending orelse return false;
        if (!std.meta.eql(ticket, pending)) return false;
        self.pending = null;
        return ticket.owner == owner and std.mem.eql(u8, &ticket.snapshot, &snapshot);
    }
};
