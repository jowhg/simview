import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var store: Store
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
    } detail: {
      DeviceGrid()
    }
    .onAppear { store.showMainWindow = { [openWindow] in openWindow(id: "main") } }
    .navigationTitle("SimView")
    .navigationSubtitle(subtitle)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Picker("Layout", selection: Binding(get: { store.layoutMode },
                                            set: { mode in withAnimation(.easeInOut(duration: 0.25)) { store.layoutMode = mode } })) {
          Label("Full Height", systemImage: "rectangle.expand.vertical").tag(Store.LayoutMode.fullHeight)
          Label("Fit All", systemImage: "rectangle.split.3x1").tag(Store.LayoutMode.fitAll)
        }
        .pickerStyle(.segmented)
        .help("Full height (⌘1) or everything at once (⌘2)")
      }
    }
  }

  private var subtitle: String {
    var parts = [String(localized: "\(store.booted.count) booted")]
    if let name = store.activeName { parts.append(String(localized: "active: \(name)")) }
    return parts.joined(separator: " · ")
  }
}

// MARK: - Sidebar

struct SidebarView: View {
  @EnvironmentObject private var store: Store

  var body: some View {
    // The selection is written back asynchronously: setting it from inside the table's own update
    // is a reentrant NSTableView operation.
    VSplitView {
      List(selection: Binding(get: { store.active }, set: { id in DispatchQueue.main.async { store.active = id } })) {
        Section("Booted") {
          ForEach(store.booted) { SimulatorRow(sim: $0).tag($0.id) }
        }
        // The others, by device family (names like "iPhone" and "iPad" aren't translated).
        ForEach(store.offByFamily, id: \.family) { group in
          Section {
            ForEach(group.simulators) { SimulatorRow(sim: $0) }
          } header: {
            Text(verbatim: group.family)
          }
        }
        if !store.unavailable.isEmpty {
          Section("Unavailable") {
            ForEach(store.unavailable) { SimulatorRow(sim: $0) }
          }
        }
      }
      .listStyle(.sidebar)
      .frame(minHeight: 140, idealHeight: 320)
      CapturesPanel()
        .frame(minHeight: 160, idealHeight: 420)
    }
  }
}

struct SimulatorRow: View {
  @EnvironmentObject private var store: Store
  let sim: Simulator

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(sim.booted ? Color.green : Color.secondary.opacity(0.35))
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(sim.name).lineLimit(1)
            .foregroundStyle(sim.available ? .primary : .secondary)
          if sim.slim?.isSlim == true && !(sim.booted && store.hasSimslim) {  // otherwise the row's slim button shows it
            Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(.green)
          }
          if store.recording[sim.id] != nil {
            Image(systemName: "record.circle.fill").font(.caption2).foregroundStyle(.red)
          }
          if sim.booted && store.detached.contains(sim.id) {
            Image(systemName: "macwindow").font(.caption2).foregroundStyle(.secondary)
              .help("In its own window")
          }
        }
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 4)
      if store.busy[sim.id] != nil {
        ProgressView().controlSize(.small)
      } else if sim.available {
        if !sim.booted && store.hasSimslim {
          // Boots as the setting says (slimmed by default); the context menu offers the other way.
          Button { store.boot(sim.id) } label: {
            Image(systemName: store.slimOnBoot ? "leaf.fill" : "play.fill")
          }
          .buttonStyle(.borderless)
          .help(store.slimOnBoot ? "Boot Slimmed" : "Boot")
        } else {
          if sim.booted && store.hasSimslim, let slim = sim.slim {
            // Green when slimmed: click to go back to standard (reboots); outlined when standard: click to slim down.
            Button { store.toggleSlim(sim) } label: {
              Image(systemName: slim.isSlim ? "leaf.fill" : "leaf")
                .foregroundStyle(slim.isSlim ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(slim.isSlim ? "Slimmed by simslim · click to restore standard (reboots)" : "Slim Down with simslim")
          }
          Button { sim.booted ? store.shutdown(sim.id) : store.boot(sim.id) } label: {
            Image(systemName: sim.booted ? "power" : "play.fill")
          }
          .buttonStyle(.borderless)
          .help(sim.booted ? "Shut Down" : "Boot")
        }
      }
    }
    .help(sim.unavailableReason ?? "")
    .contextMenu {
      if !sim.available {
        EmptyView()
      } else if sim.booted {
        if store.detached.contains(sim.id) {
          Button("Show Window") { store.detach(sim.id) }
          Button("Reattach to SimView") { store.reattach(sim.id) }
        } else {
          Button("Detach into Window") { store.detach(sim.id) }
        }
        Divider()
        Button("Shut Down") { store.shutdown(sim.id) }
        if sim.slim?.isSlim == true {
          Button("Restore Standard (Reboots)") { store.slimOff(sim.id) }
        } else {
          Button("Slim Down with simslim") { store.slimOn(sim.id) }
        }
      } else if store.hasSimslim {
        Button("Boot Slimmed") { store.boot(sim.id, slimmed: true) }
        Button("Boot Standard") { store.boot(sim.id, slimmed: false) }
      } else {
        Button("Boot") { store.boot(sim.id) }
      }
    }
  }

  private var detail: String {
    if let label = store.busy[sim.id] { return label }
    if !sim.available { return sim.unavailableReason ?? String(localized: "Can't boot with this Xcode") }
    guard sim.booted else { return sim.state == "Shutdown" ? sim.runtime : "\(sim.runtime) · \(sim.state)" }
    var parts: [String] = []
    if let memory = sim.memory { parts.append(formatMemory(memory)) }
    if let slim = sim.slim {
      parts.append(slim.isSlim ? String(localized: "slimmed \(slim.disabled)/\(slim.total)") : String(localized: "standard"))
    }
    return parts.isEmpty ? sim.runtime : parts.joined(separator: " · ")
  }
}

// MARK: - Device row

/// Layout of the device row, DeviceHub style: every device as tall as the window allows, one row only.
enum DeviceLayout {
  static let padding: CGFloat = 28       // around the row
  static let spacing: CGFloat = 32       // between devices
  static let headerHeight: CGFloat = 32  // capture and window controls above each device
  static let footerHeight: CGFloat = 58  // name line + controls under each device
  static let minCardWidth: CGFloat = 130  // the controls capsule under a device
}

struct DeviceGrid: View {
  @EnvironmentObject private var store: Store

  var body: some View {
    Group {
      if store.booted.isEmpty {
        ContentUnavailableView {
          Label("No Booted Simulators", systemImage: "iphone.slash")
        } description: {
          Text("Boot a simulator from the sidebar (▶︎).")
        }
      } else if store.docked.isEmpty {
        ContentUnavailableView {
          Label("Every Device Is in Its Own Window", systemImage: "macwindow.on.rectangle")
        } description: {
          Text("Close a device's window (or press ⇧⌘D) to bring it back here.")
        } actions: {
          Button("Reattach All") { store.booted.forEach { store.reattach($0.id) } }
        }
      } else {
        GeometryReader { geometry in
          let fullHeight = max(geometry.size.height - 2 * DeviceLayout.padding - DeviceLayout.headerHeight
                                 - DeviceLayout.footerHeight, 160)
          let heights = deviceHeights(fullHeight: fullHeight, width: geometry.size.width)
          ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: DeviceLayout.spacing) {
              ForEach(store.docked) { DeviceCard(sim: $0, height: heights[$0.id] ?? fullHeight) }
            }
            .padding(DeviceLayout.padding)
            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)  // centred when it fits
          }
          .onAppear { store.fullHeight = fullHeight }
          .onChange(of: fullHeight) { _, height in store.fullHeight = height }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(BehindWindowBlur().ignoresSafeArea())
  }

  /// Each device's height in portrait. Full height: as tall as the window allows (times its own drag-to-shrink
  /// scale). Fit all: the tallest common height at which the whole row fits the window's width. A device in
  /// landscape keeps that scale: its width is that height.
  private func deviceHeights(fullHeight: CGFloat, width: CGFloat) -> [String: CGFloat] {
    let devices = store.docked
    func heights(at height: CGFloat) -> [String: CGFloat] {
      Dictionary(uniqueKeysWithValues: devices.map { ($0.id, height * store.scale(for: $0.id)) })
    }
    guard store.layoutMode == .fitAll, !devices.isEmpty else { return heights(at: fullHeight) }
    let available = width - 2 * DeviceLayout.padding - DeviceLayout.spacing * CGFloat(devices.count - 1)
    func rowWidth(at height: CGFloat) -> CGFloat {
      devices.reduce(0) { total, sim in
        let deviceWidth = store.shownSize(sim, portraitHeight: height * store.scale(for: sim.id)).width
        return total + deviceWidth  // the controls under a device shrink with it (see DeviceCard)
      }
    }
    if rowWidth(at: fullHeight) <= available { return heights(at: fullHeight) }
    var low: CGFloat = 40, high = fullHeight
    for _ in 0..<24 {
      let mid = (low + high) / 2
      if rowWidth(at: mid) <= available { low = mid } else { high = mid }
    }
    return heights(at: low)
  }
}

struct DeviceCard: View {
  @EnvironmentObject private var store: Store
  let sim: Simulator
  let height: CGFloat  // in portrait

  var body: some View {
    let isSlim = sim.slim?.isSlim == true
    let size = store.shownSize(sim, portraitHeight: height)
    let width = size.width
    VStack(spacing: 8) {
      // Above the device, at its top right like a window's title bar buttons: captures and the window.
      HStack {
        Spacer(minLength: 0)
        if width >= 96 { controlBar(topGroups, width: width) }
      }
      .frame(width: width, height: DeviceLayout.headerHeight - 8)
      DeviceTile(udid: sim.id, store: store, quarterTurns: store.orientation(sim.id).quarterTurns)
        .frame(width: width, height: size.height)
      HStack(spacing: 6) {
        Text(sim.name)
          .font(.callout.weight(store.active == sim.id ? .semibold : .regular))
          .foregroundStyle(store.active == sim.id ? .primary : .secondary)
          .lineLimit(1)
        Button { store.toggleSlim(sim) } label: {
          Image(systemName: isSlim ? "leaf.fill" : "leaf").foregroundStyle(isSlim ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(store.busy[sim.id] != nil)
        .help(isSlim ? "Slimmed by simslim · click to restore standard (reboots)" : "Slim Down with simslim")
        if let state = store.recording[sim.id] {
          RecordingBadge(state: state)
        } else if width >= 170 {
          Text(footer).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        } else if let label = store.busy[sim.id] {
          ProgressView().controlSize(.mini).help(label)
        }
      }
      .frame(maxWidth: width)  // truncate the name rather than widen the card
      // The controls shrink with the device, and give way entirely on very small ones (the Device menu
      // and its shortcuts still act on the active device).
      if width >= 96 { controlBar(bottomGroups, width: width) }
    }
  }

  private enum Control: Hashable { case home, appSwitcher, rotate, appearance, screenshot, record, detach }

  /// Under the device: navigation, the device itself. Above it: captures, the window.
  private let bottomGroups: [[Control]] = [[.home, .appSwitcher], [.rotate, .appearance]]
  private let topGroups: [[Control]] = [[.screenshot, .record], [.detach]]

  /// One capsule per kind of action when there is room, then a single capsule, then smaller buttons.
  private func controlBar(_ groups: [[Control]], width: CGFloat) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        ForEach(groups, id: \.self) { group in controls(group, compact: false).capsule(compact: false) }
      }
      controls(groups.flatMap { $0 }, compact: false).capsule(compact: false)
      controls(groups.flatMap { $0 }, compact: true).capsule(compact: true)
    }
    .frame(maxWidth: width)
    .simultaneousGesture(TapGesture().onEnded { store.active = sim.id })
  }

  private func controls(_ items: [Control], compact: Bool) -> some View {
    HStack(spacing: compact ? 0 : 2) {
      ForEach(items, id: \.self) { control($0, compact: compact) }
    }
  }

  @ViewBuilder private func control(_ control: Control, compact: Bool) -> some View {
    switch control {
    case .home: DeviceButton("house", "Home", "⇧⌘H", compact: compact) { store.home(sim.id) }
    case .appSwitcher:
      DeviceButton("square.stack.3d.up", "App Switcher", "⌃⇧⌘H", compact: compact) { store.appSwitcher(sim.id) }
    case .rotate:
      DeviceButton("rotate.left", "Rotate Left", "⌘←", compact: compact) { store.rotate(sim.id, clockwise: false) }
    case .appearance:
      DeviceButton("circle.lefthalf.filled", "Toggle Appearance", "⇧⌘A", compact: compact) { store.toggleAppearance(sim.id) }
    case .screenshot: DeviceButton("camera", "Take Screenshot", "⌘S", compact: compact) { store.screenshot(sim.id) }
    case .record: RecordButton(sim: sim, compact: compact)
    case .detach:
      DeviceButton("macwindow.badge.plus", "Detach into Window", "⇧⌘D", compact: compact) { store.detach(sim.id) }
    }
  }

  private var footer: String {
    if let label = store.busy[sim.id] { return label }
    return sim.memory.map(formatMemory) ?? ""
  }
}

/// What is behind the window (desktop, other apps), blurred, like Simulator.app's device windows.
/// Stays blurred when SimView is not the active app.
struct BehindWindowBlur: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.material = .fullScreenUI
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Hosts the AppKit device frame (chrome + live screen + input) inside SwiftUI.
struct DeviceTile: NSViewRepresentable {
  let udid: String
  let store: Store
  /// Counter-clockwise quarter turns (see DeviceOrientation): a value, so a rotation updates the view.
  var quarterTurns = 0
  /// In its own window: dragging the bezel resizes the window instead of the device in the row.
  var detached = false

  final class Coordinator {
    let store: Store
    init(store: Store) { self.store = store }
  }

  func makeCoordinator() -> Coordinator { Coordinator(store: store) }

  func makeNSView(context: Context) -> SVDeviceFrameView {
    if ProcessInfo.processInfo.environment["SIMVIEW_TRACE"] != nil { print("trace: make \(udid.prefix(8))") }
    let view = SVDeviceFrameView(simulator: store.infos[udid]!)
    let store = self.store, udid = self.udid
    view.onActivate = { [weak store] in store?.active = udid }
    view.quarterTurns = quarterTurns
    view.canDropFiles = { [weak store] urls in store?.canDrop(urls, on: udid) ?? false }
    view.onDropFiles = { [weak store] urls in store?.drop(urls, on: udid) }
    if detached {
      view.onResize = { [weak store, weak view] width in
        guard let view else { return }
        store?.windows.resize(udid, toWidth: width, sides: (view.resizeSideX, view.resizeSideY))
      }
      view.onResetSize = { [weak store] in store?.windows.resetSize(udid) }
    } else {
      view.onResize = { [weak store] width in store?.setWidth(Double(width), for: udid) }
      view.onResetSize = { [weak store] in store?.resetWidth(for: udid) }
    }
    store.register(view)
    return view
  }

  func updateNSView(_ view: SVDeviceFrameView, context: Context) {
    view.quarterTurns = quarterTurns
    let isActive = store.active == udid
    guard view.active != isActive else { return }
    view.active = isActive
    if isActive { DispatchQueue.main.async { view.focus() } }
  }

  static func dismantleNSView(_ view: SVDeviceFrameView, coordinator: Coordinator) {
    view.stop()
    coordinator.store.unregister(view)
  }
}

private extension View {
  /// The rounded background the controls under a device sit on.
  func capsule(compact: Bool) -> some View {
    fixedSize()
      .padding(.horizontal, compact ? 3 : 6)
      .padding(.vertical, 2)
      .background(.quaternary.opacity(0.6), in: Capsule())
  }
}

/// Starts / stops the screen recording (⌘R does the same on the active device).
struct RecordButton: View {
  @EnvironmentObject private var store: Store
  let sim: Simulator
  let compact: Bool

  var body: some View {
    let state = store.recording[sim.id]
    Button { store.toggleRecording(sim.id) } label: {
      Image(systemName: state == nil ? "record.circle" : "stop.circle.fill")
        .font(compact ? .caption : .body)
        .foregroundStyle(state == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
        .frame(width: compact ? 20 : 26, height: compact ? 18 : 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(state == .saving)
    .help(String(localized: state == nil ? "Record Video" : "Stop Recording") + "  ⌘R")
  }
}

/// "● 0:42" while recording, then "Saving…" while simctl finishes the file.
struct RecordingBadge: View {
  let state: Store.RecordingState

  var body: some View {
    switch state {
    case .recording(let since):
      TimelineView(.periodic(from: since, by: 1)) { context in
        let seconds = max(Int(context.date.timeIntervalSince(since)), 0)
        Label(String(format: "%d:%02d", seconds / 60, seconds % 60), systemImage: "circle.fill")
          .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.red)
          .labelStyle(.titleAndIcon)
          .imageScale(.small)
      }
    case .saving:
      Text("Saving…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
  }
}

/// A small icon button under a device. Its tooltip: what it does, then its keyboard shortcut.
struct DeviceButton: View {
  let symbol: String
  let help: LocalizedStringResource
  let shortcut: String
  var compact = false
  let action: () -> Void

  init(_ symbol: String, _ help: LocalizedStringResource, _ shortcut: String, compact: Bool = false, action: @escaping () -> Void) {
    self.symbol = symbol
    self.help = help
    self.shortcut = shortcut
    self.compact = compact
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(compact ? .caption : .body)
        .frame(width: compact ? 20 : 26, height: compact ? 18 : 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(String(localized: help) + "  " + shortcut)
  }
}

