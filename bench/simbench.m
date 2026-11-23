// simbench: count how many distinct frames a window actually shows per second, via ScreenCaptureKit.
// Same method for any app, so DeviceHub and simview are measured identically.
// Usage: open -W simbench.app --args <pid> <seconds> <out.json> [title-substring]
//        open -W simbench.app --args --request      (ask for Screen Recording permission)
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface SBCounter : NSObject <SCStreamOutput>
@property (atomic) int complete;
@end

@implementation SBCounter
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)buffer ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, false);
  if (!attachments || CFArrayGetCount(attachments) == 0) return;
  NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
  if ([info[SCStreamFrameInfoStatus] integerValue] == SCFrameStatusComplete) self.complete++;
}
@end

static void finish(NSString *outPath, NSDictionary *result, int code) {
  if (outPath) [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:outPath atomically:YES];
  exit(code);
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    if (argc > 1 && strcmp(argv[1], "--request") == 0) {
      BOOL ok = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess();
      printf("screen recording: %s\n", ok ? "granted" : "requested");
      return 0;
    }
    if (argc < 4) return 2;
    pid_t pid = atoi(argv[1]);
    int seconds = atoi(argv[2]);
    NSString *outPath = @(argv[3]);
    NSString *titleFilter = argc > 4 ? @(argv[4]) : nil;
    if (!CGPreflightScreenCaptureAccess()) finish(outPath, @{@"error" : @"no screen recording permission"}, 3);

    SBCounter *counter = [SBCounter new];
    __block SCStream *stream = nil;
    NSMutableArray<NSNumber *> *perSecond = [NSMutableArray array];

    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
      SCWindow *target = nil;
      for (SCWindow *w in content.windows) {
        if (w.owningApplication.processID != pid || w.windowLayer != 0) continue;
        if (titleFilter && ![w.title isEqualToString:titleFilter]) continue;
        if (!target || w.frame.size.width * w.frame.size.height > target.frame.size.width * target.frame.size.height) target = w;
      }
      if (!target) finish(outPath, @{@"error" : @"window not found"}, 4);

      SCStreamConfiguration *config = [SCStreamConfiguration new];
      config.width = (size_t)(target.frame.size.width / 2);   // small capture: we count frames, not pixels
      config.height = (size_t)(target.frame.size.height / 2);
      config.minimumFrameInterval = CMTimeMake(1, 120);
      config.queueDepth = 8;
      config.showsCursor = NO;
      stream = [[SCStream alloc] initWithFilter:[[SCContentFilter alloc] initWithDesktopIndependentWindow:target]
                                  configuration:config
                                       delegate:nil];
      NSError *addError = nil;
      [stream addStreamOutput:counter type:SCStreamOutputTypeScreen
           sampleHandlerQueue:dispatch_queue_create("simbench", DISPATCH_QUEUE_SERIAL) error:&addError];
      [stream startCaptureWithCompletionHandler:^(NSError *startError) {
        if (startError) finish(outPath, @{@"error" : startError.localizedDescription}, 5);
        dispatch_async(dispatch_get_main_queue(), ^{
          counter.complete = 0;
          __block int elapsed = 0;
          [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            [perSecond addObject:@(counter.complete)];
            counter.complete = 0;
            if (++elapsed < seconds) return;
            [timer invalidate];
            [stream stopCaptureWithCompletionHandler:^(NSError *e) {
              NSArray *sorted = [perSecond sortedArrayUsingSelector:@selector(compare:)];
              double sum = 0;
              for (NSNumber *n in perSecond) sum += n.doubleValue;
              finish(outPath, @{
                @"window" : target.title ?: @"",
                @"size" : @[ @(target.frame.size.width), @(target.frame.size.height) ],
                @"perSecond" : perSecond,
                @"mean" : @(sum / perSecond.count),
                @"median" : sorted[sorted.count / 2],
                @"max" : sorted.lastObject,
              }, 0);
            }];
          }];
        });
      }];
    }];
    [NSApp run];
  }
  return 0;
}
