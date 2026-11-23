// SVDTUHID: send touches, buttons and keys to a booted simulator through Xcode 27's dtuhidd daemon.
//
// Since Xcode 27 the guest ignores the legacy Indigo HID port once dtuhidd is active (it is as soon
// as DeviceHub attaches). Input instead goes, as plain-XPC dictionaries, to dtuhidd's
// "com.apple.coredevice.feature.remote.hid.digitizer" service inside the simulator.
// Wire format and connection recipe follow idb's DTUHID transport (meta/idb, MIT).
#import <Foundation/Foundation.h>

typedef NS_ENUM(uint64_t, SVTouchPhase) {
  SVTouchPhaseStart = 0,
  SVTouchPhaseMove = 1,
  SVTouchPhaseEnd = 2,
};

// The screen edge a touch starts from. iOS needs it to recognise system edge gestures
// (swipe up from the bottom for Home / App Switcher, down from the top for Control Center).
typedef NS_ENUM(uint64_t, SVEdge) {
  SVEdgeNone = 0,
  SVEdgeTop = 1,
  SVEdgeLeft = 2,
  SVEdgeBottom = 3,
  SVEdgeRight = 4,
};

// HID consumer-page (0x0C) usages for hardware buttons.
typedef NS_ENUM(uint64_t, SVButton) {
  SVButtonHome = 0x40,
  SVButtonLock = 0x30,
  SVButtonSiri = 0xCF,
  SVButtonVolumeUp = 0xE9,
  SVButtonVolumeDown = 0xEA,
};

NS_ASSUME_NONNULL_BEGIN

@interface SVDTUHID : NSObject

/// Connects to the simulator's digitizer service and waits for dtuhidd to answer a barrier.
/// `device` is a CoreSimulator SimDevice.
+ (nullable instancetype)connectToDevice:(id)device error:(NSError * _Nullable * _Nullable)error;

/// One finger. x and y are 0..1 ratios of the screen, origin top-left.
- (void)touch:(SVTouchPhase)phase x:(double)x y:(double)y;

/// One finger starting from a screen edge (send the same edge for every phase of the contact).
- (void)touch:(SVTouchPhase)phase x:(double)x y:(double)y edge:(SVEdge)edge;

/// Two quick Home presses: opens the App Switcher.
- (void)doublePressHome;

/// Two fingers (pinch / rotate).
- (void)touch:(SVTouchPhase)phase x:(double)x y:(double)y x2:(double)x2 y2:(double)y2;

/// Press and release a hardware button.
- (void)pressButton:(SVButton)button;

/// Press and release any HID button by usage page and usage (e.g. the Action button: 0x0B / 0x2D).
- (void)pressUsagePage:(uint64_t)page usage:(uint64_t)usage;

/// A USB HID keyboard usage (page 0x07), down or up.
- (void)key:(uint64_t)usage down:(BOOL)down;

/// One edge of a button press, for presses held longer than a tap.
- (void)buttonUsagePage:(uint64_t)page usage:(uint64_t)usage down:(BOOL)down;

/// YES once the connection to dtuhidd was invalidated or interrupted (simulator rebooted, daemon
/// restarted): reconnect before sending more.
@property (atomic, readonly) BOOL invalid;

- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
