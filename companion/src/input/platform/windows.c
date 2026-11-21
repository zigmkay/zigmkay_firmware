#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

typedef struct {
    HKL hkl;
    int pending_dead;
    uint8_t pending_vk;
    uint8_t pending_mods;
} WindowsKeyMap;

WindowsKeyMap *windowsKeyMapInit(void) {
    WindowsKeyMap *km = malloc(sizeof(WindowsKeyMap));
    if (!km) return NULL;
    km->hkl = GetKeyboardLayout(0);
    km->pending_dead = 0;
    km->pending_vk = 0;
    km->pending_mods = 0;
    return km;
}

void windowsKeyMapDeinit(WindowsKeyMap *km) {
    free(km);
}

void windowsKeyMapRefresh(WindowsKeyMap *km) {
    if (!km) return;
    km->hkl = GetKeyboardLayout(0);
    km->pending_dead = 0;
}

static void build_key_state(uint8_t mods, BYTE key_state[256]) {
    memset(key_state, 0, 256);
    if (mods & 0x01) key_state[VK_SHIFT]   = 0x80;
    if (mods & 0x02) key_state[VK_CONTROL] = 0x80;
    if (mods & 0x04) key_state[VK_MENU]    = 0x80;
    if (mods & 0x10) key_state[VK_CAPITAL] = 0x01;
    if (mods & 0x20) key_state[VK_NUMLOCK] = 0x01;
}

static int translate_key(HKL hkl, uint8_t vk, uint8_t mods, WCHAR *wbuf, int wbuf_len) {
    BYTE key_state[256];
    build_key_state(mods, key_state);
    return ToUnicodeEx((UINT)vk, 0, key_state, wbuf, wbuf_len, 0, hkl);
}

static size_t utf16_to_utf8(const WCHAR *wbuf, int wbuf_len, uint8_t *buf, size_t buf_len) {
    int utf8_len = WideCharToMultiByte(CP_UTF8, 0, wbuf, wbuf_len,
                                       (LPSTR)buf, (int)buf_len, NULL, NULL);
    return (size_t)(utf8_len > 0 ? utf8_len : 0);
}

static void flush_dead_key(HKL hkl, WCHAR *out) {
    BYTE key_state[256];
    memset(key_state, 0, 256);
    ToUnicodeEx(VK_SPACE, 0, key_state, out, 8, 0, hkl);
}

size_t windowsKeyMapTranslate(WindowsKeyMap *km, uint8_t vk, uint8_t mods, bool is_dead,
                               uint8_t *buf, size_t buf_len) {
    if (!km || buf_len < 1) return 0;

    WCHAR wbuf[8];

    if (is_dead) {
        BYTE key_state[256];
        build_key_state(mods, key_state);
        key_state[vk] = 0x80;
        int r1 = ToUnicodeEx((UINT)vk, 0, key_state, wbuf, 8, 0, km->hkl);
        if (r1 < 0) {
            km->pending_dead = 1;
            km->pending_vk = vk;
            km->pending_mods = mods;
            key_state[vk] = 0;
            WCHAR flush[8];
            int flush_r = ToUnicodeEx(VK_SPACE, 0, key_state, flush, 8, 0, km->hkl);
            if (flush_r > 0) {
                return utf16_to_utf8(flush, flush_r, buf, buf_len);
            }
            return 0;
        }
        if (r1 <= 0) return 0;
        return utf16_to_utf8(wbuf, r1, buf, buf_len);
    }

    if (km->pending_dead) {
        km->pending_dead = 0;
        BYTE key_state[256];
        memset(key_state, 0, 256);
        WCHAR flush[8];
        ToUnicodeEx(VK_SPACE, 0, key_state, flush, 8, 0, km->hkl);
    }

    int result = translate_key(km->hkl, vk, mods, wbuf, 8);
    if (result < 0) {
        km->pending_dead = 1;
        km->pending_vk = vk;
        km->pending_mods = mods;
        return 0;
    }
    if (result <= 0) return 0;
    return utf16_to_utf8(wbuf, result, buf, buf_len);
}