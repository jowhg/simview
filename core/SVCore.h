// SimView core: everything that touches private simulator APIs, exposed to the SwiftUI app.
#import <Cocoa/Cocoa.h>
#import "dtuhid.h"

NS_ASSUME_NONNULL_BEGIN

/// A snapshot of one simulator.
@interface SVSimulatorInfo : NSObject
@property (nonatomic, readonly) NSString *udid;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *runtimeName;
@property (nonatomic, readonly) NSString *state;  // "Booted", "Shutdown", "Booting", "Shutting Down"…
@property (nonatomic, readonly) BOOL booted;
@property (nonatomic, readonly) NSString *productFamily;  // "iPhone", "iPad", "Apple Watch"…
/// False when it can't boot: its iOS runtime was removed, or this Xcode no longer knows its device type.
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly, nullable) NSString *unavailableReason;  // CoreSimulator's, when not available
@property (nonatomic, readonly, nullable) NSString *chromeIdentifier;
@property (nonatomic, readonly) CGSize screenPoints;  // main screen in points
@property (nonatomic, readonly, nullable) NSString *screenMaskPath;  // device type's framebufferMask PDF (rounded corners)
@property (nonatomic, readonly) id device;            // CoreSimulator SimDevice
@end

@interface SVSimulators : NSObject
/// Every simulator in the default device set, sorted by name.
+ (NSArray<SVSimulatorInfo *> *)all;
/// phys_footprint summed over each booted simulator's process tree (its launchd_sim and descendants),
/// keyed by UDID. The figure Activity Monitor and `simslim measure` report.
+ (NSDictionary<NSString *, NSNumber *> *)memoryFootprintByUDID;
/// iOS 27 makes an app ask before it reads what another app copied, and everything the Mac copies reaches the
/// simulator that way (its dtpasteboardd mirrors the Mac clipboard). A real keyboard's Cmd+V is signed and skips
/// the question; dtuhidd's is not, so the paste is refused silently (system apps) or stopped by an "Allow Paste"
/// alert. This sets "Paste from Other Apps" to Allow for every app installed on the simulator, in its TCC database.
/// About 10 ms: call it before each Cmd+V. Returns how many apps changed, or -1 if the database was not updated.
+ (NSInteger)allowPasteOnDevice:(id)device;
@end

/// Keeps the Mac clipboard and each simulator's in step, like Simulator.app's "Automatically Sync Pasteboard".
/// Xcode 27 only syncs the devices DeviceHub is showing, so SimView does it itself, with `devicectl device pasteboard
/// transfer`. Mac → device: when the Mac clipboard changes, and before each Cmd+V. Device → Mac: after Cmd+C/Cmd+X
/// on the device, and when you leave it (click another device, switch to another app).
@interface SVPasteboardSync : NSObject
+ (instancetype)shared;
- (void)addDevice:(NSString *)udid;
- (void)removeDevice:(NSString *)udid;
/// Mac → device now if the Mac clipboard changed since the device last got it. Blocks (~0.1 s when it transfers).
- (void)pushToDevice:(NSString *)udid;
/// Device → Mac, in the background, if something was copied on the device since.
- (void)pullFromDeviceIfChanged:(NSString *)udid;
@end

/// A simulator's live screen: framebuffer straight from CoreSimulator, mouse/keyboard to dtuhidd.
@interface SVScreenView : NSView
- (instancetype)initWithDevice:(id)device NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, copy, nullable) void (^onActivate)(void);
@property (nonatomic, readonly) BOOL screenReady;
@property (nonatomic, readonly) BOOL inputReady;
/// Frames received from the simulator and applied to the layer so far.
@property (nonatomic, readonly) NSUInteger frameCount;
/// Counter-clockwise quarter turns the screen is shown at (0–3). The framebuffer itself stays portrait when the
/// device rotates: the view turns it, and maps mouse input back to the framebuffer's (portrait) coordinates.
@property (nonatomic) NSInteger quarterTurns;
/// Alpha mask giving the screen its real shape (rounded corners).
@property (nonatomic, strong, nullable) NSImage *maskImage;
/// Corner radius of the live screen, as a fraction of its short side (0: the default, 0.11).
@property (nonatomic) CGFloat cornerRatio;
- (void)pressButton:(SVButton)button;
- (void)pressUsagePage:(uint64_t)page usage:(uint64_t)usage;
- (void)doublePressHome;
- (void)stop;
@end

/// The device as DeviceHub draws it: Xcode's DeviceKit chrome (bezel, side buttons) around the
/// live screen, scaled to whatever frame it is given.
@interface SVDeviceFrameView : NSView
/// The device's size in portrait (swap width and height for a landscape orientation).
+ (CGSize)naturalSizeForSimulator:(SVSimulatorInfo *)simulator NS_SWIFT_NAME(naturalSize(for:));
/// Room around the bezel for the side buttons, in portrait natural points (part of the natural size).
+ (NSEdgeInsets)devicePaddingForSimulator:(SVSimulatorInfo *)simulator NS_SWIFT_NAME(devicePadding(for:));
/// Diagnostics: drawRect calls so far, and frame views currently alive.
+ (NSUInteger)drawCount;
+ (NSInteger)liveCount;
- (instancetype)initWithSimulator:(SVSimulatorInfo *)simulator;
@property (nonatomic, readonly) NSString *udid;
@property (nonatomic, readonly) SVScreenView *screenView;
@property (nonatomic) BOOL active;
@property (nonatomic, copy, nullable) void (^onActivate)(void);
/// Dragging the bezel: the width (points) the user is pulling the device to.
@property (nonatomic, copy, nullable) void (^onResize)(CGFloat width);
/// Double-click on the bezel: back to the shared size.
@property (nonatomic, copy, nullable) void (^onResetSize)(void);
/// While the bezel is being dragged: the side or corner grabbed, -1, 0 or +1 on each axis (y: -1 = top).
@property (nonatomic, readonly) NSInteger resizeSideX;
@property (nonatomic, readonly) NSInteger resizeSideY;
/// Counter-clockwise quarter turns the whole device (bezel and screen) is drawn at: 0 portrait, 1 landscape left,
/// 2 upside down, 3 landscape right. The view then expects a frame with the swapped aspect ratio when odd.
@property (nonatomic) NSInteger quarterTurns;
/// Files dragged over the device: whether it takes them (the device lights up), and what to do once dropped.
@property (nonatomic, copy, nullable) BOOL (^canDropFiles)(NSArray<NSURL *> *urls);
@property (nonatomic, copy, nullable) void (^onDropFiles)(NSArray<NSURL *> *urls);
- (void)focus;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
