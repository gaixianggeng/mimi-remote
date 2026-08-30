#import "MimiTailcatBridge.h"

#if __has_include(<TailcatMobile/TailcatMobile.h>)
#import <TailcatMobile/TailcatMobile.h>
#define MIMI_TAILCAT_AVAILABLE 1
#else
#define MIMI_TAILCAT_AVAILABLE 0
#endif

static NSString *const MimiTailcatErrorDomain = @"com.gaixianggeng.mimi.tailcat-experiment";

@interface MimiTailcatProxy ()
#if MIMI_TAILCAT_AVAILABLE
@property(nonatomic, strong) TailcatmobileProxy *nativeProxy;
#endif
@end

@implementation MimiTailcatProxy

#if MIMI_TAILCAT_AVAILABLE
- (instancetype)initWithNativeProxy:(TailcatmobileProxy *)nativeProxy {
    self = [super init];
    if (self) {
        _nativeProxy = nativeProxy;
    }
    return self;
}
#endif

- (NSString *)localEndpoint {
#if MIMI_TAILCAT_AVAILABLE
    return self.nativeProxy.localEndpoint;
#else
    return @"";
#endif
}

- (BOOL)closeWithError:(NSError **)error {
#if MIMI_TAILCAT_AVAILABLE
    return [self.nativeProxy close:error];
#else
    if (error) {
        *error = [NSError errorWithDomain:MimiTailcatErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"Tailcat iOS 框架未生成"}];
    }
    return NO;
#endif
}

@end

@implementation MimiTailcatBridge

+ (BOOL)isAvailable {
    return MIMI_TAILCAT_AVAILABLE == 1;
}

+ (NSString *)generatePrivateKeyWithError:(NSError **)error {
#if MIMI_TAILCAT_AVAILABLE
    return TailcatmobileGeneratePrivateKey(error);
#else
    if (error) {
        *error = [self unavailableError];
    }
    return nil;
#endif
}

+ (NSString *)publicKeyForPrivateKey:(NSString *)privateKey error:(NSError **)error {
#if MIMI_TAILCAT_AVAILABLE
    return TailcatmobilePublicKey(privateKey, error);
#else
    if (error) {
        *error = [self unavailableError];
    }
    return nil;
#endif
}

+ (MimiTailcatProxy *)startProxyWithAddress:(NSString *)address
                                 privateKey:(NSString *)privateKey
                                 remotePort:(NSInteger)remotePort
                                      error:(NSError **)error {
#if MIMI_TAILCAT_AVAILABLE
    TailcatmobileProxy *nativeProxy = TailcatmobileStartProxy(address, privateKey, remotePort, error);
    if (!nativeProxy) {
        return nil;
    }
    return [[MimiTailcatProxy alloc] initWithNativeProxy:nativeProxy];
#else
    if (error) {
        *error = [self unavailableError];
    }
    return nil;
#endif
}

+ (NSError *)unavailableError {
    return [NSError errorWithDomain:MimiTailcatErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: @"Tailcat iOS 框架未生成"}];
}

@end
