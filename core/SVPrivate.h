// Private CoreSimulator selectors simview calls. Declared here, resolved at runtime: CoreSimulator is
// dlopen'ed, never linked.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurfaceObjC.h>

@protocol SVSimPrivate <NSObject>
// SimServiceContext / SimDeviceSet
+ (id)sharedServiceContextForDeveloperDir:(NSString *)dir error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)devices;
// SimDevice
- (NSUUID *)UDID;
- (NSString *)name;
- (NSString *)stateString;
- (id)deviceType;
- (id)runtime;
- (id)io;
- (NSArray *)ioPorts;
- (NSString *)dataPath;                                     // …/CoreSimulator/Devices/<UDID>/data
- (NSDictionary *)installedAppsWithError:(NSError **)error;  // bundle id → app info
- (id)descriptor;
- (BOOL)available;                                        // false: its runtime or device type is gone
- (BOOL)isAvailableWithError:(NSError **)error;
// SimDeviceType
- (NSString *)chromeIdentifier;
- (CGSize)mainScreenSize;
- (float)mainScreenScale;
- (NSString *)productFamily;
- (NSString *)bundlePath;
// SimScreenAdapter / SimScreen
- (void)enumerateScreensWithCompletionQueue:(dispatch_queue_t)queue completionHandler:(id)handler;
- (id)screenProperties;
- (unsigned long long)screenType;
- (IOSurface *)framebufferSurface;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(id)frame
                surfacesChangedCallback:(id)surfaces
              propertiesChangedCallback:(id)properties;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@end

/// CoreSimulator's service context for the selected Xcode, loading the framework on first use.
id SVServiceContext(void);
