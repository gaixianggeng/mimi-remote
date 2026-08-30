#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MimiTailcatProxy : NSObject

@property(nonatomic, copy, readonly) NSString *localEndpoint;

- (BOOL)closeWithError:(NSError **)error NS_SWIFT_NAME(close());

@end

@interface MimiTailcatBridge : NSObject

@property(class, nonatomic, readonly, getter=isAvailable) BOOL available;

+ (nullable NSString *)generatePrivateKeyWithError:(NSError **)error
    NS_SWIFT_NAME(generatePrivateKey());
+ (nullable NSString *)publicKeyForPrivateKey:(NSString *)privateKey
                                         error:(NSError **)error
    NS_SWIFT_NAME(publicKey(privateKey:));
+ (nullable MimiTailcatProxy *)startProxyWithAddress:(NSString *)address
                                          privateKey:(NSString *)privateKey
                                          remotePort:(NSInteger)remotePort
                                               error:(NSError **)error
    NS_SWIFT_NAME(startProxy(address:privateKey:remotePort:));

@end


NS_ASSUME_NONNULL_END
