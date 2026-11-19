// =============================================================================
// ZIGMKAY MOLEKULA KEYMAP
// =============================================================================
// This file defines the complete keyboard layout for the Molekula unibody split.
//
// MAIN CUSTOMIZATION AREAS:
//   1. Key definitions - change what each key sends (T, H_, B_, AF, etc.)
//   2. Layer contents - modify which keys appear on each layer
//   3. Combo definitions - create key combinations for special actions
//   4. Custom event handling - add logic for advanced features
//
// QUICK EXAMPLES:
//
//   Change a key's output:
//     BEFORE: T(us.Q)      // This position outputs 'Q'
//     AFTER:  T(us.A)      // Now outputs 'A'
//
//   Make a home-row mod (tap = letter, hold = modifier):
//     BEFORE: T(us.A)      // Plain 'A'
//     AFTER:  H_.S(us.A)   // Tap = 'A', Hold = Left Shift
//
//   Create a layer-tap key (tap = space, hold = activate layer):
//     B_.LT(L_NUM, kc.SPC)  // Tap Space, Hold activates NUM layer
//
// =============================================================================

const std = @import("std");

const zigmkay = @import("zigmkay");

// Re-export zigmkay's core module for convenience in this file
pub const core = zigmkay.core;

// _______ (seven underscores) is the "transparent" key - null means pass through to the
// next active layer instead of defining its own action. This is useful for
// making some keys in a layer "fall through" to the base layer while defining
// custom actions for other keys.
const _______: ?core.KeyDef = null;

const zkeycodes = @import("zkeycodes");
// kc = "keycodes basic" - OS-agnostic keycodes that work the same on all systems
// These are basic HID scancodes without any operating system-specific mapping.
// Use these for keys that should behave identically regardless of OS (e.g., ESC, arrows)
const kc = zkeycodes.layouts.keycodes.kcf;

// us = "US international" - OS-specific keycodes for US keyboard layout
// These produce characters based on the US international layout:
//   - Letters (A-Z) work normally
//   - Brackets and punctuation vary by OS layout
//   - Dead keys (like ~, `, ') are used to combine with letters
//
// NOTE: If you use a different OS keyboard layout (German, French, etc.), you
// need to use a different keycodes import like keycodes.german.
const us = @import("zkeycodes").layouts.us_international;

// =============================================================================
// MACRO SHORTCUTS
// =============================================================================
// These shortcuts make the keymap more readable. Each macro creates a specific
// type of key behavior. Understanding these is essential for customization.

const macros = zigmkay.macros;

// tapping_term: How long you must hold a key before it registers as a "hold"
// instead of a "tap". At 200ms, you have 200ms to release a key before the
// firmware decides you're holding it.
//
// ADJUST THIS: Lower values (e.g., 150ms) = more responsive but may cause
// accidental layer activations. Higher values (e.g., 300ms) = more deliberate
// but slower for quick taps.
const tapping_term: core.TimeSpan = .{ .ms = 200 };

// H_ = "Home-row mods" configuration
// Home-row mods are dual-function keys where you tap for a letter but hold for
// a modifier (Ctrl, Alt, Shift, GUI). This is a popular ergonomic technique
// that keeps your fingers on the home row for modifiers.
//
// AVAILABLE METHODS:
//   H_.G(key) - Tap = key, Hold = Left GUI (Windows key)
//   H_.C(key) - Tap = key, Hold = Left Control
//   H_.A(key) - Tap = key, Hold = Left Alt
//   H_.S(key) - Tap = key, Hold = Left Shift
//
// EXAMPLE: H_.S(us.A) on the 'A' position means:
//   - Tap quickly = sends 'A'
//   - Hold = Left Shift (useful for capital letters or shortcuts)
const H_ = macros.OptionsHomeRowMods{ .tapping_term = tapping_term };

// B_ = "Basic tap-hold" configuration
// A more general tap-hold macro for creating layer-tap or key-tap keys.
//
// AVAILABLE METHODS:
//   B_.LT(layer, key) - Layer-Tap: Tap = key, Hold = activate 'layer'
//   B_.GT(key_fire, key_hold) - GUI-Tap: Tap = key_fire, Hold = GUI + key_hold
const B_ = macros.OptionsBasicKeydef{ .tapping_term = tapping_term };

// kcm = "KeyCode Modifier" - Helper for adding modifiers to keycodes
// Use this to create keycodes with explicit modifiers attached.
//
// EXAMPLE: kcm.L_ALT(kc.F4) creates an Alt+F4 keycode
const kcm = zkeycodes.core; //TODO: wow this is ugly. remove later when L_ALT is obsolete trough fn on kcf

// T = "Tap" - Creates a simple tap-only key that sends a keycode when pressed.
// This is the most basic key type - just sends the keycode on press.
//
// EXAMPLE: T(us.Q) creates a key that sends 'Q' when tapped
const T = macros.T;

// AF = "AutoFire" - Creates a key that repeatedly fires while held
// Unlike a hold action, autofire rapidly sends tap events at a fixed rate.
// This is great for arrow keys - tap once = move once, hold = continuously move.
//
// SETTINGS:
//   - initial_delay: Time before autofire starts (150ms default)
//   - repeat_interval: Time between repeated events (50ms default)
//
// EXAMPLE: AF(kc.LEFT) on an arrow key means holding it will continuously send LEFT
const AF = macros.AF;

// MED = "Media" - Creates a media key for volume, playback, etc.
// These send HID Consumer Control reports instead of keyboard codes.
//
// COMMON USAGES:
//   MED(core.MEDIA_VOLUME_UP)   - Volume up
//   MED(core.MEDIA_VOLUME_DOWN) - Volume down
//   MED(core.MEDIA_PLAY_PAUSE)  - Play/Pause toggle
//   MED(core.MEDIA_MUTE)        - Mute/unmute
const MED = macros.MED;

// MO = "MOmentary" layer switch - Activates a layer only while the key is held
// Unlike LT (layer-tap), this has no tap functionality - it's purely a layer toggle.
//
// EXAMPLE: MO(L_NUM) on a thumb key means the NUM layer is active only while held
const MO = macros.MO;

// MS = "Mouse" - Creates a key that sends mouse actions (clicks, wheel movements)
//
// AVAILABLE ACTIONS:
//   MS(.LeftClick)   - Left mouse button click
//   MS(.RightClick)  - Right mouse button click
//   MS(.WheelUp)     - Scroll wheel up
//   MS(.WheelDown)   - Scroll wheel down
//   MS(.MoveLeft), MS(.MoveRight), MS(.MoveUp), MS(.MoveDown) - Mouse movement
//
// EXAMPLE: MS(.WheelDown) creates a key that scrolls down when tapped
const MS = macros.MS;

// SIG = "SIGnal" - Sends a custom signal to the companion app
// These don't send keycodes to your computer - they communicate with the
// zigmkay-companion desktop overlay application.
//
// RESERVED SIGNALS (built into zigmkay):
//   COM_TOG = core.CUSTOM_ID_COMPANION_TOGGLE (0xFF) - Show/hide companion overlay
//   COM_OFF = core.CUSTOM_ID_COMPANION_SHUTDOWN (0xFE) - Hide companion overlay
//   COM_LOG = core.CUSTOM_ID_COMPANION_LOG_TOGGLE (0xFD) - Toggle key event logging
//
// You can also define custom signals (see CUSTOM USER-DEFINED IDS section below)
const SIG = macros.SIG;

// =============================================================================
// COMPANION SIGNAL CONSTANTS
// =============================================================================
// These constants define the signals sent to the companion app overlay.
// The companion app receives these via Raw HID and can display them visually.
//
// USAGE: Place SIG(COM_TOG) on a key to make it toggle the companion overlay.

/// Toggles the companion overlay visibility (show/hide)
pub const COM_TOG = core.CUSTOM_ID_COMPANION_TOGGLE; // 0xFF

/// Closes/shuts down the companion overlay
pub const COM_OFF = core.CUSTOM_ID_COMPANION_SHUTDOWN; // 0xFE

/// Toggles the key event logging display in the companion
pub const COM_LOG = core.CUSTOM_ID_COMPANION_LOG_TOGGLE; // 0xFD

// =============================================================================
// LAYER INDEX DEFINITIONS
// =============================================================================
// Each layer is a complete keyboard layout that can be activated conditionally.
// Layers are numbered starting from 0 (L_BASE is always index 0).
//
// HOW LAYERS WORK:
//   - Only one layer is the "base" (index 0 = L_BASE) - always active
//   - Other layers are activated by: hold keys (MO, LT), combos, or custom logic
//   - When a key is pressed, firmware checks layers top-to-bottom
//   - The FIRST layer (highest priority) that has a non-transparent definition wins
//   - If all layers have transparent (_______) for a position, nothing happens
//
// LAYER PRIORITY (highest to lowest):
//   L_GAMING > L_BOTH > L_ARROWS > L_NUM > L_BASE
//
// TO ADD A NEW LAYER:
//   1. Add a new constant: const L_MYLAYER: usize = 5;
//   2. Add a new array entry in the keymap below with key_count elements
//   3. Update the dimensions constant at the bottom

// =============================================================================
// KEY COUNT
// =============================================================================
// Total number of keys in the keyboard.
// This must match:
//   - The length of the 'sides' array
//   - The length of each layer in the 'keymap' array
//   - The 'pin_mappings' array in main.zig
//
// CUSTOMIZATION: Change this if you add or remove keys from your keyboard.
// You would also need to update main.zig pin_mappings accordingly.
pub const key_count = 38;

/// Base layer index - QWERTY main layout (always active)
const L_BASE: usize = 0;

/// Arrows layer index - Navigation cluster and special characters
const L_ARROWS: usize = 1;

/// Numbers layer index - Numpad-style input with symbols
const L_NUM: usize = 2;

/// Both layer index - Function keys F1-F12
const L_BOTH: usize = 3;

/// Gaming layer index - Simplified layout for gaming mode
const L_GAMING: usize = 4;

// =============================================================================
// LAYER ALIASES
// =============================================================================
// These are convenience aliases for which layer each thumb key activates.
// LT(L_LEFT, key) on a left thumb key activates L_NUM when held.
// LT(L_RIGHT, key) on a right thumb key activates L_ARROWS when held.
//
// CUSTOMIZATION: Change these to map thumb keys to different layers

/// Left thumb key activates the NUM layer by default
const L_LEFT = L_NUM;

/// Right thumb key activates the ARROWS layer by default
const L_RIGHT = L_ARROWS;

// =============================================================================
// CUSTOM USER-DEFINED IDS
// =============================================================================
// These are custom signal IDs for user-defined functionality.
// When a SIG() key uses one of these IDs, it triggers custom logic in on_event().
//
// RULES FOR CUSTOM IDS:
//   - Valid range: 1 to 252 (0x01 to 0xFC)
//   - Values 0xFD-0xFF are RESERVED by zigmkay (COM_LOG, COM_OFF, COM_TOG)
//   - Each ID should have a unique purpose
//
// CUSTOMIZATION: Define your own custom IDs for any purpose, then handle them
// in the on_event() function at the bottom of this file.

/// Custom signal ID to enable gaming layer
pub const ENABLE_GAMING = 1;

/// Custom signal ID to disable gaming layer
pub const DISABLE_GAMING = 2;

// =============================================================================
// SIDES ARRAY
// =============================================================================
// This array maps each key index (0-39) to its PHYSICAL POSITION on the keyboard.
// This tells the firmware which half of the split keyboard each key belongs to.
//
// VALUES:
//   .L  = Left half
//   .R  = Right half
//   .TL = Top-left thumb cluster
//   .TR = Top-right thumb cluster
//   .E  = Encoder
//
// WHY THIS MATTERS:
//   - Split keyboards need to know which keys are on which side
//   - The Raw HID protocol sends key events with side information
//   - The companion app uses this to highlight the correct half
//
// CUSTOMIZATION:
//   - You generally DON'T need to change this for the Molekula
//   - Only change if you're adapting this for a different keyboard layout
//   - The order MUST match your physical keyboard's wiring (see main.zig)
// zig fmt: off
pub const sides = [key_count]core.Side{
    .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
 .L,.L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,.R,
    .L,.L,.L,.L,.L,       .R,.R,.R,.R,.R,
            .X,.X,.X,   .X,.X,.X,
                    // .E,.E TODO Encoders not supported right now
};
// zig fmt: on

// =============================================================================
// KEYMAP ARRAY
// =============================================================================
// The core keymap definition - a 2D array where:
//   - First dimension = layer index (0 = base, 1 = arrows, etc.)
//   - Second dimension = key position (0-39, must equal key_count)
//
// HOW TO READ THE KEYMAP:
//   keymap[LAYER_INDEX][KEY_POSITION]
//
// Each entry is a KeyDef created by one of the macros (T, H_, B_, AF, etc.)
//
// COMMON KEYDEF PATTERNS:
//
//   T(kc.XXX)      - Simple key, sends XXX
//   T(us.XXX)      - Simple key with US layout, sends XXX
//   H_.X(us.Y)     - Home-row mod: tap = Y, hold = modifier X
//   B_.LT(layer, kc.XXX) - Layer-tap: tap = XXX, hold = activate 'layer'
//   AF(kc.XXX)     - Autofire: hold = repeatedly send XXX
//   MO(layer)      - Momentary: hold = activate 'layer'
//   MED(code)      - Media key: controls volume/playback
//   MS(.action)    - Mouse action: click/wheel/move
//   SIG(id)        - Signal to companion app
//   _______        - Transparent: pass through to next active layer
//
// KEYCODE SOURCES:
//   kc.XXX - Basic HID codes (ESC, F1-F12, arrows, etc.) - OS neutral
//   us.XXX - US international layout codes (Q, W, E, brackets, etc.)
//   core.MEDIA_XXX - Media key constants (VOLUME_UP, PLAY_PAUSE, etc.)
//
// CUSTOMIZATION EXAMPLES:
//
//   Change a letter:
//     T(us.Q) -> T(us.A)  // Change Q to A
//
//   Add a modifier to a key:
//     T(us.A) -> H_.C(us.A)  // Tap A, Hold Ctrl+A
//
//   Make a layer switch key:
//     T(kc.SPC) -> B_.LT(L_NUM, kc.SPC)  // Tap Space, Hold activate NUM
//
//   Disable a key (make it do nothing):
//     T(us.Q) -> _______  // Pass through to layer below (or nothing)
//

// zig fmt: off
pub const keymap = [_][key_count]?core.KeyDef{
    // =============================================================================
    // LAYER 0: L_BASE - Main QWERTY Layer
    // =============================================================================
    // This is your primary typing layer - the standard QWERTY layout.
    // It uses home-row mods (H_) on ASDF and JKL; keys for comfortable modifier access.
    //
    // ACTIVATION: Always active (base layer, index 0)
    //
    // SPECIAL KEYS ON THIS LAYER:
    //   - Index 34: COM_TOG (toggle companion overlay)
    //   - Index 35: LT(L_LEFT, SPC) - Left thumb: tap=Space, hold=NUM layer
    //   - Index 36: Enter (right thumb)
    //   - Index 37: Enter (right thumb, duplicate for symmetry)
    //   - Index 38: LT(L_RIGHT, SPC) - Right thumb: tap=Space, hold=ARROWS layer
    //   - Index 39: COM_TOG (toggle companion overlay)
    //   - Index 45,46: Media volume up/down (left side encoders)
    .{
                 T(us.Q),   T(us.W),   T(us.E),   T(us.R), T(us.T),                  T(us.Y),   T(us.U), T(us.I),     T(us.O),    T(us.P),
    T(kc.TAB), H_.S(us.A), H_.A(us.S), H_.G(us.D), H_.C(us.F), T(us.G),                  T(us.H), H_.C(us.J), H_.G(us.K), H_.A(us.L),  H_.S(us.SCLN),  T(us.ACUT),
                 T(us.Z),   T(us.X),   T(us.C),   T(us.V), T(us.B),                  T(us.N),   T(us.M), T(us.COMM),  T(us.DOT),  T(us.SLSH),
       SIG(COM_TOG), B_.LT(L_LEFT, kc.SPC), T(kc.ENT),                T(kc.ENT), B_.LT(L_RIGHT, kc.SPC), SIG(COM_TOG),
    // MED(core.MEDIA_VOLUME_UP), MED(core.MEDIA_VOLUME_DOWN)
    },
    // =============================================================================
    // LAYER 1: L_ARROWS - Navigation and Special Characters
    // =============================================================================
    // Provides arrow keys, page up/down, home/end, and special characters.
    // Useful for editing without moving your hands to the arrow cluster.
    //
    // ACTIVATION: Hold L_LEFT thumb key (NUM layer) or L_RIGHT thumb key (ARROWS)
    //
    // SPECIAL KEYS ON THIS LAYER:
    //   - Index 34: COM_TOG
    //   - Index 35: LT(L_BOTH, SPC) - hold activates BOTH (function keys)
    //   - Encoder: WheelDown/WheelUp (mouse action on encoder)
    .{
                  T(us.LBRC), T(us.RBRC), T(us.LCBR), T(us.RCBR), T(us.HASH),           T(us.AT),    T(kc.HOME),  AF(kc.UP),    T(kc.END),   T(us.PLUS),
    SIG(COM_OFF), T(us.LABK), T(us.RABK), T(us.LPRN), T(us.RPRN), T(us.SLSH),           T(kc.PGUP), AF(kc.LEFT),  AF(kc.DOWN), AF(kc.RIGHT), T(kc.PGDN), _______,
                   _______,   T(us.DTIL), T(us.AMPR), T(us.ASTR), T(us.BSLS),           T(us.DLR),   T(us.SCLN),   T(us.DIAE),  T(us.ACUT),     _______,
              SIG(COM_TOG), B_.LT(L_BOTH, kc.SPC), T(kc.ENT),            T(kc.ENT),      _______, SIG(COM_TOG),
    // MS(.WheelDown), MS(.WheelUp)
    },
    // =============================================================================
    // LAYER 2: L_NUM - Numbers and Symbols
    // =============================================================================
    // Numpad-style input with numbers, basic editing keys, and the Euro symbol.
    // Designed for data entry and calculations.
    //
    // ACTIVATION: Hold L_LEFT thumb key (index 35 on BASE layer)
    //
    // SPECIAL KEYS ON THIS LAYER:
    //   - Encoder: Media volume controls
    .{
               T(kc.ESC), T(kc.PSCR), T(us.PERC),  T(us.DCIR), T(kc.GRV),             T(kc.MINUS), T(us.N7), T(us.N8), T(us.N9), T(us.PLUS),
    _______, AF(kc.BSPC), T(kc.UNDO), T(kc.AGAIN), T(kc.ENT),  T(kc.TAB),                T(us.UNDS),  T(us.N4), T(us.N5), T(us.N6), T(us.EQL),  MS(core.MouseAction.WheelUp),
                 _______, T(us.X),    T(us.C),     T(kc.DEL),  T(us.V),                  T(us.EURO),  T(us.N1), T(us.N2), T(us.N3),   MS(core.MouseAction.WheelDown),
                                    SIG(COM_TOG),    _______,  T(kc.ENT),                T(kc.ENT),  B_.LT(L_BOTH, us.N0), SIG(COM_TOG),
    // MED(core.MEDIA_VOLUME_UP), MED(core.MEDIA_VOLUME_DOWN)
    },
    // =============================================================================
    // LAYER 3: L_BOTH - Function Keys F1-F12
    // =============================================================================
    // Function key layer accessible from either thumb cluster.
    // Useful for IDE shortcuts, media controls, and application-specific hotkeys.
    //
    // ACTIVATION: Hold either thumb LT key while on NUM or ARROWS layer
    //
    // SPECIAL KEYS ON THIS LAYER:
    //   - Index 34: COM_TOG
    //   - Index 39: COM_TOG
    //   - Contains many transparent keys to pass through to underlying layer
    .{
                  T(kc.ESC),  T(kc.F7), T(kc.F8), T(kc.F9), T(kc.F10),              T(kc.GRV),  T(kc.SPC),  T(kc.SPC),  T(kc.SPC),  T(kc.TAB),
        _______, AF(kc.BSPC), T(kc.F4), T(kc.F5), T(kc.F6), T(kc.F11),              T(us.SS),   T(kc.BSPC), T(kc.BSPC), T(kc.BSPC), T(kc.ESC),  _______,
                    _______,  T(kc.F1), T(kc.F2), T(kc.F3), T(kc.F12),              T(us.DCIR), T(kc.DEL),  T(kc.DEL),  T(kc.DEL),  _______,
                                    SIG(COM_TOG),  _______, T(kc.ENT),              T(kc.ENT),  _______,    SIG(COM_TOG),
    // MED(core.MEDIA_VOLUME_UP), MED(core.MEDIA_VOLUME_DOWN)
    },
    // =============================================================================
    // LAYER 4: L_GAMING - Simplified Gaming Layout
    // =============================================================================
    // A simplified QWERTY layout optimized for gaming.
    // Disables home-row mods to prevent accidental modifier activation.
    // The layer is toggled ON/OFF via a combo (Q+W simultaneously).
    //
    // ACTIVATION: Toggled ON by combo (Q+W tap), toggled OFF by same combo on this layer
    //
    // DIFFERENCES FROM BASE:
    //   - Home-row mods replaced with plain tap keys (no accidental Ctrl/Alt)
    //   - Enter on right thumb instead of layer-tap
    //   - No COM_TOG keys (avoids accidentally toggling overlay during gaming)
    .{
               T(us.Q), T(us.W), T(us.E), T(us.R), T(us.T),            T(us.Y),   T(us.U),     T(us.I),    T(us.O),   T(us.P),
    T(kc.TAB), T(us.A), T(us.S), T(us.D), T(us.F), T(us.G),            T(us.H),   T(us.J),     T(us.K),    T(us.L),   T(us.SCLN), T(us.ACUT),
               T(us.Z), T(us.X), T(us.C), T(us.V), T(us.B),            T(us.N),   T(us.M),     T(us.COMM), T(us.DOT), T(us.SLSH),
                        SIG(COM_TOG), T(kc.SPC),   T(kc.ENT),          T(kc.ENT), T(kc.SPC), SIG(COM_TOG),
    // MED(core.MEDIA_VOLUME_UP), MED(core.MEDIA_VOLUME_DOWN)
    },
};
// zig fmt: on

// =============================================================================
// DIMENSIONS
// =============================================================================
// Tells the firmware how many keys and layers are in this keymap.
// This is used for memory allocation and validation.
//
// CUSTOMIZATION:
//   - Increase key_count if adding more keys (requires PCB modifications)
//   - Add more layers by adding entries to the keymap array above

pub const dimensions = core.KeymapDimensions{
    .key_count = key_count, // Total number of keys (40 for Molekula)
    .layer_count = keymap.len, // Number of layers (calculated from array length)
};

// PrintStats is a debug key that sends KC_PRINT_STATS (if supported by your OS)
// Currently commented out - uncomment to enable
// const PrintStats = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = us.KC_PRINT_STATS } } };

// =============================================================================
// COMBO DEFINITIONS
// =============================================================================
// Combos are key combinations that trigger when two or more keys are pressed
// simultaneously. Unlike regular key presses, combos are evaluated based on the
// TIMING of key presses (within a combo_timeout window).
//
// COMBO SYNTAX:
//   combo.Combo_Tap({.[key_index_1, key_index_2]}, layer, action)
//     - Triggers when exactly the specified keys are pressed within combo_timeout
//     - Sends 'action' (a keycode or keycode with modifiers)
//
//   combo.Combo_Custom({.[key_index_1, key_index_2]}, layer, custom_id)
//     - Triggers a custom signal ID instead of a keycode
//     - The ID is handled in on_event() function below
//
// HOW COMBOS WORK:
//   1. When keys are pressed, firmware checks if they form a defined combo
//   2. If within combo_timeout window, the combo action takes priority
//   3. Combos on higher-priority layers are checked first
//
// CUSTOMIZATION EXAMPLES:
//
//   Create a Ctrl+C combo:
//     combo.Combo_Tap(.{ 12, 13 }, L_BASE, kcm.L_CTL(kc.C))
//     (Indices 12 and 13 on BASE layer = S and D in standard layout)
//
//   Create a layer-switching combo:
//     combo.Combo_Custom(.{ 0, 4 }, L_BASE, MY_CUSTOM_ID)
//     Then handle MY_CUSTOM_ID in on_event()
//
//   Disable a combo: Comment it out or delete it from the array

const combo = zigmkay.combo.Options{
    // combo_timeout: Maximum time between first and last key press for a combo
    // If keys are pressed within this window, combo triggers
    // If timeout is exceeded, keys are processed individually
    .combo_timeout = .{ .ms = 50 },

    // tapping_term: How long each key must be held for the combo to register
    // Shorter values = faster combo detection but may cause false positives
    .tapping_term = .{ .ms = 200 },
};

pub const combos = [_]core.Combo2Def{
    // -----------------------------------------------------------------------------
    // COMBO: Alt+F4 (Window close)
    // -----------------------------------------------------------------------------
    // Triggers when keys at indices 14 and 17 are pressed together on L_BOTH
    // Holding down both thumb layer keys and tapping the index finger home row keys.
    // Tapping this combo sends Alt+F4 to close the active window
    combo.Combo_Tap(.{ 14, 17 }, L_BOTH, kcm.L_ALT(kc.F4)),

    // -----------------------------------------------------------------------------
    // COMBO: Bootloader mode (Firmware reset)
    // -----------------------------------------------------------------------------
    // Pressing Q+T (indices 0 and 4) on BASE layer triggers bootloader mode
    // This causes the RP2040 to reset into bootloader mode (for firmware update)
    // Useful for entering flash mode without manually pressing the BOOTSEL button
    combo.Combo_Tap(.{ 0, 4 }, L_BASE, core.KC_BOOT),

    // Same combo mirrored on right half: Y+P (indices 5 and 9)
    combo.Combo_Tap(.{ 5, 9 }, L_BASE, core.KC_BOOT),

    // -----------------------------------------------------------------------------
    // COMBO: Gaming mode toggle
    // -----------------------------------------------------------------------------
    // These custom combos enable/disable the gaming layer.
    // The actual toggle logic is handled in on_event() below.
    //
    // HOW IT WORKS:
    //   - Pressing Q+P (indices 0 and 9, outer home row keys) on BASE triggers ENABLE_GAMING
    //   - Pressing Q+P on GAMING layer triggers DISABLE_GAMING
    //   - The on_event() function handles the actual layer activation

    // Enable gaming: Q+P on BASE layer
    combo.Combo_Custom(.{ 0, 9 }, L_BASE, ENABLE_GAMING),

    // Disable gaming: Q+P on GAMING layer
    combo.Combo_Custom(.{ 0, 9 }, L_GAMING, DISABLE_GAMING),

    // -----------------------------------------------------------------------------
    // COMBO: Toggle companion log
    // -----------------------------------------------------------------------------
    // Pressing outer most thumb buttons on BASE toggles the key event log display
    // This shows all key events in the companion overlay for debugging
    combo.Combo_Custom(.{ 32, 37 }, L_BASE, COM_LOG),
};

// =============================================================================
// CUSTOM EVENT HANDLER
// =============================================================================
// This function is called by the firmware when specific events occur.
// It's the hook point for custom logic that goes beyond simple key/hold definitions.
//
// EVENT TYPES:
//   OnTapEnterBefore  - Fired when a tap is decided, BEFORE the tap is sent
//   OnTapEnterAfter   - Fired when a tap is decided, AFTER the tap is sent
//   OnTapExitBefore   - Fired when a tap is released, BEFORE the release is sent
//   OnTapExitAfter    - Fired when a tap is released, AFTER the release is sent
//   OnHoldEnterBefore - Fired when a hold is decided, BEFORE hold actions execute
//   OnHoldEnterAfter  - Fired when a hold is decided, AFTER hold actions execute
//   OnHoldExitBefore  - Fired when a hold is released, BEFORE release actions
//   OnHoldExitAfter   - Fired when a hold is released, AFTER release actions
//   Tick              - Fired every loop iteration (for time-based logic)
//
// AUTOMATICALLY HANDLED BY ZIGMKAY (no code needed here):
//   - Key event telemetry via Raw HID (companion communication)
//   - Companion overlay signals (COM_TOG, COM_OFF, COM_LOG)
//   - Dead key space-completion (e.g., pressing Space after a dead key)
//   - HoldDef.custom keycode taps on hold enter and exit
//
// CUSTOMIZATION: Add your own event handling for custom IDs or special behaviors.
//
// EXAMPLE: This handler processes the gaming layer toggle combos (ENABLE_GAMING/DISABLE_GAMING).
//
//     When the Q+P combo is detected on BASE layer, it activates the gaming layer.
//     When the Q+P combo is detected on GAMING layer, it deactivates the gaming layer.
fn on_event(event: core.ProcessorEvent, layers: *core.LayerActivations, output_queue: *core.OutputCommandQueue) void {
    _ = output_queue;
    switch (event) {
        // OnTapEnterBefore: Fires when a SIG() key with a custom ID is tapped
        // This is where custom signal handling happens
        .OnTapEnterBefore => |data| {
            // Check if the tapped key has our "enable gaming" custom ID
            if (data.tap.custom == ENABLE_GAMING) {
                // Activate the GAMING layer
                layers.set_layer_state(L_GAMING, true);
            }
            // Check if the tapped key has our "disable gaming" custom ID
            if (data.tap.custom == DISABLE_GAMING) {
                // Deactivate the GAMING layer
                layers.set_layer_state(L_GAMING, false);
            }
        },
        // All other events are ignored in this example but you can add your own event handleing logic here
        else => {},
    }
}

/// Container for custom function handlers passed to the firmware.
///
/// The firmware will call on_event() whenever a custom signal is triggered.
pub const custom_functions = core.CustomFunctions{
    .on_event = on_event,
};
