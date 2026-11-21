#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PairItBluetoothGateway : NSObject
- (instancetype)initWithPort:(uint16_t)port;
- (void)startWithName:(NSString *)name;
- (void)stop;
@property(nonatomic, copy, nullable) void (^statusChanged)(NSString *status);
@end
NS_ASSUME_NONNULL_END
