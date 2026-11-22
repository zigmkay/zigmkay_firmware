//! Unified test root for zigmkay core tests so `zig build test` compiles and
//! links one binary instead of ~30 separate binaries.
//! `build_utils.add_test_steps` verifies every `test_*.zig` file in this
//! directory is referenced here.
test {
    _ = @import("test_companion.zig");
    _ = @import("test_compile_all.zig");
    _ = @import("test_core.zig");
    _ = @import("test_generic_queue.zig");
    _ = @import("test_output_command_queue.zig");
    _ = @import("test_processing_autofire.zig");
    _ = @import("test_processing_basics_hold_only.zig");
    _ = @import("test_processing_basics_multitap_same_keycode.zig");
    _ = @import("test_processing_basics_tap_only.zig");
    _ = @import("test_processing_basics_trans_none.zig");
    _ = @import("test_processing_boot_key.zig");
    _ = @import("test_processing_combos_single.zig");
    _ = @import("test_processing_custom_functions.zig");
    _ = @import("test_processing_dead_keys.zig");
    _ = @import("test_processing_encoders.zig");
    _ = @import("test_processing_helpers.zig");
    _ = @import("test_processing_known_bugs.zig");
    _ = @import("test_processing_matrix_event_trace.zig");
    _ = @import("test_processing_mediakeys.zig");
    _ = @import("test_processing_mouse_actions.zig");
    _ = @import("test_processing_one_shot.zig");
    _ = @import("test_processing_one_shot_and_retrotapping.zig");
    _ = @import("test_processing_permissive_hold.zig");
    _ = @import("test_processing_permissive_hold_and_combos.zig");
    _ = @import("test_processing_retrotapping.zig");
    _ = @import("test_processing_rolling_keys.zig");
    _ = @import("test_processing_sides.zig");
    _ = @import("test_processing_struct_sizes.zig");
    _ = @import("test_processing_tap_hold.all_cases.zig");
    _ = @import("test_processing_tap_hold.zig");
    _ = @import("test_split_protocol_send_receive_message.zig");
    _ = @import("test_split_protocol_serialization.zig");
}
