#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    struct xkb_context *ctx;
    struct xkb_keymap  *keymap;
    struct xkb_state   *state;
    struct xkb_compose_table *compose_table;
    struct xkb_compose_state *compose_state;
    xkb_mod_index_t     idx_shift;
    xkb_mod_index_t     idx_ctrl;
    xkb_mod_index_t     idx_alt;
    xkb_mod_index_t     idx_logo;
    xkb_mod_index_t     idx_caps;
} LinuxKeyMap;

static void load_indices(LinuxKeyMap *km) {
    if (!km->keymap) {
        km->idx_shift = km->idx_ctrl = km->idx_alt =
            km->idx_logo = km->idx_caps = XKB_MOD_INVALID;
        return;
    }
    km->idx_shift = xkb_keymap_mod_get_index(km->keymap, XKB_MOD_NAME_SHIFT);
    km->idx_ctrl  = xkb_keymap_mod_get_index(km->keymap, XKB_MOD_NAME_CTRL);
    km->idx_alt   = xkb_keymap_mod_get_index(km->keymap, XKB_MOD_NAME_ALT);
    km->idx_logo  = xkb_keymap_mod_get_index(km->keymap, XKB_MOD_NAME_LOGO);
    km->idx_caps  = xkb_keymap_mod_get_index(km->keymap, XKB_MOD_NAME_CAPS);
}

static void load_keymap(LinuxKeyMap *km) {
    if (km->state)  { xkb_state_unref(km->state);    km->state  = NULL; }
    if (km->keymap) { xkb_keymap_unref(km->keymap);  km->keymap = NULL; }
    if (km->compose_state) { xkb_compose_state_unref(km->compose_state); km->compose_state = NULL; }
    if (km->compose_table) { xkb_compose_table_unref(km->compose_table); km->compose_table = NULL; }

    km->keymap = xkb_keymap_new_from_names(km->ctx, NULL,
                                            XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!km->keymap) {
        const struct xkb_rule_names fallback = {
            .rules  = "evdev",
            .model  = "pc105",
            .layout = "us",
        };
        km->keymap = xkb_keymap_new_from_names(km->ctx, &fallback,
                                                XKB_KEYMAP_COMPILE_NO_FLAGS);
    }
    if (km->keymap) {
        km->state = xkb_state_new(km->keymap);
        km->compose_table = xkb_compose_table_new_from_locale(km->ctx, NULL, XKB_COMPOSE_COMPILE_NO_FLAGS);
        if (km->compose_table) {
            km->compose_state = xkb_compose_state_new(km->compose_table, XKB_COMPOSE_STATE_NO_FLAGS);
        }
    }
    load_indices(km);
}

LinuxKeyMap *linuxKeyMapInit(void) {
    LinuxKeyMap *km = malloc(sizeof(LinuxKeyMap));
    if (!km) return NULL;
    km->ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!km->ctx) { free(km); return NULL; }
    km->keymap = NULL;
    km->state  = NULL;
    km->compose_table = NULL;
    km->compose_state = NULL;
    load_keymap(km);
    return km;
}

void linuxKeyMapDeinit(LinuxKeyMap *km) {
    if (!km) return;
    if (km->compose_state) xkb_compose_state_unref(km->compose_state);
    if (km->compose_table) xkb_compose_table_unref(km->compose_table);
    if (km->state)  xkb_state_unref(km->state);
    if (km->keymap) xkb_keymap_unref(km->keymap);
    xkb_context_unref(km->ctx);
    free(km);
}

void linuxKeyMapRefresh(LinuxKeyMap *km) {
    if (km) load_keymap(km);
}

static xkb_mod_mask_t mod_mask(xkb_mod_index_t idx) {
    return (idx != XKB_MOD_INVALID) ? (xkb_mod_mask_t)1u << idx : 0;
}

static void flush_compose(LinuxKeyMap *km) {
    if (!km->compose_state) return;
    xkb_compose_state_reset(km->compose_state);
}

size_t linuxKeyMapTranslate(LinuxKeyMap *km, uint32_t keycode, uint8_t mods,
                             bool is_dead, char *buf, size_t buf_len) {
    if (!km || !km->state) return 0;

    xkb_mod_mask_t depressed = 0, locked = 0;
    if (mods & 0x01) depressed |= mod_mask(km->idx_shift);
    if (mods & 0x02) depressed |= mod_mask(km->idx_ctrl);
    if (mods & 0x04) depressed |= mod_mask(km->idx_alt);
    if (mods & 0x08) depressed |= mod_mask(km->idx_logo);
    if (mods & 0x10) locked    |= mod_mask(km->idx_caps);
    xkb_state_update_mask(km->state, depressed, 0, locked, 0, 0, 0);

    if (is_dead) {
        if (km->compose_state) {
            flush_compose(km);
        }
        int written = xkb_state_key_get_utf8(km->state, keycode, buf, buf_len);
        return (size_t)(written > 0 ? written : 0);
    }

    if (km->compose_state) {
        xkb_keysym_t sym = xkb_state_key_get_one_sym(km->state, keycode);
        enum xkb_compose_feed_result feed = xkb_compose_state_feed(km->compose_state, sym);
        if (feed == XKB_COMPOSE_FEED_ACCEPTED) {
            enum xkb_compose_status status = xkb_compose_state_get_status(km->compose_state);
            if (status == XKB_COMPOSE_COMPOSING) return 0;
            if (status == XKB_COMPOSE_COMPOSED) {
                int written = xkb_compose_state_get_utf8(km->compose_state, buf, buf_len);
                xkb_compose_state_reset(km->compose_state);
                return (size_t)(written > 0 ? written : 0);
            }
            if (status == XKB_COMPOSE_CANCELLED) {
                xkb_compose_state_reset(km->compose_state);
                return 0;
            }
        }
    }

    int written = xkb_state_key_get_utf8(km->state, keycode, buf, buf_len);
    return (size_t)(written > 0 ? written : 0);
}