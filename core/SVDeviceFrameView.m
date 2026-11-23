#import "SVCore.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Chrome (Xcode's DeviceKit device frame)

/// One clickable hardware button drawn on the chrome (volume, power, action…).
@interface SVChromeButton : NSObject
@property (nonatomic) NSRect rect;  // natural coordinates
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, strong) NSImage *imageDown;
@property (nonatomic) BOOL onTop;
@property (nonatomic) uint64_t usagePage;
@property (nonatomic) uint64_t usage;
@end
@implementation SVChromeButton
@end

/// Parsed DeviceKit chrome bundle plus the geometry of one device inside it.
@interface SVChrome : NSObject
@property (nonatomic, strong) NSDictionary<NSString *, NSImage *> *pieces;  // topLeft, top, …
@property (nonatomic, strong) NSImage *composite;  // the whole bezel in one vector image
@property (nonatomic) NSEdgeInsets sizing;   // bezel thickness around the screen
@property (nonatomic) NSEdgeInsets padding;  // room outside the bezel for side buttons
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic, strong) NSArray<NSDictionary *> *inputs;
@end
@implementation SVChrome

+ (nullable SVChrome *)chromeWithIdentifier:(nullable NSString *)identifier {
  static NSMutableDictionary<NSString *, id> *cache;
  if (!cache) cache = [NSMutableDictionary dictionary];
  if (!identifier) return nil;
  id cached = cache[identifier];
  if (cached) return cached == NSNull.null ? nil : cached;

  NSString *name = identifier.pathExtension.length ? identifier.pathExtension : identifier;  // com.apple….phone11 → phone11
  NSString *resources = [NSString stringWithFormat:@"/Library/Developer/DeviceKit/Chrome/%@.devicechrome/Contents/Resources", name];
  NSData *json = [NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:@"chrome.json"]];
  NSDictionary *spec = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
  NSDictionary *images = spec[@"images"];
  if (!images) { cache[identifier] = NSNull.null; return nil; }

  SVChrome *chrome = [SVChrome new];
  NSMutableDictionary *pieces = [NSMutableDictionary dictionary];
  for (NSString *key in @[ @"topLeft", @"top", @"topRight", @"right", @"bottomRight", @"bottom", @"bottomLeft", @"left", @"screen" ]) {
    NSString *file = images[key];
    NSImage *image = file ? [[NSImage alloc] initWithContentsOfFile:[resources stringByAppendingPathComponent:[file stringByAppendingPathExtension:@"pdf"]]] : nil;
    image.cacheMode = NSImageCacheNever;  // drawn as vectors when stretched, never from a cached bitmap
    if (image) pieces[key] = image;
  }
  if (pieces.count < 8) { cache[identifier] = NSNull.null; return nil; }
  if (!pieces[@"screen"]) {
    pieces[@"screen"] = [NSImage imageWithSize:NSMakeSize(1, 1) flipped:NO drawingHandler:^BOOL(NSRect r) {
      [NSColor.blackColor setFill];
      NSRectFill(r);
      return YES;
    }];
  }
  chrome.pieces = pieces;
  if (images[@"composite"]) {
    chrome.composite = [[NSImage alloc] initWithContentsOfFile:[resources stringByAppendingPathComponent:[images[@"composite"] stringByAppendingPathExtension:@"pdf"]]];
  }
  NSDictionary *sizing = images[@"sizing"], *padding = images[@"devicePadding"];
  chrome.sizing = NSEdgeInsetsMake([sizing[@"topHeight"] doubleValue], [sizing[@"leftWidth"] doubleValue],
                                   [sizing[@"bottomHeight"] doubleValue], [sizing[@"rightWidth"] doubleValue]);
  chrome.padding = NSEdgeInsetsMake([padding[@"top"] doubleValue], [padding[@"left"] doubleValue],
                                    [padding[@"bottom"] doubleValue], [padding[@"right"] doubleValue]);
  chrome.cornerRadius = [spec[@"paths"][@"simpleOutsideBorder"][@"cornerRadiusX"] doubleValue] ?: 60;

  NSMutableArray *inputs = [NSMutableArray array];
  for (NSDictionary *input in spec[@"inputs"]) {
    if (![input[@"type"] isEqual:@"button"] || !input[@"image"]) continue;
    NSMutableDictionary *entry = [input mutableCopy];
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:[resources stringByAppendingPathComponent:[input[@"image"] stringByAppendingPathExtension:@"pdf"]]];
    if (!image) continue;
    entry[@"_image"] = image;
    NSImage *down = input[@"imageDown"] ? [[NSImage alloc] initWithContentsOfFile:[resources stringByAppendingPathComponent:[input[@"imageDown"] stringByAppendingPathExtension:@"pdf"]]] : nil;
    if (down) entry[@"_imageDown"] = down;
    [inputs addObject:entry];
  }
  chrome.inputs = inputs;
  cache[identifier] = chrome;
  return chrome;
}

@end

/// Geometry of a device frame in natural (point) coordinates, origin top-left.
typedef struct {
  CGSize natural;
  NSRect chrome;  // the bezel's outer rectangle
  NSRect screen;
} SVFrameGeometry;

static const NSEdgeInsets SVPlainBezel = {14, 14, 14, 14};

static SVFrameGeometry SVGeometry(SVChrome *chrome, CGSize screen) {
  NSEdgeInsets sizing = chrome ? chrome.sizing : SVPlainBezel;
  NSEdgeInsets padding = chrome ? chrome.padding : (NSEdgeInsets){0, 0, 0, 0};
  SVFrameGeometry g;
  g.chrome = NSMakeRect(padding.left, padding.top, screen.width + sizing.left + sizing.right, screen.height + sizing.top + sizing.bottom);
  g.screen = NSMakeRect(NSMinX(g.chrome) + sizing.left, NSMinY(g.chrome) + sizing.top, screen.width, screen.height);
  g.natural = CGSizeMake(NSMaxX(g.chrome) + padding.right, NSMaxY(g.chrome) + padding.bottom);
  return g;
}

/// Portrait natural coordinates → the coordinates of the device drawn `turns` quarter turns counter-clockwise
/// (both origin top-left, y down). `size` is the portrait natural size.
static CGAffineTransform SVTurnTransform(NSInteger turns, CGSize size) {
  switch (turns) {
    case 1: return CGAffineTransformMake(0, -1, 1, 0, 0, size.width);   // top edge to the left
    case 2: return CGAffineTransformMake(-1, 0, 0, -1, size.width, size.height);
    case 3: return CGAffineTransformMake(0, 1, -1, 0, size.height, 0);  // top edge to the right
    default: return CGAffineTransformIdentity;
  }
}

static void SVDraw(NSImage *image, NSRect rect) {
  [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

/// The bezel from its nine slices, one draw per slice. (NSDrawNinePartImage tiles the 1-point edge slices
/// one copy at a time — thousands of draws per frame, seconds per bezel.) Slices are vector PDFs drawn
/// uncached, so stretching them stays crisp and opaque.
static void SVDrawNinePart(NSRect c, NSDictionary<NSString *, NSImage *> *p) {
  CGSize tl = p[@"topLeft"].size, tr = p[@"topRight"].size, bl = p[@"bottomLeft"].size, br = p[@"bottomRight"].size;
  CGFloat top = p[@"top"].size.height, bottom = p[@"bottom"].size.height, left = p[@"left"].size.width, right = p[@"right"].size.width;
  SVDraw(p[@"top"], NSMakeRect(NSMinX(c) + tl.width, NSMinY(c), NSWidth(c) - tl.width - tr.width, top));
  SVDraw(p[@"bottom"], NSMakeRect(NSMinX(c) + bl.width, NSMaxY(c) - bottom, NSWidth(c) - bl.width - br.width, bottom));
  SVDraw(p[@"left"], NSMakeRect(NSMinX(c), NSMinY(c) + tl.height, left, NSHeight(c) - tl.height - bl.height));
  SVDraw(p[@"right"], NSMakeRect(NSMaxX(c) - right, NSMinY(c) + tr.height, right, NSHeight(c) - tr.height - br.height));
  SVDraw(p[@"topLeft"], NSMakeRect(NSMinX(c), NSMinY(c), tl.width, tl.height));
  SVDraw(p[@"topRight"], NSMakeRect(NSMaxX(c) - tr.width, NSMinY(c), tr.width, tr.height));
  SVDraw(p[@"bottomLeft"], NSMakeRect(NSMinX(c), NSMaxY(c) - bl.height, bl.width, bl.height));
  SVDraw(p[@"bottomRight"], NSMakeRect(NSMaxX(c) - br.width, NSMaxY(c) - br.height, br.width, br.height));
}

#pragma mark - Image view: shows a pre-rendered bitmap as its layer contents, never draws itself

@interface SVImageView : NSView
- (void)setImage:(CGImageRef)image;
@end

@implementation SVImageView {
  CGImageRef _image;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    self.layer.contentsGravity = kCAGravityResize;
  }
  return self;
}
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {}
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)setImage:(CGImageRef)image {
  if (image) CGImageRetain(image);
  if (_image) CGImageRelease(_image);
  _image = image;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.layer.contents = (__bridge id)image;
  [CATransaction commit];
}
- (void)dealloc {
  if (_image) CGImageRelease(_image);
}
@end

#pragma mark - Device frame

/// The display's corner radius as a fraction of its short side, read from the device type's framebufferMask:
/// how far along the top-left diagonal the mask turns opaque, for a circular corner r·(1 − 1/√2). A little under
/// it (measured: iPhones ≈ 0.15, iPad mini ≈ 0.06, other iPads ≈ 0.03; Apple's continuous corners bend earlier
/// than a circle), so the bezel overlay always covers the corners.
/// 0 when there is no mask.
static CGFloat SVCornerRatio(NSImage *mask) {
  if (!mask || mask.size.width <= 0 || mask.size.height <= 0) return 0;
  NSInteger w = 600, h = (NSInteger)round(w * mask.size.height / mask.size.width);
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
                                                             samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                              colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  if (!rep) return 0;
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [mask drawInRect:NSMakeRect(0, 0, w, h)];
  [NSGraphicsContext restoreGraphicsState];
  NSInteger shortSide = MIN(w, h), d = 0;
  while (d < shortSide / 2 && [rep colorAtX:d y:d].alphaComponent < 0.5) d++;
  if (d >= shortSide / 2) return 0;
  return 0.75 * d / (1 - M_SQRT1_2) / shortSide;
}

static NSUInteger SVDrawCount;
static NSInteger SVLiveCount;

@implementation SVDeviceFrameView {
  SVChrome *_chrome;
  SVFrameGeometry _geometry;
  NSArray<SVChromeButton *> *_buttons;
  SVChromeButton *_pressed;
  SVImageView *_backView;   // side buttons that tuck under the bezel: behind the screen
  SVImageView *_frontView;  // the bezel, cut to the screen's exact shape, over the live screen
  SVImageView *_dropView;   // lights the screen up while files are dragged over the device
  BOOL _dropAccepted;
  CGAffineTransform _turn;  // portrait natural coordinates → displayed natural coordinates
  CFTimeInterval _turnedAt;
  NSImage *_screenMask;     // device type's framebufferMask: opaque where the screen shows
  CGFloat _scale;
  NSPoint _origin;
  NSSize _renderedSize;
  CGFloat _renderedBacking;
  NSUInteger _renderGeneration;
  BOOL _resizing;
  int _resizeX, _resizeY;  // -1, 0 or +1: which side of the screen the drag started on
  NSPoint _resizeStart;    // screen coordinates
  CGFloat _resizeStartWidth;
}

+ (NSUInteger)drawCount { return SVDrawCount; }
+ (NSInteger)liveCount { return SVLiveCount; }

+ (CGSize)naturalSizeForSimulator:(SVSimulatorInfo *)simulator {
  return SVGeometry([SVChrome chromeWithIdentifier:simulator.chromeIdentifier], simulator.screenPoints).natural;
}

+ (NSEdgeInsets)devicePaddingForSimulator:(SVSimulatorInfo *)simulator {
  SVChrome *chrome = [SVChrome chromeWithIdentifier:simulator.chromeIdentifier];
  return chrome ? chrome.padding : (NSEdgeInsets){0, 0, 0, 0};
}

- (instancetype)initWithSimulator:(SVSimulatorInfo *)simulator {
  if (!(self = [super initWithFrame:NSMakeRect(0, 0, 200, 400)])) return nil;
  SVLiveCount++;
  self.wantsLayer = YES;
  _udid = simulator.udid;
  _chrome = [SVChrome chromeWithIdentifier:simulator.chromeIdentifier];
  _geometry = SVGeometry(_chrome, simulator.screenPoints);
  _buttons = [self buttonsForChrome:_chrome];

  _backView = [[SVImageView alloc] initWithFrame:self.bounds];
  [self addSubview:_backView];

  _screenView = [[SVScreenView alloc] initWithDevice:simulator.device];
  // No mask on the live layer (a masked layer costs the compositor an offscreen pass every frame):
  // the bezel is drawn over the screen instead, with a hole cut to the screen's real shape.
  _screenMask = simulator.screenMaskPath ? [[NSImage alloc] initWithContentsOfFile:simulator.screenMaskPath] : nil;
  // Measured once per device type (main thread only, like every frame view).
  static NSMutableDictionary<NSString *, NSNumber *> *cornerRatios;
  if (!cornerRatios) cornerRatios = [NSMutableDictionary dictionary];
  if (simulator.screenMaskPath && !cornerRatios[simulator.screenMaskPath]) {
    cornerRatios[simulator.screenMaskPath] = @(SVCornerRatio(_screenMask));
  }
  _screenView.cornerRatio = simulator.screenMaskPath ? cornerRatios[simulator.screenMaskPath].doubleValue : 0;
  __weak SVDeviceFrameView *weakSelf = self;
  _screenView.onActivate = ^{
    SVDeviceFrameView *strongSelf = weakSelf;
    if (strongSelf.onActivate) strongSelf.onActivate();
  };
  [self addSubview:_screenView];

  _dropView = [[SVImageView alloc] initWithFrame:self.bounds];
  _dropView.hidden = YES;
  _dropView.layer.borderWidth = 3;
  [self addSubview:_dropView];

  _frontView = [[SVImageView alloc] initWithFrame:self.bounds];
  [self addSubview:_frontView];
  _turn = CGAffineTransformIdentity;
  [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  return self;
}

- (void)dealloc { SVLiveCount--; }

- (NSArray<SVChromeButton *> *)buttonsForChrome:(SVChrome *)chrome {
  NSMutableArray *buttons = [NSMutableArray array];
  NSRect c = _geometry.chrome;
  for (NSDictionary *input in chrome.inputs) {
    NSImage *image = input[@"_image"];
    NSDictionary *offset = input[@"offsets"][@"normal"];
    CGFloat ox = [offset[@"x"] doubleValue], oy = [offset[@"y"] doubleValue];
    CGSize size = image.size;
    NSString *anchor = input[@"anchor"];
    BOOL trailing = [input[@"align"] isEqual:@"trailing"];
    NSRect rect;
    if ([anchor isEqual:@"left"] || [anchor isEqual:@"right"]) {
      CGFloat x = [anchor isEqual:@"left"] ? NSMinX(c) - size.width + ox : NSMaxX(c) + ox;
      CGFloat y = trailing ? NSMaxY(c) + oy - size.height : NSMinY(c) + oy;  // trailing offsets are negative: inward
      rect = NSMakeRect(x, y, size.width, size.height);
    } else {
      CGFloat y = [anchor isEqual:@"top"] ? NSMinY(c) - size.height + oy : NSMaxY(c) + oy;
      CGFloat x = trailing ? NSMaxX(c) + ox - size.width : NSMinX(c) + ox;
      rect = NSMakeRect(x, y, size.width, size.height);
    }
    SVChromeButton *button = [SVChromeButton new];
    button.rect = rect;
    button.image = image;
    button.imageDown = input[@"_imageDown"];
    button.onTop = [input[@"onTop"] boolValue];
    button.usagePage = [input[@"usagePage"] unsignedLongLongValue];
    button.usage = [input[@"usage"] unsignedLongLongValue];
    [buttons addObject:button];
  }
  return buttons;
}

- (BOOL)isFlipped { return YES; }

#pragma mark Layout and rendering

// Laid out synchronously with every size change (not only when AppKit gets to its layout pass), so the
// screen and the bezel always move together while the window is being resized.
- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self layoutDevice];
}

- (void)layout {
  [super layout];
  [self layoutDevice];
}

- (void)layoutDevice {
  CGSize natural = _quarterTurns % 2 ? CGSizeMake(_geometry.natural.height, _geometry.natural.width) : _geometry.natural;
  _scale = MIN(NSWidth(self.bounds) / natural.width, NSHeight(self.bounds) / natural.height);
  _origin = NSMakePoint((NSWidth(self.bounds) - natural.width * _scale) / 2, (NSHeight(self.bounds) - natural.height * _scale) / 2);
  NSRect screen = CGRectApplyAffineTransform(_geometry.screen, _turn);
  NSRect screenFrame = NSMakeRect(_origin.x + NSMinX(screen) * _scale, _origin.y + NSMinY(screen) * _scale,
                                  NSWidth(screen) * _scale, NSHeight(screen) * _scale);
  if (!NSEqualRects(screenFrame, _screenView.frame)) {
    _screenView.frame = screenFrame;
    [self.window invalidateCursorRectsForView:self];
  }
  if (!NSEqualRects(_dropView.frame, screenFrame)) {
    _dropView.frame = screenFrame;
    _dropView.layer.cornerRadius = MIN(NSWidth(screenFrame), NSHeight(screenFrame)) * (_screenView.cornerRatio ?: 0.11);
  }
  if (!NSEqualRects(_backView.frame, self.bounds)) _backView.frame = self.bounds;
  if (!NSEqualRects(_frontView.frame, self.bounds)) _frontView.frame = self.bounds;
  CGFloat backing = self.window.backingScaleFactor ?: 2;
  if (!NSEqualSizes(_renderedSize, self.bounds.size) || _renderedBacking != backing) {
    if (NSEqualSizes(_renderedSize, NSZeroSize) || CACurrentMediaTime() - _turnedAt < 0.5) {
      // First render, or the new size of a device that just turned: a stretched old bezel would show sideways.
      [self renderChrome];
    } else {
      // While zooming or dragging, the previous bitmap is simply stretched; redraw it sharp once
      // the size has settled instead of on every step.
      [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renderChrome) object:nil];
      [self performSelector:@selector(renderChrome) withObject:nil afterDelay:0.15 inModes:@[ NSRunLoopCommonModes ]];
    }
  }
}

#pragma mark Resizing by dragging the bezel

/// How far along each edge, from a corner of the screen, the bezel counts as that corner: the bezel's rounded
/// corner, so grabbing anywhere on the curve pulls diagonally.
- (CGFloat)cornerReach {
  NSRect s = _screenView.frame;
  CGFloat radius = (_chrome ? _chrome.cornerRadius : _geometry.natural.width * 0.14) * _scale;
  return MIN(radius, MIN(NSWidth(s), NSHeight(s)) / 3);
}

/// Which way a drag starting at `local` (view coordinates, on the bezel) resizes the device: -1, 0 or +1 on
/// each axis (flipped view: y -1 = top). The same zones as the resize cursors.
- (void)resizeSidesAt:(NSPoint)local x:(int *)x y:(int *)y {
  NSRect s = _screenView.frame;
  CGFloat k = [self cornerReach];
  int sx = local.x < NSMinX(s) ? -1 : local.x > NSMaxX(s) ? 1 : 0;
  int sy = local.y < NSMinY(s) ? -1 : local.y > NSMaxY(s) ? 1 : 0;
  // On the top or bottom band near a corner, or the left or right band near a corner: that corner.
  if (sy != 0 && sx == 0) sx = local.x < NSMinX(s) + k ? -1 : local.x > NSMaxX(s) - k ? 1 : 0;
  if (sx != 0 && sy == 0) sy = local.y < NSMinY(s) + k ? -1 : local.y > NSMaxY(s) - k ? 1 : 0;
  if (sx == 0 && sy == 0) sx = 1;
  *x = sx;
  *y = sy;
}

- (void)resetCursorRects {
  if (@available(macOS 15.0, *)) {
    NSRect b = self.bounds, s = _screenView.frame;
    CGFloat k = [self cornerReach];
    CGFloat x0 = NSMinX(b), x1 = NSMinX(s), x2 = NSMinX(s) + k, x3 = NSMaxX(s) - k, x4 = NSMaxX(s), x5 = NSMaxX(b);
    CGFloat y0 = NSMinY(b), y1 = NSMinY(s), y2 = NSMinY(s) + k, y3 = NSMaxY(s) - k, y4 = NSMaxY(s), y5 = NSMaxY(b);
    // Each corner is an L around the screen's corner (the bezel's curve); the edges are what lies between.
    struct { NSRect rect; NSCursorFrameResizePosition position; } zones[] = {
      {NSMakeRect(x0, y0, x2 - x0, y1 - y0), NSCursorFrameResizePositionTopLeft},  // flipped: top = small y
      {NSMakeRect(x0, y1, x1 - x0, y2 - y1), NSCursorFrameResizePositionTopLeft},
      {NSMakeRect(x3, y0, x5 - x3, y1 - y0), NSCursorFrameResizePositionTopRight},
      {NSMakeRect(x4, y1, x5 - x4, y2 - y1), NSCursorFrameResizePositionTopRight},
      {NSMakeRect(x0, y4, x2 - x0, y5 - y4), NSCursorFrameResizePositionBottomLeft},
      {NSMakeRect(x0, y3, x1 - x0, y4 - y3), NSCursorFrameResizePositionBottomLeft},
      {NSMakeRect(x3, y4, x5 - x3, y5 - y4), NSCursorFrameResizePositionBottomRight},
      {NSMakeRect(x4, y3, x5 - x4, y4 - y3), NSCursorFrameResizePositionBottomRight},
      {NSMakeRect(x2, y0, x3 - x2, y1 - y0), NSCursorFrameResizePositionTop},
      {NSMakeRect(x2, y4, x3 - x2, y5 - y4), NSCursorFrameResizePositionBottom},
      {NSMakeRect(x0, y2, x1 - x0, y3 - y2), NSCursorFrameResizePositionLeft},
      {NSMakeRect(x4, y2, x5 - x4, y3 - y2), NSCursorFrameResizePositionRight},
    };
    for (size_t i = 0; i < sizeof zones / sizeof zones[0]; i++) {
      if (NSIsEmptyRect(zones[i].rect)) continue;
      [self addCursorRect:zones[i].rect
                   cursor:[NSCursor frameResizeCursorFromPosition:zones[i].position inDirections:NSCursorFrameResizeDirectionsAll]];
    }
  }
}

- (NSInteger)resizeSideX { return _resizeX; }
- (NSInteger)resizeSideY { return _resizeY; }

- (void)mouseDragged:(NSEvent *)event {
  if (!_resizing || !self.onResize) return;
  // Screen coordinates: a detached device's window resizes (and moves) under the mouse while it drags.
  NSPoint now = NSEvent.mouseLocation;
  CGFloat dx = now.x - _resizeStart.x, dyDown = _resizeStart.y - now.y;  // window y points up
  CGFloat aspect = NSWidth(self.bounds) / MAX(NSHeight(self.bounds), 1);
  CGFloat fromX = _resizeX * dx, fromY = _resizeY * dyDown * aspect;  // both in width units
  CGFloat delta = _resizeX == 0 ? fromY : _resizeY == 0 ? fromX : (fabs(fromX) > fabs(fromY) ? fromX : fromY);
  self.onResize(_resizeStartWidth + delta);
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self setNeedsLayout:YES];
}

/// Draws into a bitmap of `size` points, in natural device coordinates (origin top-left).
static CGImageRef SVNewImage(NSSize size, CGFloat backing, NSPoint origin, CGFloat scale, CGAffineTransform turn,
                             void (^draw)(void)) CF_RETURNS_RETAINED {
  size_t width = (size_t)ceil(size.width * backing), height = (size_t)ceil(size.height * backing);
  if (width == 0 || height == 0 || scale <= 0) return NULL;
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
                                               kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
  CGColorSpaceRelease(space);
  if (!context) return NULL;
  CGContextTranslateCTM(context, 0, height);
  CGContextScaleCTM(context, backing, -backing);
  CGContextTranslateCTM(context, origin.x, origin.y);
  CGContextScaleCTM(context, scale, scale);
  CGContextConcatCTM(context, turn);  // drawn in portrait coordinates, shown turned
  @autoreleasepool {
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    draw();
    [NSGraphicsContext restoreGraphicsState];
  }
  CGImageRef image = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  return image;
}

static void SVDrawButtons(NSArray<SVChromeButton *> *buttons, SVChromeButton *pressed, BOOL onTop) {
  for (SVChromeButton *button in buttons) {
    if (button.onTop != onTop) continue;
    SVDraw(button == pressed && button.imageDown ? button.imageDown : button.image, button.rect);
  }
}

/// One serial queue for every device: bezels render off the main thread, and never two at once (the
/// chrome images are shared between devices of the same model).
static dispatch_queue_t SVRenderQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ queue = dispatch_queue_create("simview.chrome", DISPATCH_QUEUE_SERIAL); });
  return queue;
}

- (void)renderChrome {
  SVDrawCount++;
  NSSize size = self.bounds.size;
  CGFloat backing = self.window.backingScaleFactor ?: 2;
  _renderedSize = size;
  _renderedBacking = backing;
  if (_scale <= 0 || size.width < 1 || size.height < 1) return;

  // Everything the drawing reads is captured here, on the main thread; the drawing itself happens in the
  // background so resizing, zooming or switching layouts never waits for it.
  NSUInteger generation = ++_renderGeneration;
  SVChrome *chrome = _chrome;
  NSRect c = _geometry.chrome, screen = _geometry.screen;
  CGFloat scale = _scale;
  NSPoint origin = _origin;
  CGAffineTransform turn = _turn;
  NSArray<SVChromeButton *> *buttons = _buttons;
  SVChromeButton *pressed = _pressed;
  NSImage *screenMask = _screenMask;
  __weak SVDeviceFrameView *weakSelf = self;

  dispatch_async(SVRenderQueue(), ^{
    // Behind the screen: the side buttons that tuck under the bezel.
    CGImageRef back = SVNewImage(size, backing, origin, scale, turn, ^{
      SVDrawButtons(buttons, pressed, NO);
    });

    // Over the screen: the bezel, with the screen's exact shape (rounded corners, notch) cut out.
    CGImageRef front = SVNewImage(size, backing, origin, scale, turn, ^{
      // Some chromes (e.g. notched models) leave the inside of the bezel transparent: paint the whole device
      // silhouette black first, so anything outside the screen's real shape (notch, corners) is hidden.
      CGFloat outer = chrome ? chrome.cornerRadius : NSWidth(c) * 0.14;
      [NSColor.blackColor setFill];
      [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(c, 1.5, 1.5) xRadius:outer yRadius:outer] fill];
      if (chrome.composite) {
        SVDraw(chrome.composite, c);
      } else if (chrome) {
        SVDrawNinePart(c, chrome.pieces);
      } else {
        [[NSColor colorWithWhite:0.08 alpha:1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:c xRadius:outer yRadius:outer] fill];
      }
      if (screenMask) {
        [screenMask drawInRect:screen fromRect:NSZeroRect operation:NSCompositingOperationDestinationOut fraction:1
                respectFlipped:YES hints:nil];
      } else {
        CGFloat radius = NSWidth(screen) * 0.12;
        [NSGraphicsContext.currentContext setCompositingOperation:NSCompositingOperationClear];
        [[NSBezierPath bezierPathWithRoundedRect:screen xRadius:radius yRadius:radius] fill];
        [NSGraphicsContext.currentContext setCompositingOperation:NSCompositingOperationSourceOver];
      }
      SVDrawButtons(buttons, pressed, YES);
    });

    dispatch_async(dispatch_get_main_queue(), ^{
      SVDeviceFrameView *strongSelf = weakSelf;
      if (strongSelf && strongSelf->_renderGeneration == generation) {  // a newer render supersedes this one
        [strongSelf->_backView setImage:back];
        [strongSelf->_frontView setImage:front];
      }
      if (back) CGImageRelease(back);
      if (front) CGImageRelease(front);
    });
  });
}

#pragma mark Clicks on the frame

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

/// A point in the view → portrait natural coordinates (where the chrome's buttons are defined).
- (NSPoint)toNatural:(NSPoint)p {
  NSPoint shown = NSMakePoint((p.x - _origin.x) / _scale, (p.y - _origin.y) / _scale);
  return CGPointApplyAffineTransform(shown, CGAffineTransformInvert(_turn));
}

- (void)mouseDown:(NSEvent *)event {
  if (self.onActivate) self.onActivate();
  [self focus];
  NSPoint p = [self toNatural:[self convertPoint:event.locationInWindow fromView:nil]];
  for (SVChromeButton *button in _buttons) {
    if (NSPointInRect(p, NSInsetRect(button.rect, -4, -4))) {
      _pressed = button;
      [_screenView pressUsagePage:button.usagePage usage:button.usage];
      [self renderChrome];
      return;
    }
  }
  if (event.clickCount == 2) {
    if (self.onResetSize) self.onResetSize();
    return;
  }
  // Anywhere else on the bezel: start resizing, pulling away from the side (or corner) that was grabbed.
  [self resizeSidesAt:[self convertPoint:event.locationInWindow fromView:nil] x:&_resizeX y:&_resizeY];
  _resizeStart = NSEvent.mouseLocation;
  _resizeStartWidth = NSWidth(self.bounds);
  _resizing = YES;
}

- (void)mouseUp:(NSEvent *)event {
  _resizing = NO;
  if (!_pressed) return;
  _pressed = nil;
  [self renderChrome];
}

- (void)setQuarterTurns:(NSInteger)quarterTurns {
  quarterTurns = ((quarterTurns % 4) + 4) % 4;
  if (_quarterTurns == quarterTurns) return;
  _quarterTurns = quarterTurns;
  _turn = SVTurnTransform(quarterTurns, _geometry.natural);
  _turnedAt = CACurrentMediaTime();
  _screenView.quarterTurns = quarterTurns;
  [self layoutDevice];
  [self renderChrome];
}

#pragma mark Files dropped on the device

- (NSArray<NSURL *> *)draggedFiles:(id<NSDraggingInfo>)sender {
  return [sender.draggingPasteboard readObjectsForClasses:@[ NSURL.class ]
                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}] ?: @[];
}

- (void)showDropHighlight:(BOOL)show {
  if (show) {
    NSColor *accent = NSColor.controlAccentColor;
    _dropView.layer.backgroundColor = [accent colorWithAlphaComponent:0.28].CGColor;
    _dropView.layer.borderColor = accent.CGColor;
  }
  _dropView.hidden = !show;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  NSArray<NSURL *> *urls = [self draggedFiles:sender];
  _dropAccepted = urls.count > 0 && self.onDropFiles && (!self.canDropFiles || self.canDropFiles(urls));
  [self showDropHighlight:_dropAccepted];
  return _dropAccepted ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  return _dropAccepted ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender { [self showDropHighlight:NO]; }
- (void)draggingEnded:(id<NSDraggingInfo>)sender { [self showDropHighlight:NO]; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  [self showDropHighlight:NO];
  NSArray<NSURL *> *urls = [self draggedFiles:sender];
  if (!_dropAccepted || urls.count == 0 || !self.onDropFiles) return NO;
  self.onDropFiles(urls);
  return YES;
}

- (void)focus {
  if (self.window.firstResponder != _screenView) [self.window makeFirstResponder:_screenView];
}

- (void)stop {
  [_screenView stop];
}

@end
