#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A single U4025QW connection. Call only from the app's serial monitor queue.
@interface MonitorDDC : NSObject
@property (nonatomic, readonly, copy) NSString *monitorName;
@property (nonatomic, readonly, copy) NSString *monitorIdentifier;
+ (nullable instancetype)discoverWithError:(NSError **)error NS_SWIFT_NAME(discover());
- (nullable NSNumber *)readFeature:(uint8_t)feature error:(NSError **)error NS_SWIFT_NAME(read(_:));
- (BOOL)writeFeature:(uint8_t)feature value:(uint16_t)value error:(NSError **)error NS_SWIFT_NAME(write(_:value:));
@end

/// Pure packet validation, shared by the transport and its tests.
BOOL DDCDecodeReply(const uint8_t *bytes, size_t length, uint8_t feature, uint16_t *value);
NS_ASSUME_NONNULL_END
