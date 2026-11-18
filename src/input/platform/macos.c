#include <Carbon/Carbon.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    TISInputSourceRef source;
    const UCKeyboardLayout *layout;
    UInt32 dead_key_state;
} MacOsKeyMap;

static void load_layout(MacOsKeyMap *km) {
    CFDataRef data = (CFDataRef)TISGetInputSourceProperty(
        km->source, kTISPropertyUnicodeKeyLayoutData);
    km->layout = data ? (const UCKeyboardLayout *)CFDataGetBytePtr(data) : NULL;
}

MacOsKeyMap *macOsKeyMapInit(void) {
    MacOsKeyMap *km = malloc(sizeof(MacOsKeyMap));
    if (!km) return NULL;
    km->dead_key_state = 0;
    km->source = TISCopyCurrentKeyboardInputSource();
    load_layout(km);
    return km;
}

void macOsKeyMapDeinit(MacOsKeyMap *km) {
    if (!km) return;
    if (km->source) CFRelease(km->source);
    free(km);
}

void macOsKeyMapRefresh(MacOsKeyMap *km) {
    if (!km) return;
    if (km->source) CFRelease(km->source);
    km->source = TISCopyCurrentKeyboardInputSource();
    km->dead_key_state = 0;
    load_layout(km);
}

static size_t utf16_to_utf8(const UniChar *src, UniCharCount src_len,
                             uint8_t *dst, size_t dst_max) {
    size_t n = 0;
    for (UniCharCount i = 0; i < src_len; i++) {
        uint32_t cp = src[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < src_len) {
            uint32_t low = src[++i];
            if (low >= 0xDC00 && low <= 0xDFFF)
                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
        }
        if (cp < 0x80) {
            if (n + 1 > dst_max) break;
            dst[n++] = (uint8_t)cp;
        } else if (cp < 0x800) {
            if (n + 2 > dst_max) break;
            dst[n++] = 0xC0 | (uint8_t)(cp >> 6);
            dst[n++] = 0x80 | (uint8_t)(cp & 0x3F);
        } else if (cp < 0x10000) {
            if (n + 3 > dst_max) break;
            dst[n++] = 0xE0 | (uint8_t)(cp >> 12);
            dst[n++] = 0x80 | (uint8_t)((cp >> 6) & 0x3F);
            dst[n++] = 0x80 | (uint8_t)(cp & 0x3F);
        } else {
            if (n + 4 > dst_max) break;
            dst[n++] = 0xF0 | (uint8_t)(cp >> 18);
            dst[n++] = 0x80 | (uint8_t)((cp >> 12) & 0x3F);
            dst[n++] = 0x80 | (uint8_t)((cp >> 6) & 0x3F);
            dst[n++] = 0x80 | (uint8_t)(cp & 0x3F);
        }
    }
    return n;
}

static void flush_dead_key(MacOsKeyMap *km) {
    if (!km->layout || km->dead_key_state == 0) return;
    UniChar chars[8];
    UniCharCount char_count = 0;
    UInt32 saved_state = km->dead_key_state;
    km->dead_key_state = 0;
    UCKeyTranslate(
        km->layout, 0, kUCKeyActionDown, 0, LMGetKbdType(), 0,
        &km->dead_key_state, sizeof(chars) / sizeof(chars[0]), &char_count, chars);
    km->dead_key_state = saved_state;
    km->dead_key_state = 0;
}

size_t macOsKeyMapTranslate(MacOsKeyMap *km, uint16_t vk, uint8_t mods, bool is_dead,
                             uint8_t *buf, size_t buf_len) {
    if (!km || !km->layout) return 0;

    UInt32 modifier_state = 0;
    if (mods & 0x01) modifier_state |= (shiftKey >> 8);
    if (mods & 0x04) modifier_state |= (optionKey >> 8);
    if (mods & 0x10) modifier_state |= (alphaLock >> 8);

    UniChar chars[8];
    UniCharCount char_count = 0;

    if (is_dead) {
        UInt32 saved_state = km->dead_key_state;
        km->dead_key_state = 0;
        OSStatus status = UCKeyTranslate(
            km->layout, (UInt16)vk, kUCKeyActionDown, modifier_state,
            LMGetKbdType(), 0, &km->dead_key_state,
            sizeof(chars) / sizeof(chars[0]), &char_count, chars);
        if (status != noErr || char_count == 0) {
            km->dead_key_state = saved_state;
            return 0;
        }
        if (km->dead_key_state != 0) {
            flush_dead_key(km);
        }
        km->dead_key_state = saved_state;
    } else {
        if (km->dead_key_state != 0) {
            OSStatus status = UCKeyTranslate(
                km->layout, (UInt16)vk, kUCKeyActionDown, modifier_state,
                LMGetKbdType(), 0, &km->dead_key_state,
                sizeof(chars) / sizeof(chars[0]), &char_count, chars);
            if (status == noErr && char_count > 0) {
                km->dead_key_state = 0;
                return utf16_to_utf8(chars, char_count, buf, buf_len);
            }
            km->dead_key_state = 0;
        }
        OSStatus status = UCKeyTranslate(
            km->layout, (UInt16)vk, kUCKeyActionDown, modifier_state,
            LMGetKbdType(), 0, &km->dead_key_state,
            sizeof(chars) / sizeof(chars[0]), &char_count, chars);
        if (status != noErr || char_count == 0) return 0;
    }

    if (char_count == 1 && chars[0] >= 0xF700 && chars[0] <= 0xF7FF) return 0;
    return utf16_to_utf8(chars, char_count, buf, buf_len);
}