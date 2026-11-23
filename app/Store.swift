import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SlimStatus: Equatable {
  let disabled: Int
  let total: Int
  var isSlim: Bool { disabled > 0 }
}

struct Simulator: Identifiable, Equatable {
  let id: String  // UDID
  let name: String
  let runtime: String
  let state: String
  let booted: Bool
  let naturalSize: CGSize  // device frame (chrome included), in points
  let family: String  // "iPhone", "iPad", "Apple Watch"…
  let available: Bool  // false: can't boot (its runtime was removed, or this Xcode doesn't know the device)
  let unavailableReason: String?
  var memory: UInt64?
  var slim: SlimStatus?
}

/// How a device is held, as `devicectl device orientation` names it. The raw value is also the number of
/// counter-clockwise quarter turns SimView draws it at.
enum DeviceOrientation: Int {
  case portrait = 0
  case landscapeLeft = 1        // turned left (counter-clockwise): Home side on the right
  case portraitUpsideDown = 2
  case landscapeRight = 3       // turned right (clockwise)

  init(quarterTurns: Int) { self = DeviceOrientation(rawValue: ((quarterTurns % 4) + 4) % 4)! }

  init?(devicectlName name: String) {
    switch name {
    case "portrait": self = .portrait
    case "landscapeLeft": self = .landscapeLeft
    case "portraitUpsideDown": self = .portraitUpsideDown
    case "landscapeRight": self = .landscapeRight
    default: return nil  // faceUp, faceDown, unknown
    }
  }

  var devicectlName: String {
    switch self {
    case .portrait: "portrait"
    case .landscapeLeft: "landscapeLeft"
    case .portraitUpsideDown: "portraitUpsideDown"
    case .landscapeRight: "landscapeRight"
    }
  }

  var quarterTurns: Int { rawValue }
  var isLandscape: Bool { rawValue % 2 == 1 }
}

func formatMemory(_ bytes: UInt64) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

/// App state: the simulators, which one is active, and every action on them.
final class Store: ObservableObject {
  @Published private(set) var simulators: [Simulator] = []
  @Published var active: String?
  enum LayoutMode: String, CaseIterable {
    case fullHeight  // every device as tall as the window allows; scroll sideways if they do not fit
    case fitAll      // zoomed out so the whole row fits in the window, no scrolling
  }

  @Published var layoutMode: LayoutMode =
    LayoutMode(rawValue: UserDefaults.standard.string(forKey: "layoutMode") ?? "") ?? .fullHeight {
    didSet { UserDefaults.standard.set(layoutMode.rawValue, forKey: "layoutMode") }
  }

  /// Height a device gets at 100 %: the row's height minus margins and footer (kept up to date by the row).
  @Published var fullHeight: Double = 700
  /// Devices shrunk by dragging their bezel, as a fraction of the full height (35 – 100 %).
  @Published var scales: [String: Double] = [:]

  func scale(for id: String) -> Double { scales[id] ?? 1 }

  func setWidth(_ width: Double, for id: String) {
    guard let sim = simulators.first(where: { $0.id == id }), sim.naturalSize.height > 0 else { return }
    let fullWidth = shownSize(sim, portraitHeight: fullHeight).width
    scales[id] = min(max(width / fullWidth, 0.35), 1)
  }

  func resetWidth(for id: String) { scales[id] = nil }
  @Published private(set) var busy: [String: String] = [:]  // UDID → what is running on it

  // MARK: Orientation

  /// Each booted device's orientation, read from the device itself (so a rotation made elsewhere, e.g. by the MCP
  /// server, shows up too) rather than remembered: a device that reboots comes back in portrait.
  @Published private(set) var orientations: [String: DeviceOrientation] = [:]
  /// Bumped on each rotation made here: an orientation polled before it is stale.
  private var rotationSerials: [String: Int] = [:]
  private var rotationsInFlight: [String: Int] = [:]
  private let rotations = DispatchQueue(label: "simview.rotations", qos: .userInitiated, autoreleaseFrequency: .workItem)

  func orientation(_ id: String) -> DeviceOrientation { orientations[id] ?? .portrait }

  /// The device's size (chrome included) as shown: its natural size, turned when it is in landscape.
  func shownNaturalSize(_ sim: Simulator) -> CGSize {
    orientation(sim.id).isLandscape ? CGSize(width: sim.naturalSize.height, height: sim.naturalSize.width) : sim.naturalSize
  }

  /// The device's size on screen when its portrait height would be `portraitHeight`: turning a device keeps its scale.
  func shownSize(_ sim: Simulator, portraitHeight: CGFloat) -> CGSize {
    let width = portraitHeight * sim.naturalSize.width / max(sim.naturalSize.height, 1)
    return orientation(sim.id).isLandscape ? CGSize(width: portraitHeight, height: width) : CGSize(width: width, height: portraitHeight)
  }

  /// Rotate Left (⌘←) / Rotate Right (⌘→), like Simulator.app: the device turns at once on screen, then iOS follows.
  func rotate(_ id: String? = nil, clockwise: Bool) {
    guard let id = id ?? active, booted.contains(where: { $0.id == id }) else { return }
    let old = orientation(id)
    let new = DeviceOrientation(quarterTurns: old.quarterTurns + (clockwise ? -1 : 1))
    rotationSerials[id, default: 0] += 1
    rotationsInFlight[id, default: 0] += 1
    setOrientation(new, for: id)
    rotations.async { [weak self] in  // serial: quick presses reach the device in order
      let result = Store.runForResult("/usr/bin/xcrun", ["devicectl", "device", "orientation", "set", "--device", id,
                                                         new.devicectlName, "--timeout", "15"])
      DispatchQueue.main.async {
        guard let self else { return }
        self.rotationsInFlight[id, default: 1] -= 1
        self.rotationSerials[id, default: 0] += 1  // what was polled while it ran is stale
        guard !result.ok else { return }
        if self.orientation(id) == new { self.setOrientation(old, for: id) }
        self.report(String(localized: "Couldn't rotate \(self.name(id))"), result.message, on: id)
      }
    }
  }

  private func setOrientation(_ orientation: DeviceOrientation, for id: String) {
    guard self.orientation(id) != orientation else { return }
    orientations[id] = orientation
    windows.orientationChanged(id)
  }

  /// `devicectl device orientation get`, ~70 ms. Nil when it cannot tell (older Xcode, device still booting).
  private static func readOrientation(_ udid: String) -> DeviceOrientation? {
    guard let data = run("/usr/bin/xcrun", ["devicectl", "device", "orientation", "get", "--device", udid,
                                            "--quiet", "--timeout", "5", "--json-output", "-"]),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = json["result"] as? [String: Any] else { return nil }
    return (result["deviceOrientation"] as? String).flatMap(DeviceOrientation.init(devicectlName:))
      ?? (result["deviceOrientationNonFlat"] as? String).flatMap(DeviceOrientation.init(devicectlName:))
  }

  private func applyOrientations(_ polled: [String: DeviceOrientation], serials: [String: Int]) {
    for (id, orientation) in polled where rotationSerials[id, default: 0] == serials[id, default: 0]
      && rotationsInFlight[id, default: 0] == 0 {
      setOrientation(orientation, for: id)
    }
  }

  private(set) var infos: [String: SVSimulatorInfo] = [:]
  private(set) var frames: [String: SVDeviceFrameView] = [:]  // read by DebugHooks
  private var slim: [String: SlimStatus] = [:]
  private var timers: [Timer] = []
  // .workItem: drain the Objective-C autorelease pool after each poll instead of letting it pile up.
  private let poll = DispatchQueue(label: "simview.poll", qos: .utility, autoreleaseFrequency: .workItem)
  private let actions = DispatchQueue(label: "simview.actions", qos: .userInitiated, attributes: .concurrent,
                                      autoreleaseFrequency: .workItem)

  var booted: [Simulator] { simulators.filter(\.booted) }
  var off: [Simulator] { simulators.filter { !$0.booted } }

  /// The simulators that are off and can boot, by device family: iPhone, iPad, then the others by name.
  var offByFamily: [(family: String, simulators: [Simulator])] {
    let groups = Dictionary(grouping: off.filter(\.available), by: \.family)
    func rank(_ family: String) -> Int { ["iPhone": 0, "iPad": 1][family] ?? 2 }
    return groups.keys
      .sorted { (rank($0), $0) < (rank($1), $1) }
      .map { ($0, groups[$0]!) }
  }

  /// Simulators that can't boot (see Simulator.available).
  var unavailable: [Simulator] { off.filter { !$0.available } }
  /// The booted devices shown in the main window's row: those not detached into their own window.
  var docked: [Simulator] { booted.filter { !detached.contains($0.id) } }
  var activeName: String? { simulators.first { $0.id == active }?.name }

  let captures = CaptureLibrary()

  // MARK: Detached windows

  /// Devices in their own window (see DetachedWindows). Kept across launches, and while a device is off: its
  /// window comes back when it boots again.
  @Published private(set) var detached = Set(UserDefaults.standard.stringArray(forKey: "detachedDevices") ?? []) {
    didSet {
      UserDefaults.standard.set(Array(detached), forKey: "detachedDevices")
      windows.sync()
    }
  }

  /// Detached devices whose window stays above every other app.
  @Published private(set) var pinned = Set(UserDefaults.standard.stringArray(forKey: "pinnedDevices") ?? []) {
    didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinnedDevices") }
  }

  lazy var windows = DetachedWindows(store: self)
  /// Reopens the main window (set by it), for when its last detached device is closed.
  var showMainWindow: (() -> Void)?

  func detach(_ id: String? = nil) {
    guard let id = id ?? active, booted.contains(where: { $0.id == id }) else { return }
    if !detached.contains(id) { detached.insert(id) }
    windows.bringToFront(id)
  }

  func reattach(_ id: String? = nil) {
    guard let id = id ?? active, detached.contains(id) else { return }
    detached.remove(id)
  }

  func toggleDetached(_ id: String? = nil) {
    guard let id = id ?? active else { return }
    detached.contains(id) ? reattach(id) : detach(id)
  }

  func togglePinned(_ id: String? = nil) {
    guard let id = id ?? active, detached.contains(id) else { return }
    if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
    windows.updatePin(id)
  }

  init() {
    refresh()
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
      [weak self] _ in self?.finishRecordings()
    }
    timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() })
    timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshSlim(nil) })
    installDebugHooks()
  }

  // MARK: Polling

  func refresh() {
    let serials = rotationSerials
    poll.async { [weak self] in
      let all = SVSimulators.all()
      let memory = SVSimulators.memoryFootprintByUDID().mapValues { $0.uint64Value }
      var orientations: [String: DeviceOrientation] = [:]
      for info in all where info.booted { orientations[info.udid] = Store.readOrientation(info.udid) }
      DispatchQueue.main.async {
        self?.applyOrientations(orientations, serials: serials)  // first: a window opened by apply gets its shape
        self?.apply(all, memory)
      }
    }
  }

  private func apply(_ all: [SVSimulatorInfo], _ memory: [String: UInt64]) {
    for id in orientations.keys where !all.contains(where: { $0.udid == id && $0.booted }) { orientations[id] = nil }
    let wasBooted = Set(booted.map(\.id))
    infos = Dictionary(all.map { ($0.udid, $0) }, uniquingKeysWith: { a, _ in a })
    let updated = all.map { info in
      Simulator(id: info.udid, name: info.name, runtime: info.runtimeName, state: info.state, booted: info.booted,
                naturalSize: SVDeviceFrameView.naturalSize(for: info), family: info.productFamily,
                available: info.available, unavailableReason: info.unavailableReason,
                memory: memory[info.udid], slim: slim[info.udid])
    }
    if updated != simulators { simulators = updated }
    let isBooted = Set(booted.map(\.id))
    let newlyBooted = isBooted.subtracting(wasBooted)
    // Devices already running when SimView opens are left as they are; only those turned on since get slimmed.
    if !newlyBooted.isEmpty { refreshSlim(Array(newlyBooted), slimIfStandard: loadedOnce && slimOnBoot) }
    loadedOnce = true
    windows.sync()  // a detached device that booted gets its window back, one that shut down loses it
    if active == nil || !isBooted.contains(active!) {
      // Deferred: changing the sidebar's selection while it is updating is a reentrant table operation.
      let first = booted.first?.id
      DispatchQueue.main.async { [weak self] in self?.active = first }
    }
  }

  private var simslim: String? {
    ["/opt/homebrew/bin/simslim", "/usr/local/bin/simslim"].first { FileManager.default.isExecutableFile(atPath: $0) }
  }
  var hasSimslim: Bool { simslim != nil }
  private var loadedOnce = false

  /// Every simulator that turns on is slimmed down: booted from SimView, or from anywhere else (Xcode, simctl…).
  /// On by default: that is what simslim is for; booting standard stays one menu away.
  @Published var slimOnBoot = UserDefaults.standard.object(forKey: "slimOnBoot") as? Bool ?? true {
    didSet { UserDefaults.standard.set(slimOnBoot, forKey: "slimOnBoot") }
  }

  /// `simslim status --json` for the given simulators (all booted ones when nil). With `slimIfStandard`, those
  /// found standard are slimmed down.
  func refreshSlim(_ ids: [String]?, slimIfStandard: Bool = false) {
    guard let simslim else { return }
    let targets = ids ?? booted.map(\.id)
    poll.async { [weak self] in
      var results: [String: SlimStatus] = [:]
      for id in targets {
        guard let data = Store.run(simslim, ["status", id, "--json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let disabled = json["managedDisabled"] as? Int, let total = json["managedTotal"] as? Int
        else { continue }
        results[id] = SlimStatus(disabled: disabled, total: total)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.slim.merge(results) { $1 }
        self.simulators = self.simulators.map { var s = $0; s.slim = self.slim[s.id]; return s }
        guard slimIfStandard else { return }
        for (id, status) in results where !status.isSlim && self.busy[id] == nil { self.slimOn(id) }
      }
    }
  }

  // MARK: Simulator lifecycle

  /// Boots the device, slimmed down when `slimmed` (by default: the "slim on boot" setting) and simslim is there.
  func boot(_ id: String, slimmed: Bool? = nil) {
    if slimmed ?? slimOnBoot, let simslim {
      // simslim boots a shut-down device itself, already slim.
      perform(id, String(localized: "Booting Slimmed…"), simslim, ["on", id]) { [weak self] in self?.refreshSlim([id]) }
    } else {
      perform(id, String(localized: "Booting…"), "/usr/bin/xcrun", ["simctl", "boot", id])
    }
  }
  func shutdown(_ id: String) { perform(id, String(localized: "Shutting Down…"), "/usr/bin/xcrun", ["simctl", "shutdown", id]) }

  func slimOn(_ id: String) {
    guard let simslim else { return }
    perform(id, String(localized: "Slimming Down…"), simslim, ["on", id, "--no-reboot"]) { [weak self] in self?.refreshSlim([id]) }
  }

  func slimOff(_ id: String) {
    guard let simslim else { return }
    perform(id, String(localized: "Restoring Standard…"), simslim, ["off", id]) { [weak self] in self?.refreshSlim([id]) }
  }

  func toggleSlim(_ sim: Simulator) {
    sim.slim?.isSlim == true ? slimOff(sim.id) : slimOn(sim.id)
  }

  private func perform(_ id: String, _ label: String, _ path: String, _ args: [String], then: (() -> Void)? = nil) {
    busy[id] = label
    actions.async { [weak self] in
      Store.run(path, args)
      DispatchQueue.main.async {
        self?.busy[id] = nil
        self?.refresh()
        then?()
      }
    }
  }

  /// Runs a tool and keeps what it said, to report a failure in its own words.
  static func runForResult(_ path: String, _ args: [String]) -> (ok: Bool, output: String, message: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return (false, "", error.localizedDescription) }
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    let output = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let ok = process.terminationStatus == 0
    return (ok, output, ok ? "" : (stderr.isEmpty ? (output.isEmpty ? String(localized: "Exit status \(process.terminationStatus).") : output) : stderr))
  }

  @discardableResult
  static func run(_ path: String, _ args: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
  }

  // MARK: Device actions (on the active simulator)

  func register(_ view: SVDeviceFrameView) { frames[view.udid] = view }
  func frameView(_ id: String) -> SVDeviceFrameView? { frames[id] }
  func unregister(_ view: SVDeviceFrameView) { if frames[view.udid] === view { frames[view.udid] = nil } }
  private func screen(_ id: String?) -> SVScreenView? { (id ?? active).flatMap { frames[$0]?.screenView } }

  func home(_ id: String? = nil) { screen(id)?.press(.home) }
  func appSwitcher(_ id: String? = nil) { screen(id)?.doublePressHome() }
  func lock(_ id: String? = nil) { screen(id)?.press(.lock) }
  func volumeUp(_ id: String? = nil) { screen(id)?.press(.volumeUp) }
  func volumeDown(_ id: String? = nil) { screen(id)?.press(.volumeDown) }

  func screenshot(_ id: String? = nil) {
    guard let id = id ?? active, let name = simulators.first(where: { $0.id == id })?.name else { return }
    let file = captures.newFile(for: name, ext: "png")
    actions.async {
      Store.run("/usr/bin/xcrun", ["simctl", "io", id, "screenshot", "--type=png", file.temporary.path])
      CaptureLibrary.finish(file.temporary, file.final)
    }
  }

  // MARK: Screen recording

  enum RecordingState: Equatable {
    case recording(since: Date)
    case saving  // stopped, simctl is finishing the file
  }

  @Published private(set) var recording: [String: RecordingState] = [:]
  private var recorders: [String: (process: Process, temporary: URL, final: URL)] = [:]

  func isRecording(_ id: String? = nil) -> Bool {
    guard let id = id ?? active, case .recording = recording[id] else { return false }
    return true
  }

  func toggleRecording(_ id: String? = nil) {
    guard let id = id ?? active else { return }
    switch recording[id] {
    case .recording: stopRecording(id)
    case .saving: return
    case nil: startRecording(id)
    }
  }

  private func startRecording(_ id: String) {
    guard let name = simulators.first(where: { $0.id == id && $0.booted })?.name else { return }
    let file = captures.newFile(for: name, ext: "mp4")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "io", id, "recordVideo", "--codec=h264", "--force", file.temporary.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self] _ in
      CaptureLibrary.finish(file.temporary, file.final)
      DispatchQueue.main.async {
        self?.recorders[id] = nil
        self?.recording[id] = nil
      }
    }
    do { try process.run() } catch { return }
    recorders[id] = (process, file.temporary, file.final)
    recording[id] = .recording(since: Date())
  }

  private func stopRecording(_ id: String) {
    guard let process = recorders[id]?.process else { return }
    recording[id] = .saving
    process.interrupt()  // SIGINT: simctl writes the end of the file and exits
  }

  /// Quitting: finish every recording rather than leave a broken file behind.
  private func finishRecordings() {
    let running = Array(recorders.values)
    running.forEach { if $0.process.isRunning { $0.process.interrupt() } }
    let deadline = Date().addingTimeInterval(5)
    while running.contains(where: \.process.isRunning) && Date() < deadline { usleep(50_000) }
    running.forEach { CaptureLibrary.finish($0.temporary, $0.final) }  // the termination handlers may not get to it
  }

  private func name(_ id: String) -> String { simulators.first { $0.id == id }?.name ?? id }

  /// An error, as a sheet on the window showing that device (the main window or its own).
  func report(_ title: String, _ message: String, on id: String?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    if let window = id.flatMap({ frames[$0]?.window }) ?? NSApp.keyWindow ?? NSApp.mainWindow {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  // MARK: Files dropped on a device

  /// Open an app once it is installed by dropping it on a device.
  @Published var launchAfterInstall = UserDefaults.standard.object(forKey: "launchAfterInstall") as? Bool ?? true {
    didSet { UserDefaults.standard.set(launchAfterInstall, forKey: "launchAfterInstall") }
  }

  enum DroppedFile {
    case app(URL)    // a built .app bundle
    case ipa(URL)    // an archive with Payload/<name>.app inside
    case media(URL)  // a photo or a video, for the Photos library
    case other(URL)

    init(_ url: URL) {
      let ext = url.pathExtension.lowercased()
      if ext == "app" { self = .app(url); return }
      if ext == "ipa" { self = .ipa(url); return }
      if let type = UTType(filenameExtension: ext), type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
        self = .media(url)
      } else {
        self = .other(url)
      }
    }
  }

  /// Whether the device lights up under dragged files: something it can take, and nothing already running on it.
  func canDrop(_ urls: [URL], on id: String) -> Bool {
    guard busy[id] == nil, booted.contains(where: { $0.id == id }) else { return false }
    return urls.contains { if case .other = DroppedFile($0) { false } else { true } }
  }

  /// Apps (.app, .ipa) are installed, and opened if launchAfterInstall; photos and videos go to Photos.
  /// One at a time, the footer saying which; what failed is reported at the end.
  func drop(_ urls: [URL], on id: String) {
    guard canDrop(urls, on: id) else { return }
    let files = urls.map(DroppedFile.init)
    let media = files.compactMap { if case .media(let url) = $0 { url } else { nil } }
    let apps = files.filter { switch $0 { case .app, .ipa: true; default: false } }
    let others = files.compactMap { if case .other(let url) = $0 { url.lastPathComponent } else { nil } }
    let launch = launchAfterInstall
    let slim = simulators.first { $0.id == id }?.slim?.isSlim == true
    busy[id] = String(localized: "Preparing…")
    actions.async { [weak self] in
      func status(_ label: String) { DispatchQueue.main.async { self?.busy[id] = label } }
      var errors: [String] = []
      if !others.isEmpty {
        errors.append(String(localized: "Not an app, photo or video: \(others.joined(separator: ", "))."))
      }
      if !media.isEmpty {
        status(String(localized: "Adding \(media.count) files to Photos…"))
        let result = Store.runForResult("/usr/bin/xcrun", ["simctl", "addmedia", id] + media.map(\.path))
        if !result.ok {
          errors.append(String(localized: "Photos: \(result.message)")
                        + (slim ? "\n\n" + String(localized: "This device is slimmed by simslim, which turns off its photo library service: set it back to standard to add photos and videos.") : ""))
        }
      }
      for file in apps {
        do {
          try Store.install(file, on: id, launch: launch, status: status)
        } catch {
          errors.append(error.localizedDescription)
        }
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.busy[id] = nil
        if !errors.isEmpty { self.report(String(localized: "Couldn't finish the drop on \(self.name(id))"), errors.joined(separator: "\n\n"), on: id) }
      }
    }
  }

  struct DropError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  /// Installs a .app, or the .app inside an .ipa, and opens it. Blocks: call off the main thread.
  private static func install(_ file: DroppedFile, on id: String, launch: Bool, status: (String) -> Void) throws {
    var app: URL
    var temporary: URL?
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    switch file {
    case .app(let url):
      app = url
    case .ipa(let url):
      status(String(localized: "Unpacking \(url.lastPathComponent)…"))
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SimView-\(UUID().uuidString)")
      temporary = directory
      let unzip = runForResult("/usr/bin/ditto", ["-x", "-k", url.path, directory.path])
      guard unzip.ok else { throw DropError(String(localized: "\(url.lastPathComponent): couldn't unpack it (\(unzip.message)).")) }
      let payload = directory.appendingPathComponent("Payload")
      guard let found = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
        .first(where: { $0.pathExtension.lowercased() == "app" })
      else { throw DropError(String(localized: "\(url.lastPathComponent): no Payload/*.app inside, so it isn't an app archive.")) }
      app = found
    default:
      return
    }
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
    let appName = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
    let fileName: String = { if case .ipa(let url) = file { url.lastPathComponent } else { app.lastPathComponent } }()
    if let platforms = info?["CFBundleSupportedPlatforms"] as? [String], !platforms.isEmpty,
       !platforms.contains(where: { $0.hasSuffix("Simulator") }) {
      throw DropError(String(localized: "\(fileName) is built for devices (\(platforms.joined(separator: ", "))), not for the Simulator. Build it for a simulator destination instead."))
    }
    status(String(localized: "Installing \(appName)…"))
    let result = runForResult("/usr/bin/xcrun", ["simctl", "install", id, app.path])
    guard result.ok else { throw DropError("\(fileName): \(result.message)") }
    guard launch, let bundleID = info?["CFBundleIdentifier"] as? String else { return }
    status(String(localized: "Opening \(appName)…"))
    let opened = runForResult("/usr/bin/xcrun", ["simctl", "launch", id, bundleID])
    guard opened.ok else { throw DropError(String(localized: "\(appName) was installed but couldn't be opened: \(opened.message)")) }
  }

  /// Light ↔ dark, like Simulator.app's Toggle Appearance: reads the device's current appearance, sets the other.
  func toggleAppearance(_ id: String? = nil) {
    guard let id = id ?? active else { return }
    actions.async {
      let current = Store.run("/usr/bin/xcrun", ["simctl", "ui", id, "appearance"])
        .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
      Store.run("/usr/bin/xcrun", ["simctl", "ui", id, "appearance", current == "dark" ? "light" : "dark"])
    }
  }

  func shake(_ id: String? = nil) {
    guard let id = id ?? active else { return }
    actions.async { Store.run("/usr/bin/xcrun", ["simctl", "spawn", id, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"]) }
  }
}
