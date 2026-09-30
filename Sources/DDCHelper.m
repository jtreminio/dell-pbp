// Short-lived DDC helper: a new process avoids private CoreDisplay/IOAV caches
// that can retain a dead connection after the monitor swaps input sources.
#import "MonitorDDC.h"
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSString *operation = @(argv[1]);
        BOOL identify = [operation isEqualToString:@"identify"];
        BOOL reading = [operation isEqualToString:@"read"];
        BOOL writing = [operation isEqualToString:@"write"];
        if ((!identify && !reading && !writing) ||
            (identify && argc != 2) || (reading && argc != 4) || (writing && argc != 5)) return 2;
        uint8_t feature = 0;
        uint16_t value = 0;
        if (!identify) {
            char *end = NULL;
            unsigned long number = strtoul(argv[2], &end, 10);
            if (*end || (number != 0x60 && number != 0xE8 && number != 0xE9)) return 2;
            feature = (uint8_t)number;
            if (writing) {
                number = strtoul(argv[3], &end, 10);
                if (*end || number > UINT16_MAX) return 2;
                value = (uint16_t)number;
            }
        }
        // The menu app, diagnostics, and another local app instance must not consume
        // one another's DDC replies. The OS releases this lock when the helper exits.
        NSString *lockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"DellPBP-DDC-%u.lock", getuid()]];
        int lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
        if (lock < 0 || flock(lock, LOCK_EX) != 0) {
            fprintf(stderr, "Could not acquire the local monitor communication lock.\n"); return 8;
        }
        NSError *error = nil;
        MonitorDDC *connection = [MonitorDDC discoverWithError:&error];
        if (!connection) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 3; }
        if (!identify && ![connection.monitorIdentifier isEqualToString:@(argv[argc-1])]) {
            fprintf(stderr, "The connected monitor changed. Refresh before choosing a layout.\n"); return 4;
        }
        NSNumber *result = @0;
        if (reading) result = [connection readFeature:feature error:&error];
        if (writing) {
            // Preflight a fresh connection before sending one write. No write retries.
            if (![connection readFeature:0xE9 error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 6;
            }
            if (![connection writeFeature:feature value:value error:&error]) result = nil;
        }
        if (!result) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 5; }
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"identifier":connection.monitorIdentifier,
                         @"name":connection.monitorName, @"value":result} options:0 error:&error];
        if (!json) return 7;
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
