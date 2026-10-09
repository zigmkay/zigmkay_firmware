#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>

enum {
    zigmkay_vendor_id = 0xFAFA,
    zigmkay_product_id = 0x00F0,
    zigmkay_usage_page = 0xFF31,
    zigmkay_usage = 0x0074,
    key_event_signal = 0x03,
    report_size = 32,
};

static uint8_t report_buffer[report_size];

static void set_number(CFMutableDictionaryRef dictionary, CFStringRef key, int value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
}

static void print_report(void *context, IOReturn result, void *sender,
                         IOHIDReportType type, uint32_t report_id,
                         uint8_t *report, CFIndex length) {
    (void)context;
    (void)sender;
    (void)type;
    (void)report_id;

    if (result != kIOReturnSuccess) {
        fprintf(stderr, "Raw HID read failed: 0x%08x\n", result);
        return;
    }
    if (length == 0) return;

    if (report[0] == key_event_signal && length >= 5) {
        printf("key=%u %-7s layer=%u modifiers=0x%02x\n",
               report[2], report[1] ? "pressed" : "released",
               report[3], report[4]);
    } else {
        printf("signal=0x%02x data=", report[0]);
        for (CFIndex i = 1; i < length; ++i) printf("%02x", report[i]);
        putchar('\n');
    }
    fflush(stdout);
}

static void device_connected(void *context, IOReturn result, void *sender,
                             IOHIDDeviceRef device) {
    (void)context;
    (void)result;
    (void)sender;

    puts("ZigMkay RawHID connected; press Ctrl-C to stop.");
    fflush(stdout);
    IOHIDDeviceRegisterInputReportCallback(
        device, report_buffer, sizeof(report_buffer), print_report, NULL);
}

int main(void) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (manager == NULL) {
        fputs("Could not create an IOKit HID manager.\n", stderr);
        return 1;
    }

    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    set_number(matching, CFSTR(kIOHIDVendorIDKey), zigmkay_vendor_id);
    set_number(matching, CFSTR(kIOHIDProductIDKey), zigmkay_product_id);
    set_number(matching, CFSTR(kIOHIDPrimaryUsagePageKey), zigmkay_usage_page);
    set_number(matching, CFSTR(kIOHIDPrimaryUsageKey), zigmkay_usage);

    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(matching);
    IOHIDManagerRegisterDeviceMatchingCallback(manager, device_connected, NULL);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    const IOReturn open_result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (open_result != kIOReturnSuccess) {
        fprintf(stderr, "Could not open ZigMkay RawHID: 0x%08x\n", open_result);
        CFRelease(manager);
        return 1;
    }

    puts("Waiting for ZigMkay RawHID (FAFA:00F0, FF31:0074)...");
    fflush(stdout);
    CFRunLoopRun();

    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    CFRelease(manager);
    return 0;
}
