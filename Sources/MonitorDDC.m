// Display discovery is adapted from waydabber/m1ddc (MIT).
// See ThirdParty/m1ddc-LICENSE. Transport and validation are local implementations.
#import "MonitorDDC.h"
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <unistd.h>

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

static NSError *DDCError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"DellPBP.DDC" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static id Property(io_registry_entry_t entry, CFStringRef key) {
    return CFBridgingRelease(IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key,
                           kCFAllocatorDefault, kIORegistryIterateRecursively));
}
static BOOL ValidInput(uint16_t value) { return value == 0x19 || value == 0x0F || value == 0x11; }

BOOL DDCDecodeReply(const uint8_t *b, size_t n, uint8_t feature, uint16_t *value) {
    if (n < 11 || b[0] != 0x6E || b[1] != 0x88 || b[2] != 0x02 || b[3] != 0 || b[4] != feature) return NO;
    uint8_t checksum = 0x50;
    for (size_t i = 0; i < 11; ++i) checksum ^= b[i];
    if (checksum != 0) return NO;
    *value = ((uint16_t)b[8] << 8) | b[9];
    return YES;
}

@implementation MonitorDDC {
    IOAVServiceRef _service;
    uint32_t _chipAddress;
}

+ (instancetype)discoverWithError:(NSError **)error {
    CGDirectDisplayID displays[32];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, displays, &count) != kCGErrorSuccess) {
        if (error) *error = DDCError(1, @"Cannot read connected displays.");
        return nil;
    }
    MonitorDDC *match = nil;
    NSUInteger matchingDisplays = 0;
    for (uint32_t i = 0; i < count; ++i) {
        NSDictionary *info = CFBridgingRelease(CoreDisplay_DisplayCreateInfoDictionary(displays[i]));
        NSString *location = info[@"IODisplayLocation"];
        if (![location isKindOfClass:NSString.class]) continue;
        io_registry_entry_t adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)location);
        if (!adapter) continue;
        NSDictionary *attributes = Property(adapter, CFSTR("DisplayAttributes"));
        NSDictionary *product = [attributes isKindOfClass:NSDictionary.class] ? attributes[@"ProductAttributes"] : nil;
        NSString *name = product[@"ProductName"];
        if (![name isKindOfClass:NSString.class] || [name rangeOfString:@"U4025QW" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            IOObjectRelease(adapter);
            continue;
        }
        matchingDisplays++;
        if (matchingDisplays > 1) {
            IOObjectRelease(adapter);
            if (error) *error = DDCError(2, @"More than one U4025QW is connected. Connect one to choose its layout.");
            return nil;
        }
        io_iterator_t iterator = IO_OBJECT_NULL;
        uint64_t selectedAdapterID = 0;
        IORegistryEntryGetRegistryEntryID(adapter, &selectedAdapterID);
        io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
        kern_return_t iterResult = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
        IOObjectRelease(root);
        if (iterResult != KERN_SUCCESS) {
            IOObjectRelease(adapter);
            continue;
        }
        io_registry_entry_t entry;
        BOOL matchingFramebuffer = NO;
        while ((entry = IOIteratorNext(iterator))) {
            // On Apple silicon, the DCP service lives in a sibling branch of the
            // framebuffer, not below its IODisplayLocation. Follow m1ddc's scoped
            // registry traversal and stop matching at the next framebuffer.
            if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
                uint64_t entryID = 0;
                matchingFramebuffer = IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS && entryID == selectedAdapterID;
                IOObjectRelease(entry);
                continue;
            }
            io_name_t entryName = {0};
            IORegistryEntryGetName(entry, entryName);
            if (!matchingFramebuffer || strcmp(entryName, "DCPAVServiceProxy") != 0 || ![Property(entry, CFSTR("Location")) isEqual:@"External"]) {
                IOObjectRelease(entry);
                continue;
            }
            IOAVServiceRef service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry);
            if (service) {
                match = [[MonitorDDC alloc] init];
                match->_service = service;
                match->_chipAddress = 0x37;
                match->_monitorName = [name copy];
                NSString *serial = product[@"AlphanumericSerialNumber"];
                // Model/EDID UUID can change when PBP changes. Use the monitor serial instead.
                match->_monitorIdentifier = [NSString stringWithFormat:@"U4025QW:%@", serial.length ? serial : @"single-monitor"];
                io_registry_entry_t parent = IO_OBJECT_NULL;
                if (IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS) {
                    if ([Property(parent, CFSTR("EPICProviderClass")) isEqual:@"AppleDCPMCDP29XX"]) match->_chipAddress = 0xB7;
                    IOObjectRelease(parent);
                }
                IOObjectRelease(entry);
                break;
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iterator);
        IOObjectRelease(adapter);
    }
    if (!match && error) *error = DDCError(3, @"U4025QW unavailable. Connect this Mac directly and enable DDC/CI in the monitor menu.");
    return match;
}

- (void)dealloc { if (_service) CFRelease(_service); }

- (NSNumber *)readFeature:(uint8_t)feature error:(NSError **)error {
    if (feature != 0x60 && feature != 0xE8 && feature != 0xE9) {
        if (error) *error = DDCError(4, @"This app reads only input and PBP settings.");
        return nil;
    }
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        uint8_t request[] = {0x82, 0x01, feature, (uint8_t)(0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ feature)};
        usleep(200000);
        IOReturn sent = IOAVServiceWriteI2C(_service, _chipAddress, 0x51, request, sizeof(request));
        if (sent != kIOReturnSuccess) continue;
        usleep(250000);
        uint8_t reply[12] = {0};
        IOReturn received = IOAVServiceReadI2C(_service, _chipAddress, 0x51, reply, sizeof(reply));
        uint16_t value = 0;
        if (received == kIOReturnSuccess && DDCDecodeReply(reply, sizeof(reply), feature, &value)) return @(value);
    }
    if (error) *error = DDCError(5, [NSString stringWithFormat:@"The monitor did not return a valid reply for setting %02X. Its video input may be inactive.", feature]);
    return nil;
}

- (BOOL)writeFeature:(uint8_t)feature value:(uint16_t)value error:(NSError **)error {
    BOOL allowed = (feature == 0xE9 && (value == 0 || value == 0x24 || value == 0x27 || value == 0x28 || value == 0x29 || value == 0x2A))
                || (feature == 0x60 && ValidInput(value))
                || (feature == 0xE8 && ValidInput(value & 0x1F));
    if (!allowed) {
        if (error) *error = DDCError(6, @"Unsupported monitor setting blocked.");
        return NO;
    }
    uint8_t request[] = {0x84, 0x03, feature, (uint8_t)(value >> 8), (uint8_t)value, 0};
    uint8_t checksum = 0x6E ^ 0x51;
    for (size_t i = 0; i < 5; ++i) checksum ^= request[i];
    request[5] = checksum;
    usleep(250000);
    IOReturn sent = IOAVServiceWriteI2C(_service, _chipAddress, 0x51, request, sizeof(request));
    if (sent != kIOReturnSuccess && error) *error = DDCError(7, [NSString stringWithFormat:@"Monitor write failed (%08X).", sent]);
    return sent == kIOReturnSuccess;
}
@end
