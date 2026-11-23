// simview-mcp: a local MCP server (stdio) that lets AI agents see and drive the iOS simulators on
// this Mac. Screen through `simctl io screenshot`, touches / buttons / keys through Xcode 27's dtuhidd
// (see dtuhid.h), everything else through simctl, devicectl and simslim.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Plumbing

struct ToolError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { description = message }
}

enum Content {
  case text(String)
  case image(Data, mimeType: String)

  var json: [String: Any] {
    switch self {
    case .text(let text): return ["type": "text", "text": text]
    case .image(let data, let mimeType): return ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
    }
  }
}

func log(_ message: String) {
  FileHandle.standardError.write(Data(("simview-mcp: " + message + "\n").utf8))
}

func send(_ object: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

struct RunResult {
  let status: Int32
  let stdout: Data
  let stderr: String
  var output: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
  var ok: Bool { status == 0 }
}

/// Runs a command, feeding `stdin`, and gives up after `timeout` seconds.
@discardableResult
func run(_ path: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) -> RunResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = args
  let out = Pipe(), err = Pipe()
  process.standardOutput = out
  process.standardError = err
  let input = stdin == nil ? nil : Pipe()
  process.standardInput = input ?? FileHandle.nullDevice
  do { try process.run() } catch { return RunResult(status: -1, stdout: Data(), stderr: "\(error)") }
  if let stdin, let input {
    input.fileHandleForWriting.write(stdin)
    try? input.fileHandleForWriting.close()
  }
  var outData = Data(), errData = Data()
  let group = DispatchGroup()
  group.enter()
  DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
  group.enter()
  DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
  if group.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    return RunResult(status: -2, stdout: outData, stderr: "timed out after \(Int(timeout)) s")
  }
  process.waitUntilExit()
  return RunResult(status: process.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
}

let xcrun = "/usr/bin/xcrun"

func simctl(_ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) throws -> RunResult {
  let result = run(xcrun, ["simctl"] + args, stdin: stdin, timeout: timeout)
  guard result.ok else {
    throw ToolError("simctl \(args.first ?? "") failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
  }
  return result
}

var simslimPath: String? {
  ["/opt/homebrew/bin/simslim", "/usr/local/bin/simslim"].first { FileManager.default.isExecutableFile(atPath: $0) }
}

func sleep(seconds: Double) { usleep(useconds_t(max(seconds, 0) * 1_000_000)) }

// MARK: - Arguments

struct Args {
  let raw: [String: Any]

  func string(_ key: String) -> String? { raw[key] as? String }
  func double(_ key: String) -> Double? {
    if let number = raw[key] as? NSNumber { return number.doubleValue }
    return (raw[key] as? String).flatMap(Double.init)
  }
  func bool(_ key: String) -> Bool? {
    if let bool = raw[key] as? Bool { return bool }
    return (raw[key] as? String).map { $0 == "true" }
  }
  func strings(_ key: String) -> [String]? { raw[key] as? [String] }

  func requireString(_ key: String) throws -> String {
    guard let value = string(key), !value.isEmpty else { throw ToolError("Missing `\(key)`.") }
    return value
  }
  func requireDouble(_ key: String) throws -> Double {
    guard let value = double(key) else { throw ToolError("Missing number `\(key)`.") }
    return value
  }
}

// MARK: - Simulators

func describe(_ sim: SVSimulatorInfo) -> String { "\(sim.name) (\(sim.udid))" }

/// The simulator named by `simulator` (UDID or exact name), or the only booted one when omitted.
func resolve(_ args: Args, requireBooted: Bool = true) throws -> SVSimulatorInfo {
  let all = SVSimulators.all()
  func checked(_ sim: SVSimulatorInfo) throws -> SVSimulatorInfo {
    if requireBooted && !sim.booted {
      throw ToolError("\(describe(sim)) is \(sim.state.lowercased()), not booted. Boot it with boot_simulator.")
    }
    return sim
  }
  if let key = args.string("simulator"), !key.isEmpty {
    if let sim = all.first(where: { $0.udid.caseInsensitiveCompare(key) == .orderedSame }) { return try checked(sim) }
    let named = all.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    let bootedNamed = named.filter(\.booted)
    if bootedNamed.count == 1 { return bootedNamed[0] }
    if named.count == 1 { return try checked(named[0]) }
    if named.count > 1 {
      throw ToolError("Several simulators are named \"\(key)\": \(named.map(\.udid).joined(separator: ", ")). Pass the UDID.")
    }
    throw ToolError("No simulator matches \"\(key)\". Call list_simulators.")
  }
  let booted = all.filter(\.booted)
  if booted.count == 1 { return booted[0] }
  if booted.isEmpty { throw ToolError("No simulator is booted. Call list_simulators, then boot_simulator.") }
  throw ToolError("Several simulators are booted (\(booted.map(describe).joined(separator: "; "))). Pass `simulator` (UDID or name).")
}

// MARK: - Input (dtuhidd)

var hidConnections: [String: SVDTUHID] = [:]

func hid(_ sim: SVSimulatorInfo) throws -> SVDTUHID {
  if let existing = hidConnections[sim.udid], !existing.invalid { return existing }
  hidConnections[sim.udid]?.disconnect()
  do {
    let connection = try SVDTUHID.connect(toDevice: sim.device)
    hidConnections[sim.udid] = connection
    return connection
  } catch {
    throw ToolError("Cannot reach the touch service of \(describe(sim)): \(error.localizedDescription)")
  }
}

/// Converts a point in screen points (origin top-left) to the 0…1 ratios dtuhidd expects.
func ratio(_ sim: SVSimulatorInfo, _ x: Double, _ y: Double) throws -> (Double, Double) {
  let size = sim.screenPoints
  guard size.width > 0, size.height > 0 else { throw ToolError("Unknown screen size for \(describe(sim)).") }
  guard x >= 0, y >= 0, x <= size.width, y <= size.height else {
    throw ToolError("(\(x), \(y)) is outside the screen, which is \(Int(size.width))×\(Int(size.height)) points.")
  }
  return (x / size.width, y / size.height)
}

/// The edge a gesture starts from when it begins within 8 points of the screen's border.
func autoEdge(_ sim: SVSimulatorInfo, _ x: Double, _ y: Double) -> SVEdge {
  let size = sim.screenPoints
  if size.height - y <= 8 { return .bottom }
  if y <= 8 { return .top }
  if x <= 8 { return .left }
  if size.width - x <= 8 { return .right }
  return .none
}

func edge(named name: String?) throws -> SVEdge? {
  switch name?.lowercased() {
  case nil, "auto": return nil
  case "none": return SVEdge.none
  case "top": return .top
  case "bottom": return .bottom
  case "left": return .left
  case "right": return .right
  default: throw ToolError("`edge` must be auto, none, top, bottom, left or right.")
  }
}

func drag(_ sim: SVSimulatorInfo, from: (Double, Double), to: (Double, Double), duration: Double, holdEnd: Double, edge: SVEdge) throws {
  let device = try hid(sim)
  let start = try ratio(sim, from.0, from.1), end = try ratio(sim, to.0, to.1)
  let steps = max(Int(duration * 60), 6)
  device.touch(.start, x: start.0, y: start.1, edge: edge)
  for step in 1...steps {
    sleep(seconds: duration / Double(steps))
    let t = Double(step) / Double(steps)
    device.touch(.move, x: start.0 + (end.0 - start.0) * t, y: start.1 + (end.1 - start.1) * t, edge: edge)
  }
  if holdEnd > 0 { sleep(seconds: holdEnd) }
  device.touch(.end, x: end.0, y: end.1, edge: edge)
}

// USB HID keyboard usages (page 0x07) for named keys. Letters and digits are physical US positions.
let keyUsages: [String: UInt64] = {
  var keys: [String: UInt64] = [
    "return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29, "delete": 0x2A, "backspace": 0x2A, "tab": 0x2B,
    "space": 0x2C, "minus": 0x2D, "equal": 0x2E, "left_bracket": 0x2F, "right_bracket": 0x30, "backslash": 0x31,
    "semicolon": 0x33, "quote": 0x34, "grave": 0x35, "comma": 0x36, "period": 0x37, "slash": 0x38,
    "capslock": 0x39, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52, "home": 0x4A, "end": 0x4D,
    "pageup": 0x4B, "pagedown": 0x4E, "forward_delete": 0x4C,
  ]
  for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() { keys[String(letter)] = 0x04 + UInt64(index) }
  for (index, digit) in "1234567890".enumerated() { keys[String(digit)] = 0x1E + UInt64(index) }
  for f in 1...12 { keys["f\(f)"] = 0x3A + UInt64(f - 1) }
  return keys
}()

let modifierUsages: [String: UInt64] = [
  "cmd": 0xE3, "command": 0xE3, "shift": 0xE1, "option": 0xE2, "alt": 0xE2, "control": 0xE0, "ctrl": 0xE0,
]

// MARK: - Screenshots

/// The screen as JPEG, at `scale` image pixels per screen point (1 = coordinates match the image).
func screenshot(_ sim: SVSimulatorInfo, scale: Double = 1) throws -> Content {
  let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("simview-\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(atPath: path) }
  _ = try simctl(["io", sim.udid, "screenshot", "--type=png", path], timeout: 30)
  guard let data = FileManager.default.contents(atPath: path),
        let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ToolError("The screenshot could not be read.") }
  let size = sim.screenPoints
  let maxPixels = Int((max(size.width, size.height) * min(max(scale, 0.25), 3)).rounded())
  let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
  guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw ToolError("The screenshot could not be scaled.") }
  let jpeg = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
    throw ToolError("The screenshot could not be encoded.")
  }
  CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
  CGImageDestinationFinalize(destination)
  return .image(jpeg as Data, mimeType: "image/jpeg")
}

func screenNote(_ sim: SVSimulatorInfo, scale: Double = 1) -> String {
  let size = sim.screenPoints
  let base = "\(sim.name): screen \(Int(size.width))×\(Int(size.height)) points, origin top-left."
  if abs(scale - 1) < 0.01 { return base + " Image pixels = points: use them directly as tap/swipe coordinates." }
  return base + " Image scaled ×\(scale): divide image pixel coordinates by \(scale) to get points."
}

/// Appends a screenshot to an action's result when the caller asked for one.
func withScreenshot(_ args: Args, _ sim: SVSimulatorInfo, _ message: String) throws -> [Content] {
  guard args.bool("screenshot") == true else { return [.text(message)] }
  sleep(seconds: args.double("screenshot_delay") ?? 0.6)
  return [.text(message + " " + screenNote(sim)), try screenshot(sim)]
}

// MARK: - Typing text key by key

struct KeyStroke {
  let usage: UInt64
  var shift = false
  var option = false
  init(_ usage: UInt64, shift: Bool = false, option: Bool = false) { self.usage = usage; self.shift = shift; self.option = option }
}

func type(_ stroke: KeyStroke, on device: SVDTUHID) {
  if stroke.shift { device.key(0xE1, down: true) }
  if stroke.option { device.key(0xE2, down: true) }
  if stroke.shift || stroke.option { sleep(seconds: 0.015) }
  device.key(stroke.usage, down: true)
  sleep(seconds: 0.015)
  device.key(stroke.usage, down: false)
  if stroke.option { device.key(0xE2, down: false) }
  if stroke.shift { device.key(0xE1, down: false) }
  sleep(seconds: 0.015)
}

/// The simulator's current hardware keyboard layout, from its active keyboard ("hw=Automatic" follows the
/// software keyboard, e.g. en_US@sw=QWERTY → us, fr_FR@sw=AZERTY → fr). Cached for 30 s.
var layoutCache: [String: (layout: String, at: Date)] = [:]
func keyboardLayout(_ sim: SVSimulatorInfo) -> String {
  if let cached = layoutCache[sim.udid], Date().timeIntervalSince(cached.at) < 30 { return cached.layout }
  let output = run(xcrun, ["simctl", "spawn", sim.udid, "defaults", "read", "com.apple.keyboard.preferences", "KeyboardsCurrentAndNext"], timeout: 10).output
  let current = output.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
  let hardware = current.components(separatedBy: "hw=").dropFirst().first?.components(separatedBy: ";").first ?? "Automatic"
  let descriptor = hardware == "Automatic" ? current : hardware
  let layout = descriptor.localizedCaseInsensitiveContains("AZERTY") || descriptor.localizedCaseInsensitiveContains("French")
    || (hardware == "Automatic" && current.hasPrefix("fr") && !current.contains("QWERTY")) ? "fr" : "us"
  layoutCache[sim.udid] = (layout, Date())
  return layout
}

// US QWERTY: character → key (usage) and whether Shift is needed.
let usKeys: [Character: (UInt64, Bool)] = {
  var keys: [Character: (UInt64, Bool)] = [" ": (0x2C, false), "\n": (0x28, false), "\t": (0x2B, false)]
  for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
    keys[letter] = (0x04 + UInt64(index), false)
    keys[Character(letter.uppercased())] = (0x04 + UInt64(index), true)
  }
  for (index, pair) in zip("1234567890", "!@#$%^&*()").enumerated() {
    keys[pair.0] = (0x1E + UInt64(index), false)
    keys[pair.1] = (0x1E + UInt64(index), true)
  }
  for (usage, plain, shifted) in [(0x2D, "-", "_"), (0x2E, "=", "+"), (0x2F, "[", "{"), (0x30, "]", "}"), (0x31, "\\", "|"),
                                  (0x33, ";", ":"), (0x34, "'", "\""), (0x35, "`", "~"), (0x36, ",", "<"), (0x37, ".", ">"),
                                  (0x38, "/", "?")] as [(UInt64, Character, Character)] {
    keys[plain] = (usage, false)
    keys[shifted] = (usage, true)
  }
  return keys
}()

// French AZERTY (Apple layout), by physical key position.
let frKeys: [Character: (UInt64, Bool)] = {
  var keys: [Character: (UInt64, Bool)] = [" ": (0x2C, false), "\n": (0x28, false), "\t": (0x2B, false)]
  let positions: [Character: UInt64] = ["a": 0x14, "z": 0x1A, "q": 0x04, "w": 0x1D, "m": 0x33]
  for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
    let usage = positions[letter] ?? 0x04 + UInt64(index)
    keys[letter] = (usage, false)
    keys[Character(letter.uppercased())] = (usage, true)
  }
  for (index, pair) in zip("&é\"'(§è!çà", "1234567890").enumerated() {
    keys[pair.0] = (0x1E + UInt64(index), false)
    keys[pair.1] = (0x1E + UInt64(index), true)
  }
  for (usage, plain, shifted) in [(0x2D, ")", "°"), (0x2E, "-", "_"), (0x10, ",", "?"), (0x36, ";", "."), (0x37, ":", "/"),
                                  (0x38, "=", "+"), (0x30, "$", "*"), (0x34, "ù", "%"), (0x35, "@", "#"), (0x64, "<", ">")]
      as [(UInt64, Character, Character)] {
    keys[plain] = (usage, false)
    keys[shifted] = (usage, true)
  }
  return keys
}()

/// Keystrokes producing `character`, using dead keys for accents the layout has no key for.
func keystrokes(for character: Character, layout: String) -> [KeyStroke]? {
  let table = layout == "fr" ? frKeys : usKeys
  if let (usage, shift) = table[character] { return [KeyStroke(usage, shift: shift)] }
  if layout == "us", character == "ç" || character == "Ç" { return [KeyStroke(0x06, shift: character == "Ç", option: true)] }
  // Accented letter: dead key for the accent, then the base letter.
  let decomposed = String(character).decomposedStringWithCanonicalMapping.unicodeScalars
  guard decomposed.count == 2, let base = table[Character(decomposed.first!)] else { return nil }
  let mark = decomposed.last!.value
  let dead: KeyStroke?
  if layout == "fr" {
    switch mark {
    case 0x0302: dead = KeyStroke(0x2F)               // ^
    case 0x0308: dead = KeyStroke(0x2F, shift: true)  // ¨
    case 0x0300: dead = KeyStroke(0x31)               // `
    default: dead = nil
    }
  } else {
    switch mark {
    case 0x0301: dead = KeyStroke(0x08, option: true)  // ´  ⌥E
    case 0x0300: dead = KeyStroke(0x35, option: true)  // `  ⌥`
    case 0x0302: dead = KeyStroke(0x0C, option: true)  // ^  ⌥I
    case 0x0308: dead = KeyStroke(0x18, option: true)  // ¨  ⌥U
    case 0x0303: dead = KeyStroke(0x11, option: true)  // ~  ⌥N
    default: dead = nil
    }
  }
  guard let dead else { return nil }
  return [dead, KeyStroke(base.0, shift: base.1)]
}

// MARK: - Video recording

var recordings: [String: (process: Process, path: String)] = [:]

// MARK: - Tool definitions

struct Tool {
  let name: String
  let description: String
  let properties: [String: Any]
  let required: [String]
  let run: (Args) throws -> [Content]

  var json: [String: Any] {
    ["name": name, "description": description,
     "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
  }
}

func prop(_ type: String, _ description: String, _ extra: [String: Any] = [:]) -> [String: Any] {
  var property: [String: Any] = ["type": type, "description": description]
  extra.forEach { property[$0.key] = $0.value }
  return property
}

let simulatorProp = prop("string", "UDID or exact name of the simulator. Optional when exactly one simulator is booted.")
let screenshotProp = prop("boolean", "Return a screenshot of the result in the same call (after `screenshot_delay`).")
let screenshotDelayProp = prop("number", "Seconds to wait before that screenshot (default 0.6).")
func target(_ extra: [String: Any] = [:]) -> [String: Any] {
  var properties: [String: Any] = ["simulator": simulatorProp]
  extra.forEach { properties[$0.key] = $0.value }
  return properties
}
func action(_ extra: [String: Any] = [:]) -> [String: Any] {
  target(extra.merging(["screenshot": screenshotProp, "screenshot_delay": screenshotDelayProp]) { a, _ in a })
}

let buttons: [String: (page: UInt64, usage: UInt64)] = [
  "home": (0x0C, 0x40), "lock": (0x0C, 0x30), "side": (0x0C, 0x30), "siri": (0x0C, 0xCF),
  "volume_up": (0x0C, 0xE9), "volume_down": (0x0C, 0xEA), "action": (0x0B, 0x2D),
]

let tools: [Tool] = [
  // Simulators
  Tool(name: "list_simulators",
       description: "List the iOS simulators on this Mac: name, UDID, state, OS, screen size in points, and for booted ones their RAM and whether simslim has slimmed them. Start here.",
       properties: ["booted_only": prop("boolean", "Only booted simulators.")], required: []) { args in
    let all = SVSimulators.all().filter { args.bool("booted_only") != true || $0.booted }
    let memory = SVSimulators.memoryFootprintByUDID()
    var rows: [[String: Any]] = []
    for sim in all {
      var row: [String: Any] = ["name": sim.name, "udid": sim.udid, "state": sim.state, "os": sim.runtimeName,
                                "screen_points": "\(Int(sim.screenPoints.width))x\(Int(sim.screenPoints.height))"]
      if sim.booted {
        if let bytes = memory[sim.udid]?.uint64Value { row["ram_mb"] = bytes / 1_048_576 }
        if let simslim = simslimPath, let data = Optional(run(simslim, ["status", sim.udid, "--json"], timeout: 10).stdout),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let disabled = json["managedDisabled"] as? Int {
          row["slimmed"] = disabled > 0
        }
      }
      rows.append(row)
    }
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    return [.text(String(decoding: data, as: UTF8.self))]
  },
  Tool(name: "boot_simulator",
       description: "Boot a simulator and wait until it has finished booting (up to ~3 minutes).",
       properties: target(), required: ["simulator"]) { args in
    let sim = try resolve(args, requireBooted: false)
    if sim.booted { return [.text("\(describe(sim)) is already booted.")] }
    _ = try simctl(["boot", sim.udid])
    _ = try simctl(["bootstatus", sim.udid, "-b"], timeout: 240)
    return [.text("\(describe(sim)) booted.")]
  },
  Tool(name: "shutdown_simulator", description: "Shut a simulator down.", properties: target(), required: ["simulator"]) { args in
    let sim = try resolve(args, requireBooted: false)
    if !sim.booted { return [.text("\(describe(sim)) is already \(sim.state.lowercased()).")] }
    hidConnections.removeValue(forKey: sim.udid)?.disconnect()
    _ = try simctl(["shutdown", sim.udid], timeout: 120)
    return [.text("\(describe(sim)) shut down.")]
  },
  Tool(name: "slim_simulator",
       description: "Use simslim to stop the background iOS services a test run does not need (Siri, Spotlight, iCloud, widgets…), cutting the simulator's RAM about 4×, without rebooting. Some features stop working while slim: list the categories you need in `keep` (e.g. store = push notifications & StoreKit, photos = photo picker, web = universal links, icloud, health, pim = contacts/calendar, search, siri).",
       properties: target(["keep": prop("array", "simslim categories to leave running.", ["items": ["type": "string"]])]),
       required: []) { args in
    let sim = try resolve(args)
    guard let simslim = simslimPath else { throw ToolError("simslim is not installed (brew install mobai-app/tap/simslim).") }
    var command = ["on", sim.udid, "--no-reboot"]
    if let keep = args.strings("keep"), !keep.isEmpty { command += ["--except", keep.joined(separator: ",")] }
    let result = run(simslim, command, timeout: 180)
    guard result.ok else { throw ToolError("simslim failed: \(result.stderr)") }
    hidConnections.removeValue(forKey: sim.udid)?.disconnect()
    return [.text("\(describe(sim)) slimmed.\(result.output.isEmpty ? "" : "\n" + result.output)")]
  },
  Tool(name: "unslim_simulator",
       description: "Undo slim_simulator: re-enable every background service and reboot the simulator.",
       properties: target(), required: []) { args in
    let sim = try resolve(args, requireBooted: false)
    guard let simslim = simslimPath else { throw ToolError("simslim is not installed.") }
    hidConnections.removeValue(forKey: sim.udid)?.disconnect()
    let result = run(simslim, ["off", sim.udid], timeout: 300)
    guard result.ok else { throw ToolError("simslim failed: \(result.stderr)") }
    return [.text("\(describe(sim)) is back to stock (rebooted).")]
  },

  // Screen
  Tool(name: "screenshot",
       description: "See the simulator's screen. By default the image is 1 pixel per screen point, so pixel coordinates in it are the coordinates tap/swipe expect.",
       properties: target(["scale": prop("number", "Image pixels per point, 0.25–3 (default 1). Lower is cheaper; coordinates must then be divided by it.")]),
       required: []) { args in
    let sim = try resolve(args)
    let scale = args.double("scale") ?? 1
    return [.text(screenNote(sim, scale: scale)), try screenshot(sim, scale: scale)]
  },
  Tool(name: "get_screen_info",
       description: "Screen size in points, pixel scale, and current orientation of a simulator.",
       properties: target(), required: []) { args in
    let sim = try resolve(args)
    let orientation = run(xcrun, ["devicectl", "device", "orientation", "get", "--device", sim.udid], timeout: 20).output
    return [.text("\(describe(sim))\nscreen: \(Int(sim.screenPoints.width))×\(Int(sim.screenPoints.height)) points\n\(orientation)")]
  },

  // Touch
  Tool(name: "tap", description: "Tap the screen at (x, y) in points, origin top-left.",
       properties: action(["x": prop("number", "Points from the left."), "y": prop("number", "Points from the top.")]),
       required: ["x", "y"]) { args in
    let sim = try resolve(args)
    let x = try args.requireDouble("x"), y = try args.requireDouble("y")
    let point = try ratio(sim, x, y)
    let device = try hid(sim)
    device.touch(.start, x: point.0, y: point.1)
    sleep(seconds: 0.06)
    device.touch(.end, x: point.0, y: point.1)
    return try withScreenshot(args, sim, "Tapped (\(Int(x)), \(Int(y))).")
  },
  Tool(name: "double_tap", description: "Double-tap at (x, y) in points.",
       properties: action(["x": prop("number", "Points from the left."), "y": prop("number", "Points from the top.")]),
       required: ["x", "y"]) { args in
    let sim = try resolve(args)
    let x = try args.requireDouble("x"), y = try args.requireDouble("y")
    let point = try ratio(sim, x, y)
    let device = try hid(sim)
    for _ in 0..<2 {
      device.touch(.start, x: point.0, y: point.1)
      sleep(seconds: 0.05)
      device.touch(.end, x: point.0, y: point.1)
      sleep(seconds: 0.08)
    }
    return try withScreenshot(args, sim, "Double-tapped (\(Int(x)), \(Int(y))).")
  },
  Tool(name: "long_press", description: "Touch and hold at (x, y) in points (context menus, drag handles, editing mode).",
       properties: action(["x": prop("number", "Points from the left."), "y": prop("number", "Points from the top."),
                           "duration": prop("number", "Seconds to hold (default 1).")]),
       required: ["x", "y"]) { args in
    let sim = try resolve(args)
    let x = try args.requireDouble("x"), y = try args.requireDouble("y")
    let point = try ratio(sim, x, y)
    let device = try hid(sim)
    device.touch(.start, x: point.0, y: point.1)
    sleep(seconds: min(args.double("duration") ?? 1, 10))
    device.touch(.end, x: point.0, y: point.1)
    return try withScreenshot(args, sim, "Long-pressed (\(Int(x)), \(Int(y))).")
  },
  Tool(name: "swipe",
       description: "Drag one finger from (from_x, from_y) to (to_x, to_y), in points. Starting within 8 points of a screen edge makes it an edge gesture automatically: from the bottom edge upward = go Home (hold at the end with hold_end ≈ 0.5 to open the App Switcher), down from the top edge = Notification/Control Center, from the left edge = Back. Use hold_end > 0 for a precise drag without momentum.",
       properties: action(["from_x": prop("number", "Start, points from the left."), "from_y": prop("number", "Start, points from the top."),
                           "to_x": prop("number", "End, points from the left."), "to_y": prop("number", "End, points from the top."),
                           "duration": prop("number", "Seconds for the movement (default 0.3)."),
                           "hold_end": prop("number", "Seconds to hold still before lifting (default 0)."),
                           "edge": prop("string", "Edge gesture: auto (default), none, top, bottom, left, right.")]),
       required: ["from_x", "from_y", "to_x", "to_y"]) { args in
    let sim = try resolve(args)
    let from = (try args.requireDouble("from_x"), try args.requireDouble("from_y"))
    let to = (try args.requireDouble("to_x"), try args.requireDouble("to_y"))
    let gestureEdge = try edge(named: args.string("edge")) ?? autoEdge(sim, from.0, from.1)
    try drag(sim, from: from, to: to, duration: min(args.double("duration") ?? 0.3, 10), holdEnd: min(args.double("hold_end") ?? 0, 10), edge: gestureEdge)
    return try withScreenshot(args, sim, "Swiped (\(Int(from.0)), \(Int(from.1))) → (\(Int(to.0)), \(Int(to.1)))\(gestureEdge == .none ? "" : " from the \(["", "top", "left", "bottom", "right"][Int(gestureEdge.rawValue)]) edge").")
  },
  Tool(name: "scroll",
       description: "Scroll content by about `distance` points without momentum. direction = where the content moves into view: down reveals what is below (the finger moves up).",
       properties: action(["direction": prop("string", "up, down, left or right.", ["enum": ["up", "down", "left", "right"]]),
                           "distance": prop("number", "Points to scroll (default: 40 % of the screen)."),
                           "x": prop("number", "Where to scroll, points from the left (default: centre)."),
                           "y": prop("number", "Where to scroll, points from the top (default: centre).")]),
       required: ["direction"]) { args in
    let sim = try resolve(args)
    let size = sim.screenPoints
    let direction = try args.requireString("direction")
    let x = args.double("x") ?? size.width / 2, y = args.double("y") ?? size.height / 2
    let vertical = direction == "up" || direction == "down"
    let distance: Double = args.double("distance") ?? Double(vertical ? size.height : size.width) * 0.4
    var dx = 0.0, dy = 0.0
    switch direction {
    case "down": dy = -distance
    case "up": dy = distance
    case "right": dx = -distance
    case "left": dx = distance
    default: throw ToolError("`direction` must be up, down, left or right.")
    }
    let clamp = { (v: Double, limit: Double) in min(max(v, 12), limit - 12) }
    let from = (clamp(x - dx / 2, size.width), clamp(y - dy / 2, size.height))
    let to = (clamp(x + dx / 2, size.width), clamp(y + dy / 2, size.height))
    try drag(sim, from: from, to: to, duration: 0.35, holdEnd: 0.15, edge: .none)
    return try withScreenshot(args, sim, "Scrolled \(direction).")
  },
  Tool(name: "pinch",
       description: "Two-finger pinch centred on (x, y): scale > 1 zooms in (fingers spread), < 1 zooms out.",
       properties: action(["x": prop("number", "Centre, points from the left (default: screen centre)."),
                           "y": prop("number", "Centre, points from the top (default: screen centre)."),
                           "scale": prop("number", "End distance ÷ start distance, e.g. 2 or 0.5."),
                           "duration": prop("number", "Seconds (default 0.5).")]),
       required: ["scale"]) { args in
    let sim = try resolve(args)
    let size = sim.screenPoints
    let cx = args.double("x") ?? size.width / 2, cy = args.double("y") ?? size.height / 2
    let scale = max(min(try args.requireDouble("scale"), 6), 0.15)
    let maxHalf = min(cx, size.width - cx) - 6
    let startHalf = min(scale >= 1 ? 40 : maxHalf, maxHalf), endHalf = min(max(startHalf * scale, 10), maxHalf)
    let device = try hid(sim)
    let duration = min(args.double("duration") ?? 0.5, 5)
    let steps = max(Int(duration * 60), 8)
    func send(_ phase: SVTouchPhase, _ half: Double) throws {
      let a = try ratio(sim, cx - half, cy), b = try ratio(sim, cx + half, cy)
      device.touch(phase, x: a.0, y: a.1, x2: b.0, y2: b.1)
    }
    try send(.start, startHalf)
    for step in 1...steps {
      sleep(seconds: duration / Double(steps))
      try send(.move, startHalf + (endHalf - startHalf) * Double(step) / Double(steps))
    }
    sleep(seconds: 0.1)
    try send(.end, endHalf)
    return try withScreenshot(args, sim, "Pinched ×\(scale) at (\(Int(cx)), \(Int(cy))).")
  },

  // Keyboard & buttons
  Tool(name: "type_text",
       description: "Type text into the focused field (tap the field first), key by key like a hardware keyboard. The simulator's keyboard layout (US QWERTY or French AZERTY) is detected automatically. Accented letters work; characters that are not on the keyboard (e.g. emoji) are reported, not typed. Autocorrection may still change words.",
       properties: action(["text": prop("string", "Text to type. \\n presses Return."),
                           "submit": prop("boolean", "Press Return afterwards."),
                           "layout": prop("string", "auto (default), us or fr.", ["enum": ["auto", "us", "fr"]])]),
       required: ["text"]) { args in
    let sim = try resolve(args)
    let text = try args.requireString("text")
    let layout = args.string("layout").flatMap { $0 == "auto" ? nil : $0 } ?? keyboardLayout(sim)
    let device = try hid(sim)
    var skipped: [Character] = []
    for character in text {
      guard let strokes = keystrokes(for: character, layout: layout) else { skipped.append(character); continue }
      strokes.forEach { type($0, on: device) }
    }
    if args.bool("submit") == true { type(KeyStroke(0x28), on: device) }
    var message = "Typed \(text.count - skipped.count) of \(text.count) characters (\(layout) layout)\(args.bool("submit") == true ? " and pressed Return" : "")."
    if !skipped.isEmpty { message += " Not on the keyboard, skipped: \(String(skipped))." }
    return try withScreenshot(args, sim, message)
  },
  Tool(name: "press_key",
       description: "Press a hardware-keyboard key, optionally with modifiers (e.g. key \"a\" + [\"cmd\"] = Select All). Keys: return, escape, delete, tab, space, up/down/left/right, home, end, pageup, pagedown, forward_delete, f1–f12, a–z, 0–9, and punctuation names (comma, period, slash, minus…). Letters are US key positions: on an AZERTY simulator keyboard, a↔q and w↔z differ. Use type_text for text.",
       properties: action(["key": prop("string", "Key name."),
                           "modifiers": prop("array", "Any of cmd, shift, option, control.", ["items": ["type": "string"]]),
                           "repeat": prop("integer", "How many times (default 1).")]),
       required: ["key"]) { args in
    let sim = try resolve(args)
    let name = try args.requireString("key").lowercased()
    guard let usage = keyUsages[name] else { throw ToolError("Unknown key \"\(name)\". Known: \(keyUsages.keys.sorted().joined(separator: ", ")).") }
    let modifiers = try (args.strings("modifiers") ?? []).map { modifier -> UInt64 in
      guard let usage = modifierUsages[modifier.lowercased()] else { throw ToolError("Unknown modifier \"\(modifier)\".") }
      return usage
    }
    let device = try hid(sim)
    // iOS 27 refuses a simulated Cmd+V of something another app (or the Mac) copied unless the app may paste freely.
    if name == "v" && modifiers.contains(0xE3) { SVSimulators.allowPaste(onDevice: sim.device) }
    for _ in 0..<max(min(Int(args.double("repeat") ?? 1), 50), 1) {
      modifiers.forEach { device.key($0, down: true) }
      if !modifiers.isEmpty { sleep(seconds: 0.08) }
      device.key(usage, down: true)
      sleep(seconds: 0.06)
      device.key(usage, down: false)
      if !modifiers.isEmpty { sleep(seconds: 0.05) }
      modifiers.reversed().forEach { device.key($0, down: false) }
      sleep(seconds: 0.04)
    }
    return try withScreenshot(args, sim, "Pressed \((args.strings("modifiers") ?? []).map { $0 + "+" }.joined())\(name).")
  },
  Tool(name: "press_button",
       description: "Press a hardware button: home, lock (side button), siri, volume_up, volume_down, action (Action button), or app_switcher (double Home). Use duration for a long press (e.g. siri, or lock for 2 s).",
       properties: action(["button": prop("string", "Button name.", ["enum": ["home", "lock", "side", "siri", "volume_up", "volume_down", "action", "app_switcher"]]),
                           "duration": prop("number", "Seconds to hold (default: a quick press).")]),
       required: ["button"]) { args in
    let sim = try resolve(args)
    let name = try args.requireString("button")
    let device = try hid(sim)
    if name == "app_switcher" {
      device.doublePressHome()
    } else {
      guard let button = buttons[name] else { throw ToolError("Unknown button \"\(name)\".") }
      device.buttonUsagePage(button.page, usage: button.usage, down: true)
      sleep(seconds: min(args.double("duration") ?? 0.08, 10))
      device.buttonUsagePage(button.page, usage: button.usage, down: false)
    }
    return try withScreenshot(args, sim, "Pressed \(name).")
  },
  Tool(name: "rotate",
       description: "Set the device orientation: portrait, portraitUpsideDown, landscapeLeft, landscapeRight. Touch coordinates stay in the portrait screen's points.",
       properties: action(["orientation": prop("string", "New orientation.", ["enum": ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"]])]),
       required: ["orientation"]) { args in
    let sim = try resolve(args)
    let orientation = try args.requireString("orientation")
    let result = run(xcrun, ["devicectl", "device", "orientation", "set", "--device", sim.udid, orientation], timeout: 30)
    guard result.ok else { throw ToolError("Rotation failed: \(result.stderr.isEmpty ? result.output : result.stderr)") }
    return try withScreenshot(args, sim, "Rotated to \(orientation).")
  },
  Tool(name: "shake", description: "Shake the device (triggers motion/shake handlers, e.g. undo).",
       properties: action(), required: []) { args in
    let sim = try resolve(args)
    _ = try simctl(["spawn", sim.udid, "notifyutil", "-p", "com.apple.UIKit.SimulatorShake"])
    return try withScreenshot(args, sim, "Shook \(sim.name).")
  },
  Tool(name: "wait", description: "Wait for the app to settle (animations, loading), then optionally look at the screen.",
       properties: action(["seconds": prop("number", "Seconds to wait, up to 30 (default 1).")]), required: []) { args in
    // Only a screenshot needs to know which simulator.
    let sim = args.bool("screenshot") == true ? try resolve(args) : nil
    sleep(seconds: min(args.double("seconds") ?? 1, 30))
    guard let sim else { return [.text("Waited.")] }
    return try withScreenshot(args.with(["screenshot_delay": 0]), sim, "Waited.")
  },

  // Apps
  Tool(name: "list_apps", description: "Apps installed on the simulator: bundle id, name, version, and whether it is a system app.",
       properties: target(["include_system": prop("boolean", "Also list Apple's built-in apps (default false).")]), required: []) { args in
    let sim = try resolve(args)
    let result = try simctl(["listapps", sim.udid])
    guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: [String: Any]] else {
      throw ToolError("Could not read the app list.")
    }
    let rows = plist.compactMap { bundleID, info -> String? in
      let system = (info["ApplicationType"] as? String) == "System"
      if system && args.bool("include_system") != true { return nil }
      let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "?"
      return "\(bundleID)\t\(name)\t\(info["CFBundleShortVersionString"] as? String ?? "")\(system ? "\tsystem" : "")"
    }.sorted()
    return [.text(rows.isEmpty ? "No user apps installed (pass include_system to see Apple's)." : rows.joined(separator: "\n"))]
  },
  Tool(name: "launch_app", description: "Launch an app by bundle id (brings it to the front if already running).",
       properties: action(["bundle_id": prop("string", "e.g. com.apple.Preferences."),
                           "arguments": prop("array", "Launch arguments.", ["items": ["type": "string"]]),
                           "restart": prop("boolean", "Terminate a running instance first.")]),
       required: ["bundle_id"]) { args in
    let sim = try resolve(args)
    var command = ["launch"]
    if args.bool("restart") == true { command.append("--terminate-running-process") }
    command += [sim.udid, try args.requireString("bundle_id")] + (args.strings("arguments") ?? [])
    let result = try simctl(command)
    return try withScreenshot(args, sim, "Launched: \(result.output).")
  },
  Tool(name: "terminate_app", description: "Quit an app by bundle id.",
       properties: action(["bundle_id": prop("string", "Bundle id.")]), required: ["bundle_id"]) { args in
    let sim = try resolve(args)
    _ = try simctl(["terminate", sim.udid, try args.requireString("bundle_id")])
    return try withScreenshot(args, sim, "Terminated.")
  },
  Tool(name: "install_app", description: "Install a built .app bundle (e.g. from Xcode's DerivedData) on the simulator.",
       properties: target(["app_path": prop("string", "Absolute path to the .app.")]), required: ["app_path"]) { args in
    let sim = try resolve(args)
    let path = try args.requireString("app_path")
    _ = try simctl(["install", sim.udid, path], timeout: 300)
    let bundleID = (NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String) ?? "?"
    return [.text("Installed \(bundleID).")]
  },
  Tool(name: "uninstall_app", description: "Uninstall an app by bundle id.",
       properties: target(["bundle_id": prop("string", "Bundle id.")]), required: ["bundle_id"]) { args in
    let sim = try resolve(args)
    _ = try simctl(["uninstall", sim.udid, try args.requireString("bundle_id")], timeout: 120)
    return [.text("Uninstalled.")]
  },
  Tool(name: "open_url", description: "Open a URL on the simulator: web pages in Safari, deep links and universal links in their app.",
       properties: action(["url": prop("string", "The URL.")]), required: ["url"]) { args in
    let sim = try resolve(args)
    _ = try simctl(["openurl", sim.udid, try args.requireString("url")])
    return try withScreenshot(args, sim, "Opened.")
  },
  Tool(name: "get_app_container", description: "Path on this Mac of an app's bundle, data container, or app-group containers (to read its files, databases, preferences).",
       properties: target(["bundle_id": prop("string", "Bundle id."),
                           "container": prop("string", "app, data (default) or groups.", ["enum": ["app", "data", "groups"]])]),
       required: ["bundle_id"]) { args in
    let sim = try resolve(args)
    let result = try simctl(["get_app_container", sim.udid, try args.requireString("bundle_id"), args.string("container") ?? "data"])
    return [.text(result.output)]
  },

  // Device settings & data
  Tool(name: "set_location", description: "Simulate the device's GPS location.",
       properties: target(["latitude": prop("number", "Degrees."), "longitude": prop("number", "Degrees.")]),
       required: ["latitude", "longitude"]) { args in
    let sim = try resolve(args)
    _ = try simctl(["location", sim.udid, "set", "\(try args.requireDouble("latitude")),\(try args.requireDouble("longitude"))"])
    return [.text("Location set.")]
  },
  Tool(name: "clear_location", description: "Stop simulating a location.", properties: target(), required: []) { args in
    let sim = try resolve(args)
    _ = try simctl(["location", sim.udid, "clear"])
    return [.text("Location cleared.")]
  },
  Tool(name: "set_appearance", description: "Switch the simulator between light and dark mode.",
       properties: action(["appearance": prop("string", "light or dark.", ["enum": ["light", "dark"]])]), required: ["appearance"]) { args in
    let sim = try resolve(args)
    _ = try simctl(["ui", sim.udid, "appearance", try args.requireString("appearance")])
    return try withScreenshot(args, sim, "Appearance set.")
  },
  Tool(name: "set_content_size", description: "Set Dynamic Type text size, e.g. large (default), extra-large, accessibility-extra-extra-extra-large, extra-small.",
       properties: action(["size": prop("string", "extra-small, small, medium, large, extra-large, extra-extra-large, extra-extra-extra-large, accessibility-medium, accessibility-large, accessibility-extra-large, accessibility-extra-extra-large, accessibility-extra-extra-extra-large.")]),
       required: ["size"]) { args in
    let sim = try resolve(args)
    _ = try simctl(["ui", sim.udid, "content_size", try args.requireString("size")])
    return try withScreenshot(args, sim, "Text size set.")
  },
  Tool(name: "set_permission",
       description: "Grant, revoke or reset an app's privacy permission without the system prompt. Services: all, calendar, contacts, contacts-limited, location, location-always, photos, photos-add, media-library, microphone, motion, reminders, siri. Some changes terminate the app.",
       properties: target(["action": prop("string", "grant, revoke or reset.", ["enum": ["grant", "revoke", "reset"]]),
                           "service": prop("string", "Privacy service."),
                           "bundle_id": prop("string", "App bundle id (optional for reset).")]),
       required: ["action", "service"]) { args in
    let sim = try resolve(args)
    var command = ["privacy", sim.udid, try args.requireString("action"), try args.requireString("service")]
    if let bundle = args.string("bundle_id") { command.append(bundle) }
    _ = try simctl(command)
    return [.text("Permission updated.")]
  },
  Tool(name: "send_push", description: "Deliver a simulated push notification to an app.",
       properties: action(["bundle_id": prop("string", "Target app bundle id."),
                           "payload": prop("object", "APNs payload, e.g. {\"aps\": {\"alert\": {\"title\": \"Hi\", \"body\": \"…\"}, \"badge\": 1}}.")]),
       required: ["bundle_id", "payload"]) { args in
    let sim = try resolve(args)
    guard let payload = args.raw["payload"] as? [String: Any] else { throw ToolError("`payload` must be a JSON object.") }
    let data = try JSONSerialization.data(withJSONObject: payload)
    _ = try simctl(["push", sim.udid, try args.requireString("bundle_id"), "-"], stdin: data)
    return try withScreenshot(args, sim, "Push sent.")
  },
  Tool(name: "set_clipboard",
       description: "Put text on the simulator's clipboard; then press_key v with [\"cmd\"] pastes it into the focused field (works for emoji and any script, unlike type_text). The simulator's clipboard is kept in sync with the Mac's, so this also replaces the Mac clipboard of the person at this computer: use it only when type_text cannot do the job.",
       properties: target(["text": prop("string", "Text.")]), required: ["text"]) { args in
    let sim = try resolve(args)
    // simctl pbcopy is ignored on Xcode 27 (the clipboard belongs to dtpasteboardd); devicectl goes through it.
    let result = run(xcrun, ["devicectl", "device", "pasteboard", "copy", "--device", sim.udid, "--quiet"],
                     stdin: Data(try args.requireString("text").utf8), timeout: 20)
    guard result.ok else { throw ToolError("Could not set the clipboard: \(result.stderr.isEmpty ? result.output : result.stderr)") }
    SVSimulators.allowPaste(onDevice: sim.device)
    return [.text("Clipboard set (the Mac clipboard follows).")]
  },
  Tool(name: "get_clipboard", description: "Read the simulator's clipboard text.", properties: target(), required: []) { args in
    let sim = try resolve(args)
    return [.text(try simctl(["pbpaste", sim.udid]).output)]
  },
  Tool(name: "override_status_bar", description: "Override the status bar for clean screenshots (e.g. time 9:41, full battery and signal).",
       properties: target(["time": prop("string", "e.g. 9:41."), "battery_level": prop("integer", "0–100."),
                           "battery_state": prop("string", "charging, charged or discharging."),
                           "wifi_bars": prop("integer", "0–3."), "cellular_bars": prop("integer", "0–4."),
                           "operator_name": prop("string", "Carrier name.")]),
       required: []) { args in
    let sim = try resolve(args)
    var command = ["status_bar", sim.udid, "override"]
    if let time = args.string("time") { command += ["--time", time] }
    if let level = args.double("battery_level") { command += ["--batteryLevel", String(Int(level))] }
    if let state = args.string("battery_state") { command += ["--batteryState", state] }
    if let bars = args.double("wifi_bars") { command += ["--wifiMode", "active", "--wifiBars", String(Int(bars))] }
    if let bars = args.double("cellular_bars") { command += ["--cellularMode", "active", "--cellularBars", String(Int(bars))] }
    if let name = args.string("operator_name") { command += ["--operatorName", name] }
    if command.count == 3 { command += ["--time", "9:41", "--batteryLevel", "100", "--batteryState", "charged"] }
    _ = try simctl(command)
    return [.text("Status bar overridden.")]
  },
  Tool(name: "clear_status_bar", description: "Remove status bar overrides.", properties: target(), required: []) { args in
    let sim = try resolve(args)
    _ = try simctl(["status_bar", sim.udid, "clear"])
    return [.text("Status bar restored.")]
  },
  Tool(name: "add_media", description: "Add photos or videos (files on this Mac) to the simulator's photo library.",
       properties: target(["paths": prop("array", "Absolute file paths.", ["items": ["type": "string"]])]), required: ["paths"]) { args in
    let sim = try resolve(args)
    guard let paths = args.strings("paths"), !paths.isEmpty else { throw ToolError("Missing `paths`.") }
    _ = try simctl(["addmedia", sim.udid] + paths, timeout: 120)
    return [.text("Added \(paths.count) file(s).")]
  },

  // Debugging
  Tool(name: "get_logs",
       description: "Recent system log lines from the simulator (crashes, print/os_log output). Filter by process name and/or a log predicate.",
       properties: target(["seconds": prop("number", "How far back (default 30, max 600)."),
                           "process": prop("string", "Only this process (app executable name)."),
                           "predicate": prop("string", "NSPredicate for `log show`, e.g. subsystem == \"com.example.app\"."),
                           "max_lines": prop("integer", "Return at most this many most recent lines (default 200).")]),
       required: []) { args in
    let sim = try resolve(args)
    var predicates: [String] = []
    if let process = args.string("process") { predicates.append("process == \"\(process.replacingOccurrences(of: "\"", with: ""))\"") }
    if let predicate = args.string("predicate") { predicates.append("(\(predicate))") }
    var command = ["spawn", sim.udid, "log", "show", "--style", "compact", "--last", "\(Int(min(args.double("seconds") ?? 30, 600)))s"]
    if !predicates.isEmpty { command += ["--predicate", predicates.joined(separator: " AND ")] }
    let result = try simctl(command, timeout: 90)
    let lines = result.output.split(separator: "\n")
    let limit = max(Int(args.double("max_lines") ?? 200), 1)
    return [.text(lines.suffix(limit).joined(separator: "\n").isEmpty ? "No log lines." : lines.suffix(limit).joined(separator: "\n"))]
  },
  Tool(name: "start_recording", description: "Start recording the screen to a video file.",
       properties: target(["path": prop("string", "Output .mp4/.mov path (default: on the Desktop).")]), required: []) { args in
    let sim = try resolve(args)
    if recordings[sim.udid] != nil { throw ToolError("Already recording \(sim.name); call stop_recording first.") }
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let path = args.string("path") ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/\(sim.name) \(format.string(from: Date())).mp4")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = ["simctl", "io", sim.udid, "recordVideo", "--codec=h264", "--force", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    recordings[sim.udid] = (process, path)
    sleep(seconds: 0.5)
    return [.text("Recording \(sim.name) to \(path).")]
  },
  Tool(name: "stop_recording", description: "Stop the screen recording and return the video's path.",
       properties: target(), required: []) { args in
    let sim = try resolve(args)
    guard let recording = recordings.removeValue(forKey: sim.udid) else { throw ToolError("\(sim.name) is not being recorded.") }
    recording.process.interrupt()
    let deadline = Date().addingTimeInterval(10)
    while recording.process.isRunning && Date() < deadline { sleep(seconds: 0.1) }
    return [.text("Saved \(recording.path).")]
  },
]

extension Args {
  func with(_ values: [String: Any]) -> Args { Args(raw: raw.merging(values) { _, new in new }) }
}

let instructions = """
Drive the iOS simulators on this Mac. Start with list_simulators. Every tool takes `simulator` (UDID or exact name); \
it can be omitted when exactly one simulator is booted. When several agents share this Mac, each should work on its own simulator.
Look before you act: `screenshot` returns the screen at 1 pixel per point, and tap/swipe/long_press take coordinates in \
those points (origin top-left). Pass screenshot: true to an action to see its result in the same call.
Type with type_text (key by key, US or French layout detected); use press_key for Return, arrows, shortcuts. \
For emoji or other characters type_text reports as skipped: set_clipboard, then press_key v with ["cmd"].
Home: press_button home, or swipe up from the bottom edge. App Switcher: press_button app_switcher.
"""

// MARK: - JSON-RPC server

func handle(_ message: [String: Any]) {
  let id = message["id"]
  let method = message["method"] as? String ?? ""
  let params = message["params"] as? [String: Any] ?? [:]
  func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
  func fail(_ code: Int, _ text: String) { if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]) } }

  switch method {
  case "initialize":
    reply(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
           "capabilities": ["tools": ["listChanged": false]],
           "serverInfo": ["name": "simview", "version": "0.1.0"],
           "instructions": instructions])
  case "ping":
    reply([:])
  case "tools/list":
    reply(["tools": tools.map(\.json)])
  case "tools/call":
    let name = params["name"] as? String ?? ""
    guard let tool = tools.first(where: { $0.name == name }) else { return fail(-32602, "Unknown tool \(name)") }
    do {
      let content = try tool.run(Args(raw: params["arguments"] as? [String: Any] ?? [:]))
      reply(["content": content.map(\.json), "isError": false])
    } catch {
      reply(["content": [Content.text("\(error)").json], "isError": true])
    }
  default:
    if id != nil && !method.hasPrefix("notifications/") { fail(-32601, "Method not found: \(method)") }
  }
}

@main
struct SimViewMCP {
  static func main() {
    signal(SIGPIPE, SIG_IGN)
    log("ready")
    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty, let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) else { continue }
      if let batch = json as? [[String: Any]] { batch.forEach(handle) } else if let message = json as? [String: Any] { handle(message) }
    }
    recordings.values.forEach { $0.process.interrupt() }
  }
}
