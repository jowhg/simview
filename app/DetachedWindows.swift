import AppKit
import SwiftUI

/// Devices taken out of the row into their own window, like Simulator.app's device windows: the bezel on a
/// transparent background under a floating title bar with the device's name and its buttons. Dragging the title
/// bar moves the window; dragging the bezel resizes it, like a device in the row. The window keeps the device's proportions, can float above every
/// other app (even a full-screen one), and remembers its place.
final class DetachedWindows: NSObject, NSWindowDelegate {
  /// The title bar and the gap that keeps it off the bezel: everything above the device.
  static let barHeight: CGFloat = 44
  static let barGap: CGFloat = 8
  static let titleBarHeight = barHeight + barGap
  static let minWidth: CGFloat = 200
  /// SimView is quitting: windows closing now are not the user putting a device back in the row.
  static var quitting = false

  private unowned let store: Store
  private var windows: [String: DeviceWindow] = [:]

  init(store: Store) { self.store = store }

  /// Opens a window for every detached device that is booted, closes the others.
  func sync() {
    let wanted = Set(store.booted.map(\.id)).intersection(store.detached)
    for id in windows.keys where !wanted.contains(id) { close(id) }
    for id in wanted where windows[id] == nil { open(id) }
  }

  func bringToFront(_ id: String) {
    NSApp.activate()
    windows[id]?.makeKeyAndOrderFront(nil)
  }

  func updatePin(_ id: String) { windows[id]?.pinned = store.pinned.contains(id) }

  // MARK: Opening and closing

  private func open(_ id: String) {
    guard let sim = store.simulators.first(where: { $0.id == id }), sim.naturalSize.height > 0 else { return }
    let window = DeviceWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 400, height: 800)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
    window.udid = id
    window.naturalSize = store.shownNaturalSize(sim)
    window.isReleasedWhenClosed = false
    window.title = sim.name
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.tabbingMode = .disallowed
    window.delegate = self
    window.contentMinSize = window.size(forWidth: Self.minWidth)
    window.contentView = NSHostingView(rootView: DetachedDeviceView(udid: id)
      .environmentObject(store)
      .environmentObject(store.captures))
    window.setFrame(defaultFrame(for: window), display: false)
    window.setFrameAutosaveName("SimView.device.\(id)")  // restores the last position and size, if any
    // The device's proportions, whatever was saved. A frame saved in the other orientation keeps its scale.
    var saved = window.frame
    if (saved.width > saved.height - Self.titleBarHeight) != (window.naturalSize.width > window.naturalSize.height) {
      saved.size.width = saved.height - Self.titleBarHeight
    }
    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
      saved.size.width = min(saved.width, visible.width, window.width(forHeight: visible.height))
    }
    window.setFrame(window.constrainFrameRect(window.fitted(saved), to: window.screen), display: false)
    window.pinned = store.pinned.contains(id)
    windows[id] = window
    window.makeKeyAndOrderFront(nil)
    window.refreshShadow()
  }

  private func close(_ id: String) {
    guard let window = windows[id] else { return }
    window.closingFromCode = true
    window.close()  // windowWillClose does the rest
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? DeviceWindow, let id = window.udid, windows[id] === window else { return }
    windows[id] = nil
    if let view = store.frameView(id) {
      view.stop()
      store.unregister(view)
    }
    window.contentView = nil
    guard !window.closingFromCode, !Self.quitting else { return }
    // Closed by the user: the device goes back to the row. Reopen SimView's main window first if it was closed,
    // or SimView would quit with its last window.
    if !NSApp.windows.contains(where: { !($0 is DeviceWindow) && $0.title == "SimView" && ($0.isVisible || $0.isMiniaturized) }) {
      store.showMainWindow?()
    }
    store.reattach(id)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let id = (notification.object as? DeviceWindow)?.udid else { return }
    if store.active != id { store.active = id }  // the Device menu and its shortcuts act on this device
    store.frameView(id)?.focus()
  }

  // MARK: Size

  /// Keeps the device's proportions while the window is resized from its edges.
  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    guard let window = sender as? DeviceWindow, !window.styleMask.contains(.fullScreen) else { return frameSize }
    return window.size(forWidth: frameSize.width)
  }

  func windowDidEndLiveResize(_ notification: Notification) { (notification.object as? DeviceWindow)?.refreshShadow() }

  /// Dragging the bezel: the window follows the side or corner being pulled, the opposite one stays put (a side:
  /// the window stays centred across it, and keeps its top when pulled sideways).
  func resize(_ id: String, toWidth width: CGFloat, sides: (x: Int, y: Int)) {
    guard let window = windows[id], !window.styleMask.contains(.fullScreen) else { return }
    let maxWidth = window.screen.map { min($0.visibleFrame.width, window.width(forHeight: $0.visibleFrame.height)) }
      ?? .greatestFiniteMagnitude
    let size = window.size(forWidth: min(max(width, Self.minWidth), maxWidth))
    let old = window.frame
    let x = sides.x > 0 ? old.minX : sides.x < 0 ? old.maxX - size.width : old.midX - size.width / 2
    let y = sides.y < 0 ? old.minY : old.maxY - size.height  // flipped sides: -1 = top, so the bottom stays
    window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    window.refreshShadow()
  }

  /// The device turned: the window takes its new shape at the same scale, around the same centre.
  func orientationChanged(_ id: String) {
    guard let window = windows[id], let sim = store.simulators.first(where: { $0.id == id }) else { return }
    let old = window.naturalSize, new = store.shownNaturalSize(sim)
    guard old != new else { return }
    window.naturalSize = new
    window.contentMinSize = window.size(forWidth: Self.minWidth)
    guard !window.styleMask.contains(.fullScreen) else { return }
    var width = window.frame.width * new.width / max(old.width, 1)
    if let visible = window.screen?.visibleFrame {
      width = min(width, visible.width, window.width(forHeight: visible.height))
    }
    let size = window.size(forWidth: max(width, Self.minWidth))
    let frame = window.frame
    window.setFrame(window.constrainFrameRect(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                                     width: size.width, height: size.height), to: window.screen),
                    display: true)
    window.refreshShadow()
  }

  /// Double-click on the bezel: back to the default size, under the same top centre.
  func resetSize(_ id: String) {
    guard let window = windows[id], !window.styleMask.contains(.fullScreen) else { return }
    let size = defaultFrame(for: window).size
    let old = window.frame
    window.setFrame(window.constrainFrameRect(NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height,
                                                     width: size.width, height: size.height), to: window.screen),
                    display: true, animate: true)
    window.refreshShadow()
  }

  /// At most 80 % of the screen's height, at most the device's natural size; at the right of the screen.
  private func defaultFrame(for window: DeviceWindow) -> NSRect {
    let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let height = min(visible.height * 0.8, window.naturalSize.height + Self.titleBarHeight)
    let size = window.size(forWidth: max(window.width(forHeight: height), Self.minWidth))
    return NSRect(x: visible.maxX - size.width - 40, y: visible.midY - size.height / 2, width: size.width, height: size.height)
  }
}

/// A detached device's window.
final class DeviceWindow: NSWindow {
  var udid: String?
  var naturalSize = CGSize(width: 1, height: 2)
  var closingFromCode = false

  /// Above every other window, on every Space, full-screen apps' included.
  var pinned = false {
    didSet {
      level = pinned ? .floating : .normal
      collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
    }
  }

  func size(forWidth width: CGFloat) -> NSSize {
    NSSize(width: width, height: (DetachedWindows.titleBarHeight + width * naturalSize.height / max(naturalSize.width, 1)).rounded())
  }

  func width(forHeight height: CGFloat) -> CGFloat {
    (height - DetachedWindows.titleBarHeight) * naturalSize.width / max(naturalSize.height, 1)
  }

  /// The same width and top edge, at the device's proportions.
  func fitted(_ frame: NSRect) -> NSRect {
    let size = size(forWidth: max(frame.width, DetachedWindows.minWidth))
    return NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
  }

  /// The shadow follows the bezel's shape, which is drawn asynchronously: recompute it once it is there.
  func refreshShadow() {
    for delay in [0.1, 0.4] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.invalidateShadow() }
    }
  }
}

// MARK: - Content

struct DetachedDeviceView: View {
  @EnvironmentObject private var store: Store
  let udid: String

  var body: some View {
    GeometryReader { proxy in
      let inset = bezelInsets(width: proxy.size.width)
      VStack(spacing: DetachedWindows.barGap) {
        DetachedTitleBar(udid: udid)
          .frame(height: DetachedWindows.barHeight)
          .padding(.leading, inset.leading)
          .padding(.trailing, inset.trailing)
        DeviceTile(udid: udid, store: store, quarterTurns: store.orientation(udid).quarterTurns, detached: true)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .ignoresSafeArea()
  }

  /// The room the side buttons take left and right of the bezel, at this width: the title bar lines up with
  /// the bezel itself.
  private func bezelInsets(width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
    guard let sim = store.simulators.first(where: { $0.id == udid }), let info = store.infos[udid] else { return (0, 0) }
    let natural = store.shownNaturalSize(sim)
    guard natural.width > 0 else { return (0, 0) }
    let p = SVDeviceFrameView.devicePadding(for: info)
    // Counter-clockwise quarter turns: the portrait top ends up on the left, and so on.
    let (left, right): (CGFloat, CGFloat) = switch store.orientation(udid).quarterTurns {
    case 1: (p.top, p.bottom)
    case 2: (p.right, p.left)
    case 3: (p.bottom, p.top)
    default: (p.left, p.right)
    }
    let scale = width / natural.width
    return (left * scale, right * scale)
  }
}

/// Simulator.app's title bar: the device's name and OS on the left, its buttons on the right. The buttons
/// give way to a menu when the window is narrow.
struct DetachedTitleBar: View {
  @EnvironmentObject private var store: Store
  let udid: String

  var body: some View {
    let sim = store.simulators.first { $0.id == udid }
    HStack(spacing: 6) {
      Color.clear.frame(width: 72)  // the window's close / minimise / zoom buttons
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          title(sim)
          Spacer(minLength: 4)
          buttons
        }
        HStack(spacing: 6) {
          Spacer(minLength: 0)
          busyIndicator
          buttons
        }
        HStack(spacing: 6) {
          Spacer(minLength: 0)
          if let state = store.recording[udid] { RecordingBadge(state: state) } else { busyIndicator }
          menu
        }
      }
    }
    .padding(.trailing, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .modifier(TitleBarBackground(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
    .modifier(MovesWindow())
  }

  private func title(_ sim: Simulator?) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(sim?.name ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
      if let state = store.recording[udid] {
        RecordingBadge(state: state)
      } else {
        Text(store.busy[udid] ?? sim?.runtime ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .fixedSize()
  }

  /// Something running on the device (an install, photos being added…), when there is no room for its label.
  @ViewBuilder private var busyIndicator: some View {
    if let label = store.busy[udid] { ProgressView().controlSize(.small).help(label) }
  }

  private var buttons: some View {
    let pinned = store.pinned.contains(udid)
    return HStack(spacing: 0) {
      DeviceButton("house", "Home", "⇧⌘H") { store.home(udid) }
      DeviceButton("square.stack.3d.up", "App Switcher", "⌃⇧⌘H") { store.appSwitcher(udid) }
      groupDivider
      DeviceButton("rotate.left", "Rotate Left", "⌘←") { store.rotate(udid, clockwise: false) }
      DeviceButton("circle.lefthalf.filled", "Toggle Appearance", "⇧⌘A") { store.toggleAppearance(udid) }
      groupDivider
      DeviceButton("camera", "Take Screenshot", "⌘S") { store.screenshot(udid) }
      if let sim = store.simulators.first(where: { $0.id == udid }) { RecordButton(sim: sim, compact: false) }
      groupDivider
      DeviceButton(pinned ? "pin.fill" : "pin", pinned ? "Don't Keep on Top" : "Keep on Top", "⌥⌘T") {
        store.togglePinned(udid)
      }
      .foregroundStyle(pinned ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
      DeviceButton("arrow.down.right.and.arrow.up.left.rectangle", "Reattach to SimView", "⇧⌘D") { store.reattach(udid) }
    }
    .fixedSize()
  }

  /// Between kinds of actions: navigation, the device, captures, the window.
  private var groupDivider: some View { Divider().frame(height: 16).padding(.horizontal, 4) }

  private var menu: some View {
    Menu {
      Button("Home") { store.home(udid) }
      Button("App Switcher") { store.appSwitcher(udid) }
      Divider()
      Button("Rotate Left") { store.rotate(udid, clockwise: false) }
      Button("Rotate Right") { store.rotate(udid, clockwise: true) }
      Button("Toggle Appearance") { store.toggleAppearance(udid) }
      Divider()
      Button("Take Screenshot") { store.screenshot(udid) }
      Button(store.isRecording(udid) ? "Stop Recording" : "Record Video") { store.toggleRecording(udid) }
      Divider()
      Toggle("Keep on Top", isOn: Binding(get: { store.pinned.contains(udid) }, set: { _ in store.togglePinned(udid) }))
      Button("Reattach to SimView") { store.reattach(udid) }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

/// Dragging this view moves its window (the title bar: the bezel resizes the device instead).
struct MovesWindow: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.gesture(WindowDragGesture())
    } else {
      content
    }
  }
}

/// The floating title bar: Liquid Glass where there is some, the title bar material before.
struct TitleBarBackground<S: InsettableShape>: ViewModifier {
  let shape: S

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content
        .background(TitleBarMaterial())
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
  }
}

/// The title bar's own material, translucent over what is behind the window.
struct TitleBarMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.material = .titlebar
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
