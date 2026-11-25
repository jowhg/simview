#import "SVCore.h"
#import "SVPrivate.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// Private but long-standing CALayer API: re-read the same IOSurface after it was drawn into.
@interface CALayer (SVPrivate)
- (void)setContentsChanged;
@end

// A touch that starts within this many points of the screen's border is an edge gesture
// (swipe up from the bottom = Home / App Switcher, down from the top = Control Center…).
static const CGFloat SVEdgeMargin = 12;

// Two-finger scrolling over the screen drags a finger on the device. It touches down only once the gesture has
// moved this share of the screen's short side, so a scroll that barely moves never lands as a tap.
static const CGFloat SVScrollSlop = 0.03;
// The scrolling finger stays this many points inside the screen; reaching that it lifts and touches down again.
static const CGFloat SVScrollInset = 24;
// A mouse wheel's (imprecise) deltas are in lines: points per line, and how long after its last notch it lifts.
static const CGFloat SVWheelLine = 16;
static const NSTimeInterval SVWheelLift = 0.12;

/// The built-in display (screen type 0), asked from the screen adapter as idb does on Xcode 27.
/// Blocks up to 5 s: call off the main thread.
static id<SVSimPrivate> SVMainScreen(id<SVSimPrivate> device) {
  Protocol *adapterProtocol = objc_getProtocol("SimScreenAdapter");
  for (id<SVSimPrivate> port in [[device io] ioPorts]) {
    id<SVSimPrivate> adapter = [port descriptor];
    if (![adapter conformsToProtocol:adapterProtocol]) continue;
    __block NSArray *screens = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [adapter enumerateScreensWithCompletionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                               completionHandler:^(NSArray *list) {
                                 screens = list;
                                 dispatch_semaphore_signal(done);
                               }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    for (id<SVSimPrivate> screen in screens) {
      if ([[screen screenProperties] screenType] == 0) return screen;
    }
  }
  return nil;
}

// macOS virtual key codes (physical positions) → USB HID keyboard usages (page 0x07).
static uint64_t SVHIDUsageForKeyCode(unsigned short keyCode) {
  static const uint8_t map[128] = {
    [0x00] = 0x04, [0x01] = 0x16, [0x02] = 0x07, [0x03] = 0x09, [0x04] = 0x0B, [0x05] = 0x0A, [0x06] = 0x1D,
    [0x07] = 0x1B, [0x08] = 0x06, [0x09] = 0x19, [0x0A] = 0x64, [0x0B] = 0x05, [0x0C] = 0x14, [0x0D] = 0x1A,
    [0x0E] = 0x08, [0x0F] = 0x15, [0x10] = 0x1C, [0x11] = 0x17, [0x12] = 0x1E, [0x13] = 0x1F, [0x14] = 0x20,
    [0x15] = 0x21, [0x16] = 0x23, [0x17] = 0x22, [0x18] = 0x2E, [0x19] = 0x26, [0x1A] = 0x24, [0x1B] = 0x2D,
    [0x1C] = 0x25, [0x1D] = 0x27, [0x1E] = 0x30, [0x1F] = 0x12, [0x20] = 0x18, [0x21] = 0x2F, [0x22] = 0x0C,
    [0x23] = 0x13, [0x24] = 0x28, [0x25] = 0x0F, [0x26] = 0x0D, [0x27] = 0x34, [0x28] = 0x0E, [0x29] = 0x33,
    [0x2A] = 0x31, [0x2B] = 0x36, [0x2C] = 0x38, [0x2D] = 0x11, [0x2E] = 0x10, [0x2F] = 0x37, [0x30] = 0x2B,
    [0x31] = 0x2C, [0x32] = 0x35, [0x33] = 0x2A, [0x35] = 0x29, [0x75] = 0x4C, [0x7B] = 0x50, [0x7C] = 0x4F,
    [0x7D] = 0x51, [0x7E] = 0x52, [0x73] = 0x4A, [0x77] = 0x4D, [0x74] = 0x4B, [0x79] = 0x4E,
    [0x38] = 0xE1, [0x3C] = 0xE5, [0x3B] = 0xE0, [0x3E] = 0xE4, [0x3A] = 0xE2, [0x3D] = 0xE6, [0x39] = 0x39,
  };
  return keyCode < 128 ? map[keyCode] : 0;
}

@implementation SVScreenView {
  id<SVSimPrivate> _device;
  id<SVSimPrivate> _screen;
  NSUUID *_callbackID;
  CALayer *_screenLayer;
  SVDTUHID *_hid;
  NSString *_udid;
  dispatch_queue_t _connectQueue;
  dispatch_queue_t _buttonQueue;
  BOOL _stopped;
  BOOL _pinching;
  SVEdge _edge;
  BOOL _scrolling;       // a scroll gesture is being turned into a finger
  BOOL _scrollTouching;  // …whose finger is down on the device
  NSPoint _scrollStart;  // where that finger touches down, in view points from the top-left
  NSPoint _scrollFinger; // where it is now
  NSTimer *_wheelTimer;  // lifts a mouse wheel's finger once the wheel stops
}

- (instancetype)initWithDevice:(id)device {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 100, 200)])) return nil;
  _device = device;
  _udid = [[(id<SVSimPrivate>)device UDID] UUIDString];
  _connectQueue = dispatch_queue_create("simview.connect", DISPATCH_QUEUE_SERIAL);
  // Leaving SimView for another app: what was copied on the focused device goes to the Mac.
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive:)
                                               name:NSApplicationWillResignActiveNotification object:nil];
  _buttonQueue = dispatch_queue_create("simview.buttons", DISPATCH_QUEUE_SERIAL);
  self.wantsLayer = YES;
  self.layer.backgroundColor = NSColor.blackColor.CGColor;
  _screenLayer = [CALayer layer];
  _screenLayer.frame = self.bounds;
  _screenLayer.contentsGravity = kCAGravityResize;
  _screenLayer.masksToBounds = YES;
  // Layers we add ourselves animate every change by default (≈0.25 s): that is what made zooming lag.
  _screenLayer.actions = @{@"bounds" : NSNull.null, @"position" : NSNull.null, @"frame" : NSNull.null,
                           @"contents" : NSNull.null, @"cornerRadius" : NSNull.null};
  [self.layer addSublayer:_screenLayer];
  [self attachScreen:0];
  [self connectInput:0];
  return self;
}

#pragma mark Screen

- (void)attachScreen:(int)attempt {
  __weak SVScreenView *weakSelf = self;
  id device = _device;
  dispatch_async(_connectQueue, ^{
    SVScreenView *alive = weakSelf;
    if (!alive || alive->_stopped) return;
    alive = nil;  // do not keep the view alive across the blocking call below
    id<SVSimPrivate> screen = SVMainScreen(device);
    dispatch_async(dispatch_get_main_queue(), ^{
      SVScreenView *strongSelf = weakSelf;
      if (!strongSelf || strongSelf->_stopped) return;
      if (screen) [strongSelf subscribe:screen];
      else if (attempt < 120) {  // still booting: try again for up to ~2 minutes
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [weakSelf attachScreen:attempt + 1];
        });
      }
    });
  });
}

- (void)subscribe:(id<SVSimPrivate>)screen {
  _screen = screen;
  _callbackID = [NSUUID UUID];
  _screenLayer.contents = [screen framebufferSurface];
  __weak SVScreenView *weakSelf = self;
  [screen registerScreenCallbacksWithUUID:_callbackID
                            callbackQueue:dispatch_get_main_queue()
                            frameCallback:^{ [weakSelf frameArrived]; }
                  surfacesChangedCallback:^(IOSurface *framebuffer, IOSurface *masked) {
                    [weakSelf surfaceChanged:framebuffer];
                  }
                propertiesChangedCallback:^(id properties) {}];
  _screenReady = YES;
}

- (void)frameArrived {
  _frameCount++;
  [_screenLayer setContentsChanged];
}

- (void)surfaceChanged:(IOSurface *)framebuffer {
  _screenLayer.contents = framebuffer ?: [_screen framebufferSurface];
}

#pragma mark Shape

- (void)setCornerRatio:(CGFloat)cornerRatio {
  if (_cornerRatio == cornerRatio) return;
  _cornerRatio = cornerRatio;
  [self setNeedsLayout:YES];
}

- (void)setMaskImage:(NSImage *)maskImage {
  _maskImage = maskImage;
  if (!maskImage) { self.layer.mask = nil; return; }
  CALayer *mask = [CALayer layer];
  // The mask PDFs are defined in pixels (1206×2622 for an iPhone 17): rasterize at a modest fixed
  // width, plenty for a tile and ~5 MB instead of ~50 MB per screen.
  CGFloat width = 600, height = round(width * maskImage.size.height / MAX(maskImage.size.width, 1));
  NSRect proposed = NSMakeRect(0, 0, width, height);
  mask.contents = (__bridge id)[maskImage CGImageForProposedRect:&proposed context:nil hints:nil];
  mask.contentsGravity = kCAGravityResize;
  mask.actions = @{@"bounds" : NSNull.null, @"position" : NSNull.null, @"frame" : NSNull.null};
  mask.frame = self.layer.bounds;
  self.layer.mask = mask;
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self updateLayerGeometry];
}

- (void)layout {
  [super layout];
  [self updateLayerGeometry];
}

// The live image's layer is sized explicitly, at the same moment as the view. Left to layer
// autoresizing it could keep a stale size while the window was being resized, and slide out of the bezel.
// Rotated, the (always portrait) framebuffer layer keeps its portrait size and is turned about the view's centre.
- (void)updateLayerGeometry {
  NSRect bounds = NSMakeRect(0, 0, NSWidth(self.frame), NSHeight(self.frame));
  BOOL sideways = _quarterTurns % 2 != 0;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _screenLayer.affineTransform = CGAffineTransformIdentity;
  _screenLayer.bounds = sideways ? NSMakeRect(0, 0, NSHeight(bounds), NSWidth(bounds)) : bounds;
  _screenLayer.position = NSMakePoint(NSMidX(bounds), NSMidY(bounds));
  // The layer's y axis points up: a positive angle turns it counter-clockwise on screen.
  _screenLayer.affineTransform = CGAffineTransformMakeRotation(_quarterTurns * M_PI_2);
  self.layer.mask.frame = bounds;
  // Rounded a little less than the real display, so nothing pokes out of the bezel's rounded silhouette
  // while the bezel overlay, cut to the exact shape, still hides the rest.
  CGFloat radius = MIN(NSWidth(bounds), NSHeight(bounds)) * (_cornerRatio > 0 ? _cornerRatio : 0.11);
  self.layer.cornerRadius = radius;
  _screenLayer.cornerRadius = radius;
  [CATransaction commit];
}

- (void)setQuarterTurns:(NSInteger)quarterTurns {
  quarterTurns = ((quarterTurns % 4) + 4) % 4;
  if (_quarterTurns == quarterTurns) return;
  _quarterTurns = quarterTurns;
  [self updateLayerGeometry];
}

#pragma mark Input connection

- (void)connectInput:(int)attempt {
  __weak SVScreenView *weakSelf = self;
  id device = _device;
  dispatch_async(_connectQueue, ^{
    SVScreenView *alive = weakSelf;
    if (!alive || alive->_stopped) return;
    alive = nil;  // do not keep the view alive across the blocking call below
    NSError *error = nil;
    SVDTUHID *hid = [SVDTUHID connectToDevice:device error:&error];
    dispatch_async(dispatch_get_main_queue(), ^{
      SVScreenView *strongSelf = weakSelf;
      if (!strongSelf || strongSelf->_stopped) { [hid disconnect]; return; }
      if (hid) {
        strongSelf->_hid = hid;
        strongSelf->_inputReady = YES;
        dispatch_async(strongSelf->_buttonQueue, ^{ [SVSimulators allowPasteOnDevice:device]; });
        [[SVPasteboardSync shared] addDevice:strongSelf->_udid];
      } else if (attempt < 60) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [weakSelf connectInput:attempt + 1];
        });
      }
    });
  });
}

- (void)stop {
  if (_hid && !_stopped) [[SVPasteboardSync shared] removeDevice:_udid];
  _stopped = YES;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (_screen && _callbackID) [_screen unregisterScreenCallbacksWithUUID:_callbackID];
  _screen = nil;
  _screenLayer.contents = nil;
  [self endScroll];
  [_hid disconnect];
  _hid = nil;
}

#pragma mark Buttons

- (void)pressButton:(SVButton)button {
  [self pressUsagePage:0x0C usage:button];
}

- (void)pressUsagePage:(uint64_t)page usage:(uint64_t)usage {
  SVDTUHID *hid = _hid;
  if (hid) dispatch_async(_buttonQueue, ^{ [hid pressUsagePage:page usage:usage]; });
}

- (void)doublePressHome {
  SVDTUHID *hid = _hid;
  if (hid) dispatch_async(_buttonQueue, ^{ [hid doublePressHome]; });
}

#pragma mark Mouse = finger

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

/// Where the event is on the framebuffer, as 0…1 ratios from its top-left corner. The framebuffer (and the
/// digitizer dtuhidd feeds) stays portrait whatever the orientation: a rotated view's point is turned back.
- (NSPoint)ratioForEvent:(NSEvent *)event {
  return [self ratioForTopLeftPoint:[self topLeftPointForEvent:event]];
}

/// The event's location in view points from the view's top-left corner.
- (NSPoint)topLeftPointForEvent:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  return NSMakePoint(p.x, self.isFlipped ? p.y : NSHeight(self.bounds) - p.y);
}

- (NSPoint)ratioForTopLeftPoint:(NSPoint)p {
  CGFloat x = p.x / NSWidth(self.bounds), y = p.y / NSHeight(self.bounds);
  x = MIN(MAX(x, 0), 1), y = MIN(MAX(y, 0), 1);
  switch (_quarterTurns) {
    case 1: return NSMakePoint(1 - y, x);  // turned counter-clockwise: the framebuffer's top is on the left
    case 2: return NSMakePoint(1 - x, 1 - y);
    case 3: return NSMakePoint(y, 1 - x);  // turned clockwise: its top is on the right
    default: return NSMakePoint(x, y);
  }
}

/// The framebuffer's edge a touch starts from (swipe up from the bottom of a landscape screen starts from the
/// portrait framebuffer's left or right edge).
- (SVEdge)edgeForEvent:(NSEvent *)event {
  NSPoint r = [self ratioForEvent:event];
  BOOL sideways = _quarterTurns % 2 != 0;
  CGFloat width = sideways ? NSHeight(self.bounds) : NSWidth(self.bounds);  // the framebuffer's, in view points
  CGFloat height = sideways ? NSWidth(self.bounds) : NSHeight(self.bounds);
  CGFloat fromLeft = r.x * width, fromTop = r.y * height;
  if (height - fromTop <= SVEdgeMargin) return SVEdgeBottom;
  if (fromTop <= SVEdgeMargin) return SVEdgeTop;
  if (fromLeft <= SVEdgeMargin) return SVEdgeLeft;
  if (width - fromLeft <= SVEdgeMargin) return SVEdgeRight;
  return SVEdgeNone;
}

- (void)touch:(SVTouchPhase)phase event:(NSEvent *)event {
  if (!_hid) return;
  NSPoint r = [self ratioForEvent:event];
  if (phase == SVTouchPhaseStart) {
    _pinching = (event.modifierFlags & NSEventModifierFlagOption) != 0;
    _edge = _pinching ? SVEdgeNone : [self edgeForEvent:event];
  }
  if (_pinching) [_hid touch:phase x:r.x y:r.y x2:1 - r.x y2:1 - r.y];
  else [_hid touch:phase x:r.x y:r.y edge:_edge];
}

- (void)mouseDown:(NSEvent *)event {
  if (self.onActivate) self.onActivate();
  [self.window makeFirstResponder:self];
  [self endScroll];
  [self touch:SVTouchPhaseStart event:event];
}
- (void)mouseDragged:(NSEvent *)event { [self touch:SVTouchPhaseMove event:event]; }
- (void)mouseUp:(NSEvent *)event { [self touch:SVTouchPhaseEnd event:event]; }

#pragma mark Scrolling = finger

// Scrolling over the screen (trackpad or mouse wheel) drags a finger on the device, where the pointer is: the
// content follows the fingers as it does on the Mac (scrollingDelta already follows "natural scrolling"). The
// finger lifts with the gesture's own speed and iOS adds its own momentum: the Mac's momentum events are ignored.

- (void)scrollWheel:(NSEvent *)event {
  if (!_hid) return [super scrollWheel:event];
  if (NSEvent.pressedMouseButtons & 1) return;  // a mouse drag already holds a finger down
  if (event.momentumPhase != NSEventPhaseNone) return;
  CGFloat scale = event.hasPreciseScrollingDeltas ? 1 : SVWheelLine;
  NSSize delta = NSMakeSize(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale);
  switch (event.phase) {
    case NSEventPhaseMayBegin: return;  // fingers resting on the trackpad: touching down could become a tap
    case NSEventPhaseBegan:
      [self endScroll];
      [self beginScrollAt:[self topLeftPointForEvent:event]];
      [self moveScrollBy:delta];
      return;
    case NSEventPhaseChanged:
      if (!_scrolling) [self beginScrollAt:[self topLeftPointForEvent:event]];
      [self moveScrollBy:delta];
      return;
    case NSEventPhaseEnded:
    case NSEventPhaseCancelled:
      if (_scrolling) [self moveScrollBy:delta];
      [self endScroll];
      return;
    default: {  // a mouse wheel: no phases, its finger lifts once the notches stop
      // Slow notches can be a fraction of a line: each still moves the finger past the slop.
      CGFloat length = hypot(delta.width, delta.height);
      CGFloat least = 2 * SVScrollSlop * MIN(NSWidth(self.bounds), NSHeight(self.bounds));
      if (length > 0 && length < least) delta = NSMakeSize(delta.width * least / length, delta.height * least / length);
      if (!_scrolling) [self beginScrollAt:[self topLeftPointForEvent:event]];
      [self moveScrollBy:delta];
      [_wheelTimer invalidate];
      __weak SVScreenView *weakSelf = self;
      _wheelTimer = [NSTimer scheduledTimerWithTimeInterval:SVWheelLift repeats:NO block:^(NSTimer *timer) {
        [weakSelf endScroll];
      }];
      return;
    }
  }
}

/// The area the scrolling finger stays in, in view points from the top-left.
- (NSRect)scrollArea {
  CGFloat inset = MIN(SVScrollInset, MIN(NSWidth(self.bounds), NSHeight(self.bounds)) / 4);
  return NSInsetRect(NSMakeRect(0, 0, NSWidth(self.bounds), NSHeight(self.bounds)), inset, inset);
}

static NSPoint SVClamp(NSPoint p, NSRect r) {
  return NSMakePoint(MIN(MAX(p.x, NSMinX(r)), NSMaxX(r)), MIN(MAX(p.y, NSMinY(r)), NSMaxY(r)));
}

- (void)sendScrollFinger:(SVTouchPhase)phase {
  NSPoint r = [self ratioForTopLeftPoint:_scrollFinger];
  [_hid touch:phase x:r.x y:r.y edge:SVEdgeNone];  // never an edge gesture, even near the bottom
}

- (void)beginScrollAt:(NSPoint)point {
  _scrolling = YES;
  _scrollTouching = NO;
  _scrollStart = _scrollFinger = SVClamp(point, [self scrollArea]);
}

- (void)moveScrollBy:(NSSize)delta {
  if (!_scrolling || (delta.width == 0 && delta.height == 0)) return;
  _scrollFinger.x += delta.width;
  _scrollFinger.y += delta.height;
  if (!_scrollTouching) {
    CGFloat slop = SVScrollSlop * MIN(NSWidth(self.bounds), NSHeight(self.bounds));
    if (hypot(_scrollFinger.x - _scrollStart.x, _scrollFinger.y - _scrollStart.y) < slop) return;
    NSPoint here = _scrollFinger;
    _scrollFinger = _scrollStart;
    [self sendScrollFinger:SVTouchPhaseStart];
    _scrollFinger = here;
    _scrollTouching = YES;
  }
  NSRect area = [self scrollArea];
  if (NSPointInRect(_scrollFinger, area)) return [self sendScrollFinger:SVTouchPhaseMove];
  // The finger reached the screen's border: lift it there and touch down again on the far side, room to go on.
  NSPoint overshoot = _scrollFinger;
  _scrollFinger = SVClamp(_scrollFinger, area);
  [self sendScrollFinger:SVTouchPhaseMove];
  [self sendScrollFinger:SVTouchPhaseEnd];
  NSPoint restart = _scrollFinger;
  if (overshoot.y < NSMinY(area)) restart.y = NSMinY(area) + NSHeight(area) * 0.75;
  else if (overshoot.y > NSMaxY(area)) restart.y = NSMinY(area) + NSHeight(area) * 0.25;
  if (overshoot.x < NSMinX(area)) restart.x = NSMinX(area) + NSWidth(area) * 0.75;
  else if (overshoot.x > NSMaxX(area)) restart.x = NSMinX(area) + NSWidth(area) * 0.25;
  _scrollTouching = NO;
  _scrollStart = _scrollFinger = restart;
}

- (void)endScroll {
  [_wheelTimer invalidate];
  _wheelTimer = nil;
  if (_scrolling && _scrollTouching && _hid) [self sendScrollFinger:SVTouchPhaseEnd];
  _scrolling = _scrollTouching = NO;
}

#pragma mark Cmd shortcuts = the device's

// Cmd+<key> reaches the simulator as its hardware keyboard's Cmd+<key>, like in the old Simulator.app. SimView's
// own menu shortcuts are resolved by AppKit first; the Edit menu's items arrive here as the actions below.

typedef NS_ENUM(NSInteger, SVShortcut) { SVShortcutOther, SVShortcutPaste, SVShortcutCopy };

/// Sends Cmd(+Shift)+usage. A paste first brings the Mac clipboard over and lets every app read it (see
/// allowPasteOnDevice:); a copy or cut then sends what the device copied to the Mac.
- (void)sendCommandKey:(uint64_t)usage shift:(BOOL)shift kind:(SVShortcut)kind {
  SVDTUHID *hid = _hid;
  if (!hid || !usage) return;
  id device = _device;
  NSString *udid = _udid;
  dispatch_async(_buttonQueue, ^{
    if (kind == SVShortcutPaste) {
      [[SVPasteboardSync shared] pushToDevice:udid];
      [SVSimulators allowPasteOnDevice:device];
    }
    [hid key:0xE3 down:YES];
    if (shift) [hid key:0xE1 down:YES];
    usleep(50 * 1000);
    [hid key:usage down:YES];
    usleep(50 * 1000);
    [hid key:usage down:NO];
    usleep(30 * 1000);
    if (shift) [hid key:0xE1 down:NO];
    [hid key:0xE3 down:NO];
    if (kind == SVShortcutCopy) {
      usleep(300 * 1000);  // let the app write the pasteboard
      [[SVPasteboardSync shared] pullFromDeviceIfChanged:udid];
    }
  });
}

/// Leaving the device (another device or the sidebar took the keyboard, or another app came forward): whatever was
/// copied on it, with Cmd+C or iOS's Copy menu, goes to the Mac clipboard.
- (BOOL)resignFirstResponder {
  BOOL resigned = [super resignFirstResponder];
  if (resigned && _hid) [[SVPasteboardSync shared] pullFromDeviceIfChanged:_udid];
  return resigned;
}

- (void)appWillResignActive:(NSNotification *)notification {
  if (_hid && self.window.firstResponder == self) [[SVPasteboardSync shared] pullFromDeviceIfChanged:_udid];
}

/// The physical key behind the shortcut being handled (AZERTY and QWERTZ keep their places), else the QWERTY one.
- (uint64_t)usageOfCurrentShortcutOr:(uint64_t)fallback {
  NSEvent *event = NSApp.currentEvent;
  if (event.type != NSEventTypeKeyDown || !(event.modifierFlags & NSEventModifierFlagCommand)) return fallback;
  return SVHIDUsageForKeyCode(event.keyCode) ?: fallback;
}

- (void)paste:(id)sender { [self sendCommandKey:[self usageOfCurrentShortcutOr:0x19] shift:NO kind:SVShortcutPaste]; }
- (void)copy:(id)sender { [self sendCommandKey:[self usageOfCurrentShortcutOr:0x06] shift:NO kind:SVShortcutCopy]; }
- (void)cut:(id)sender { [self sendCommandKey:[self usageOfCurrentShortcutOr:0x1B] shift:NO kind:SVShortcutCopy]; }
- (void)selectAll:(id)sender { [self sendCommandKey:[self usageOfCurrentShortcutOr:0x04] shift:NO kind:SVShortcutOther]; }
- (void)undo:(id)sender { [self sendCommandKey:[self usageOfCurrentShortcutOr:0x1D] shift:NO kind:SVShortcutOther]; }
- (void)redo:(id)sender { [self sendCommandKey:[self usageOfCurrentShortcutOr:0x1D] shift:YES kind:SVShortcutOther]; }

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
  return _hid != nil;
}

#pragma mark Keyboard

- (void)keyDown:(NSEvent *)event {
  if (event.modifierFlags & NSEventModifierFlagCommand) {
    // A Cmd shortcut no menu claimed: the device's.
    uint64_t usage = SVHIDUsageForKeyCode(event.keyCode);
    if (!usage || !_hid) return [super keyDown:event];
    if (!event.isARepeat) {
      NSString *key = event.charactersIgnoringModifiers.lowercaseString;
      SVShortcut kind = [key isEqualToString:@"v"] ? SVShortcutPaste
                        : ([key isEqualToString:@"c"] || [key isEqualToString:@"x"]) ? SVShortcutCopy : SVShortcutOther;
      [self sendCommandKey:usage shift:(event.modifierFlags & NSEventModifierFlagShift) != 0 kind:kind];
    }
    return;
  }
  uint64_t usage = SVHIDUsageForKeyCode(event.keyCode);
  if (usage && !event.isARepeat) [_hid key:usage down:YES];
}

- (void)keyUp:(NSEvent *)event {
  if (event.modifierFlags & NSEventModifierFlagCommand) return;
  uint64_t usage = SVHIDUsageForKeyCode(event.keyCode);
  if (usage) [_hid key:usage down:NO];
}

- (void)flagsChanged:(NSEvent *)event {
  NSEventModifierFlags flag = 0;
  switch (event.keyCode) {
    case 0x38: case 0x3C: flag = NSEventModifierFlagShift; break;
    case 0x3B: case 0x3E: flag = NSEventModifierFlagControl; break;
    case 0x3A: case 0x3D: flag = NSEventModifierFlagOption; break;
    case 0x39: flag = NSEventModifierFlagCapsLock; break;
    default: return;
  }
  uint64_t usage = SVHIDUsageForKeyCode(event.keyCode);
  if (usage) [_hid key:usage down:(event.modifierFlags & flag) != 0];
}

@end
