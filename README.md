# Welcome
ZigMkay is a keyboard firmware made in zig. You also configure your own keymaps in zig. 

## Getting started
1. Install zig on your machine. Ensure you can run "zig version" and that it spits out 0.15.2. These is a shell.nix which will show all needed dependencies over time.

2. Clone this repo

3. TODO: Describe how to copy an example and built it to the keyboard. 

## Only modify files in my_keyboards/

Do only modify things inside my_keyboards. If you stick to this rule, future git fetches should be painless most of the time as we will keep changes inside the my_keyboards to an absolute minimum.

# Join our discord:

Feel free to join our discord server: https://discord.gg/jWY6UPgu


<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>
<br>


# OLD AND OUTDATED INFORMATION THAT NEEDS REWRITING:


To get started, follow these steps:

1. Install zig. 
Follow these instructions: https://ziglang.org/learn/getting-started/ - The objective is to be able to call "zig version" and get the zig version displayed. That means you have installed zig correctly and it can be found in your path

2. Fork this repo and clone it to your local machine and open your favourite IDE with the zigmkay folder as the root folder (the folder that contains the hidden .git folder)

3. Contact me on the discord "microzig" for a personal guide to get you up and running. :) 
 
# Getting started
- Copy an existing keyboard folder. For this walk through, we will copy the zilpzapl keyboard folder and call it "cool_board".
- In the outer most main.zig, the one that is located directly at the root of the src folder, change the content to this:

```c
pub fn main() !void {
    try @import("keyboards/cool_board/main.zig").main();
}
```

- Open a terminal at the root folder (the parent folder of the src folder) and run the follow command:
```bash
zig build
```

If you don't encounter any build errors, nothing will be outputted in the terminal.

Now you can find a .uf2 file in zig-out/firmware/zigmkay.uf2

Now flash this file to your keyboard.

# Editing your keymap
Typically you will only need to edit the keymap.zig file. This will contain your keymap with combos and custom code, and your pin mappings which you only need to alter if the board you use is different from what the copied keyboard was made for.

# Introduction to using ZigMKay
A keymap consists of N number of layers each with M number of keys. It is defined as [N][M]KeyDef. 

A KeyDef can be any of the following kinds:
- Tap_only: has a TapDef value only
- Hold_only: has a HoldDef value only
- Tap_Hold: has both a TapDef and a HoldDef
- Tap_autofire: has a TapDef only - when holding down a key of this type, repeating taps will be fired at a rate you can configure

A TapDef contains:
- a keycode, which is the code that will be fired when zigmkay decides that a tap has happened
- an optional Modifiers value - if set, this will be applied to the keycode 
- an optional media_key value - if set, this will fire a Consumer Control HID report (e.g., volume, play/pause, mute)
- an optional mouse_action value - if set, this will fire a Mouse HID report (e.g., clicks, wheel movements)
If a tap has a modifiers, the current held modifiers will be cancelled, the tap will be fired with its own modifiers and then any previous modifiers will be re-applied.
This behaviour allows for various features, eg. a layer activates shift, but a single key should not be shifted. In this case, the optional modifier could be set to empty (instead of null).

A HoldDef contains:
- an optional layer to activate
- an optional modifiers to activate
This model allows for straight forward combinations of layer switches and modifiers at the same time.
The modifiers defined here will be added to any existing mod holds (eg if left_alt is held down and this hold key is set to enable left_shift, then both of these modifiers will be held at the same time
  
Want to have a single key that fires a keycode with a modifier on tap and also shifts layer and applies another modifier when held? This is automatically support out of the box by this model. If you can express it with a KeyDef struct, it is possible.

## Autofire
Autofire allows for fast repeating and cannot be used in combination with holds, hence it has its own type. The usetype for this is to allow arrow keys (for instance) to reach very fast to holding, allowing for snappy ide work for instance. Likewise, w and b could also have autofire, and suddenly vim motions got a boost - this feature is very addictive by the way.

## Combos
A combo is defined by a KeyDef, 2 key_indexes and a layer that it is active on. By using a keyDef for combos so everything that is possible for a single key is also possible with a combo, ie tap_only, hold_only, tap_hold and aurofire are all supported by combos out of the box. Currently combos are limited to 2 keys but let me know if you need 3, then I might look into it.

## Retrotapping
Retrotapping is an opt in on the tap_hold type. When set to true, the key will fire its tap after the hold is released if no other key were tapped while the key were held. A use case for this is in combination with a tapping term of 0 ms. This will allow for eg instant layers switches and still trigger eg ENTER on release. 

## Permissive hold
Permissive hold is always on. In qmk you can enable permissive hold and pressing tap/hold key 1, then press and release key 2 and then releasing key 1 - all withing the tapping term will still make zigmkay choose the hold over the tap allowing for fast use of shift while typing fast. Permissive hold is not only the default but the only way in zigmkay.

## Encoders
ZigMKay supports quadrature rotary encoders. An encoder is defined with two key indexes representing clockwise (CW) and counter-clockwise (CCW) rotation. When the encoder is rotated, it simulates key press/release events for these indexes, allowing the same KeyDef logic (tap, hold, layer, etc.) to apply to encoder movements.

## HID Channels
ZigMKay supports multiple HID channels beyond standard keyboard:
- **Keyboard**: Standard 6-key rollover with modifier keys and LED indicator feedback
- **Consumer Control**: Media keys (volume, play/pause, mute, next/prev track)
- **Mouse**: 5-button mouse with X/Y movement, wheel, and pan support
- **Raw HID**: 32-byte bidirectional channel for companion app communication and key logging

This allows keymaps to define keys that control media playback, move the mouse cursor, or send custom data to a companion application.

## Custom code
You can hook into events and manipulate modifiers, layer settings and manually fire key presses and releases. By providing this pattern, zigmkay gives you full flexibility without making you opt out intirely from all tap/hold decision logic. 
The events you can hook into are:
- OnTapEnterBefore => This is fired when a tap is decided (by using tap_only, tap_hold or autofire) right before the actual tap press logic is executed (which will send a "keycode press" to the host)
- OnTapEnterAfter => This is fired when a tap is decided (by using tap_only, tap_hold or autofire) right after the actual tap press logic is executed (which will send a "keycode press" to the host)
- OnTapExitBefore => This is fired when a previously decided tap is released again (by using tap_only, tap_hold or autofire) right before the actual tap release logic is executed (which will send a "keycode release" to the host)
- OnTapExitAfter => This is fired when a previously decided tap is released again (by using tap_only, tap_hold or autofire) right after the actual tap release logic is executed (which will send a "keycode release" to the host)
- OnHoldEnterBefore => This is fired when a hold is decided (by using hold_only or tap_hold) right before the actual hold is executed (eg before any modifiers are sent and layers are manipulated)
- OnHoldEnterAfter => This is fired when a hold is decided (by using hold_only or tap_hold) right after the actual hold is executed (eg after any modifiers are sent and layers are manipulated)
- OnHoldExitBefore => This is fired when a previously decided hold is released again (by using hold_only or tap_hold) right before the actual hold-release is executed (eg before any modifiers cancels are sent and layers are manipulated back)
- OnHoldExitAfter => This is fired when a previously decided hold is released again (by using hold_only or tap_hold) right after the actual hold-release is executed (eg after any modifiers cancels are sent and layers are manipulated back)
- Tick => every time the loop ticks, this will be fired. Useful for when you want to time something that cannot be correlated to any of the other events.


# Guide
```c
pub fn main() !void {
    // Data queues
    var matrix_change_queue = zigmkay.core.MatrixStateChangeQueue.Create();
    var usb_command_queue = zigmkay.core.OutputCommandQueue.Create();

    // Logic
    const matrix_scanner = zigmkay.matrix_scanning.CreateMatrixScanner(.{ .debounce_ms = 5 });
    var processor = zigmkay.processing.CreateProcessorType(keyboard.dimensions, &keyboard.keymap){};
    const usb_command_executor = zigmkay.usb_command_executor.CreateAndInitUsbCommandExecutor();

    while (true) {
        const current_time = time.get_time_since_boot().to_us();

        // Detect matrix changes
        try matrix_scanner.DetectKeyboardChanges(&matrix_change_queue, current_time);

        // Decide actions
        try processor.Process(&matrix_change_queue, &usb_command_queue, current_time);

        // Execute actions
        try usb_command_executor.HouseKeepAndProcessCommands(&usb_command_queue);
    }
}
```
# KeyDef examples
- tap_only
- tap_only tap-with-mod
- tap_only with media key: KC.MEDIA_VOLUME_UP
- tap_only with mouse action: MS().WheelUp
- tap_only with mouse action: MS().WheelDown
- tap_only with mouse action: MS().LeftClick
- hold mod
- hold layer
- tap/hold with layer hold
- tap/hold with mod hold
- tap/hold with both layer and mod hold
- tap/hold with retro tapping enabled
- autofire
- combo
- custom code, example to do a tri-layer

# Philosophy
No hidden control flow. I don't want any behind-the-scenes triggered timing events og interrupts working anywhere it can be avoided (which I believe is everywhere). I want plain, readable sequential code that the reader can make sense of, even the first time they read the code. 

# Why did I make ZigMkay?
I was curious to what it would take to do this and then there was some things that could be improved in the existing options available:
- Written in zig. This should make it possible to give better and more compile error messages.
- Easy start: Easy to setup and compile locally (in opposition to qmk where python is now annoying, you must git pull with -recursive flag, you must run a qmk setup command etc). The "etc" is mainly because I personally always feel there are more cases, but I could not come up with any at the time of writing :D
- handling is done in plain procedural code (look at processing.zig). No events with hidden control flow or anything like that.
- tap-with-mod combined with hold: Say you need to press altgr+7 for making a {, then you also want the same key to be a modifier when hold. This is possible out of the box (possible in zmk, but in qmk this must be done using custom tap/hold handling)
- combos can fire anything that a single key can fire, e.g. a combo can behave as a modifier hold (say a+s should act as a LGUI hold) as well as layer switch - all out of the box within the standard way of configuring zigmkay (combos for modifiers is not possible in zmk afaik - please correct me if I'm wrong)
- custom code is more isolated to a key. This is one of the very nice feature in zmk - in qmk you cannot do this in the same manner, you will have the big switch case to handle all the custom behaviour.
- tap-without-mods while mod activated: Option of defining that a given key should be fired without any modifiers (ctrl, shift etc) even though shift or other modifiers are currently being held. 
- user is in control: The users code is the top level of orchestration. In qmk you hook into existing land and by magic everything is compiled. The zigmkay way makes it more obvious how the whole code is running and custom IO stuff will be implemented at the top level (the main.zig)
- no black magic like #define specific field, compile flags, special function names to be implemented etc. Instead you edit the source code. You are not hooking into predefined events or defining methods with specific names to allow your logic to run at a specific place. And you IDE will understand more of what is going on as a result.
- Strict 3-legged logic in terms of A:scanning, B:processing, C:send keycodes to the host using usb. Leg A and C are small, oneoffs and needs to be tested by hand. Leg B is the complex part an because queues are used for comminution between these 3, it is possible to test step B in isolation. And there are lots of tests of this part guarding against regression.
- Readable pin mapping definition
- Less custom code: Hook into tap-enter, tap-exit, hold-enter and hold-exit times. In qmk you react to key presses and key releases, so if you want a custom behaviour on tap, but standard on hold, you must handle both tap and hold in your custom code. in zigmkay you let zigmkay decide if tap or hold is chosen, and only run your code in one of the cases. 
- Only dependencies is zig, which must be downloaded first, and microzig which will be auto-fetched when compiling (i think that is the time this happens)
- Autofire per setting - allows for very fast autofire, eg on arrow keys while other keys remain unchanged. This feature does not support combination with hold functions.

# When not to choose zigmkay
- mcu: zigmkay will only support the mcu types that microzig supports.
- wireless: zigmkay is not planned to be wireless ever.
- tap dances: only tap/hold is supported as I don't need tap dances myself. But might be a future thing.
- rgb: I don't need rgb support myself - however, it could be rather fun to explore good ways this could be supported so this might be a thing in the future - but no promisses

# TODOs
- 3 key combos (maybe)
- make documentation
- split support
- import keycodes from qmk

# Found a bug or want to contribute?
- Please let me know. You can write me here in the repo or contact me on the "zig" or the "microzig" discord servers. My username is "Rollercole".

# License 
This project is licensed under GPL2
 
# AI-Assisted Development
Parts of this firmware were developed with AI assistance. All AI-generated code, features, and changes were reviewed and tested by human developers before inclusion.
 
 


