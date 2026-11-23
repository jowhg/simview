#import "SVCore.h"
#import <CommonCrypto/CommonDigest.h>

/// Runs `xcrun devicectl …`, waiting up to `timeout` seconds. Returns its stdout, or nil if it failed.
static NSData *SVDevicectl(NSArray<NSString *> *arguments, NSTimeInterval timeout) {
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
  task.arguments = [@[ @"devicectl" ] arrayByAddingObjectsFromArray:arguments];
  NSPipe *output = [NSPipe pipe];
  task.standardOutput = output;
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  task.standardInput = [NSFileHandle fileHandleWithNullDevice];
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  task.terminationHandler = ^(NSTask *finished) { dispatch_semaphore_signal(done); };
  if (![task launchAndReturnError:nil]) return nil;
  NSData *data = [output.fileHandleForReading readDataToEndOfFile];
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
    [task terminate];
    return nil;
  }
  return task.terminationStatus == 0 ? data : nil;
}

/// What is on the Mac clipboard, to tell a real change from the same content written back (DeviceHub mirrors the
/// devices it shows, so a transfer to one of them comes back as a new Mac clipboard change).
static NSString *SVMacFingerprint(void) {
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  NSData *data = [[pasteboard stringForType:NSPasteboardTypeString] dataUsingEncoding:NSUTF8StringEncoding];
  NSPasteboardType first = pasteboard.types.firstObject;
  if (!data && first) data = [pasteboard dataForType:first];
  if (!data) return @"";
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString stringWithString:first ?: @""];
  for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

@implementation SVPasteboardSync {
  dispatch_queue_t _queue;  // every transfer, one at a time; the state below lives on it
  NSMutableSet<NSString *> *_devices;
  NSMutableDictionary<NSString *, NSNumber *> *_macCountSeen;    // Mac changeCount each device is up to date with
  NSMutableDictionary<NSString *, NSString *> *_fingerprint;     // the content behind it
  NSMutableDictionary<NSString *, NSNumber *> *_deviceCount;     // device changeCount right after our last transfer
  NSInteger _macCount;  // main thread: the Mac changeCount the timer last saw
}

+ (instancetype)shared {
  static SVPasteboardSync *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [SVPasteboardSync new]; });
  return shared;
}

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _queue = dispatch_queue_create("simview.pasteboard", DISPATCH_QUEUE_SERIAL);
  _devices = [NSMutableSet set];
  _macCountSeen = [NSMutableDictionary dictionary];
  _fingerprint = [NSMutableDictionary dictionary];
  _deviceCount = [NSMutableDictionary dictionary];
  __weak SVPasteboardSync *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    SVPasteboardSync *strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf->_macCount = NSPasteboard.generalPasteboard.changeCount;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [weakSelf macTick]; }];
    timer.tolerance = 0.2;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  });
  return self;
}

/// Main thread, every 0.5 s: a copy on the Mac goes to every device right away, so iOS's own Paste menu has it too.
- (void)macTick {
  NSInteger count = NSPasteboard.generalPasteboard.changeCount;
  if (count == _macCount) return;
  _macCount = count;
  dispatch_async(_queue, ^{
    for (NSString *udid in self->_devices.allObjects) [self sendMacToDevice:udid];
  });
}

- (void)addDevice:(NSString *)udid {
  dispatch_async(_queue, ^{
    [self->_devices addObject:udid];
    [self sendMacToDevice:udid];
    if (!self->_deviceCount[udid]) {
      NSDictionary *info = [self deviceInfo:udid];
      if (info) self->_deviceCount[udid] = info[@"changeCount"];
    }
  });
}

- (void)removeDevice:(NSString *)udid {
  dispatch_async(_queue, ^{
    [self->_devices removeObject:udid];
    [self->_macCountSeen removeObjectForKey:udid];
    [self->_fingerprint removeObjectForKey:udid];
    [self->_deviceCount removeObjectForKey:udid];
  });
}

- (void)pushToDevice:(NSString *)udid {
  dispatch_sync(_queue, ^{ [self sendMacToDevice:udid]; });
}

- (void)pullFromDeviceIfChanged:(NSString *)udid {
  dispatch_async(_queue, ^{ [self bringDeviceToMac:udid]; });
}

#pragma mark On _queue

/// The device pasteboard's changeCount and item count, or nil.
- (NSDictionary *)deviceInfo:(NSString *)udid {
  NSData *json = SVDevicectl(@[ @"device", @"pasteboard", @"info", @"--device", udid, @"--quiet", @"--json-output", @"-" ], 10);
  NSDictionary *result = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil][@"result"] : nil;
  if (![result isKindOfClass:NSDictionary.class] || !result[@"changeCount"]) return nil;
  return @{@"changeCount" : result[@"changeCount"], @"items" : @([result[@"items"] count])};
}

/// Mac → device, unless the device already has what the Mac holds.
- (void)sendMacToDevice:(NSString *)udid {
  NSInteger count = NSPasteboard.generalPasteboard.changeCount;
  if (_macCountSeen[udid] && _macCountSeen[udid].integerValue == count) return;
  NSString *fingerprint = SVMacFingerprint();
  if (fingerprint.length == 0 || [_fingerprint[udid] isEqualToString:fingerprint]) {
    _macCountSeen[udid] = @(count);
    return;
  }
  NSArray *arguments = @[ @"device", @"pasteboard", @"transfer", @"to", @"--device", udid, @"--data-policy", @"all-resolved", @"--quiet" ];
  if (!SVDevicectl(arguments, 15)) return;
  _macCountSeen[udid] = @(count);
  _fingerprint[udid] = fingerprint;
  NSDictionary *info = [self deviceInfo:udid];
  if (info) _deviceCount[udid] = info[@"changeCount"];  // so leaving the device does not bring it straight back
}

/// Device → Mac, if something was copied on the device since our last transfer.
- (void)bringDeviceToMac:(NSString *)udid {
  NSDictionary *info = [self deviceInfo:udid];
  if (!info || [info[@"items"] integerValue] == 0) return;  // never empty the Mac clipboard
  if ([_deviceCount[udid] isEqual:info[@"changeCount"]]) return;
  NSArray *arguments = @[ @"device", @"pasteboard", @"transfer", @"from", @"--device", udid, @"--data-policy", @"all-resolved", @"--quiet" ];
  if (!SVDevicectl(arguments, 15)) return;
  _deviceCount[udid] = info[@"changeCount"];
  _macCountSeen[udid] = @(NSPasteboard.generalPasteboard.changeCount);
  _fingerprint[udid] = SVMacFingerprint();
}

@end
