import AppKit
import SwiftUI

@main
struct SimViewApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = Store()

  var body: some Scene {
    Window("SimView", id: "main") {
      ContentView()
        .environmentObject(store)
        .environmentObject(store.captures)
        .frame(minWidth: 860, minHeight: 560)
    }
    .defaultSize(width: 1560, height: 940)
    .commands { DeviceCommands(store: store) }

    Settings {
      SettingsView()
        .environmentObject(store)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    DetachedWindows.quitting = true  // the windows closing now stay detached for the next launch
    return .terminateNow
  }
}

/// The layout items at the top of the View menu, and the Device menu with the old Simulator.app shortcuts.
/// Both act on the active simulator.
struct DeviceCommands: Commands {
  @ObservedObject var store: Store

  var body: some Commands {
    CommandGroup(before: .toolbar) {
      Button("Full Height") { withAnimation(.easeInOut(duration: 0.25)) { store.layoutMode = .fullHeight } }
        .keyboardShortcut("1", modifiers: .command)
      Button("Fit All") { withAnimation(.easeInOut(duration: 0.25)) { store.layoutMode = .fitAll } }
        .keyboardShortcut("2", modifiers: .command)
      Divider()
      let detached = store.active.map { store.detached.contains($0) } ?? false
      Button(detached ? "Reattach to SimView" : "Detach into Window") { store.toggleDetached() }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(store.active == nil)
      Button(store.active.map { store.pinned.contains($0) } == true ? "Don't Keep on Top" : "Keep on Top") {
        store.togglePinned()
      }
      .keyboardShortcut("t", modifiers: [.command, .option])
      .disabled(!detached)
      Divider()
    }
    CommandMenu("Device") {
      Button("Home") { store.home() }
        .keyboardShortcut("h", modifiers: [.command, .shift])
      Button("App Switcher") { store.appSwitcher() }
        .keyboardShortcut("h", modifiers: [.command, .shift, .control])
      Button("Lock") { store.lock() }
        .keyboardShortcut("l", modifiers: .command)
      Divider()
      Button("Rotate Left") { store.rotate(clockwise: false) }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(store.active == nil)
      Button("Rotate Right") { store.rotate(clockwise: true) }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(store.active == nil)
      Divider()
      Button("Volume Up") { store.volumeUp() }
        .keyboardShortcut(.upArrow, modifiers: .command)
      Button("Volume Down") { store.volumeDown() }
        .keyboardShortcut(.downArrow, modifiers: .command)
      Button("Shake") { store.shake() }
        .keyboardShortcut("z", modifiers: [.command, .control])
      Button("Toggle Appearance") { store.toggleAppearance() }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(store.active == nil)
      Divider()
      Button("Take Screenshot") { store.screenshot() }
        .keyboardShortcut("s", modifiers: .command)
      Button(store.isRecording() ? "Stop Recording" : "Record Video") { store.toggleRecording() }
        .keyboardShortcut("r", modifiers: .command)
      Button("Open Captures Folder") { store.captures.reveal([]) }
      Divider()
      Toggle("Open Apps After Installing", isOn: $store.launchAfterInstall)
    }
  }
}

// MARK: - Settings

/// Settings (⌘,): slimming down simulators as they boot, and the interface language. The language is SimView's
/// own `AppleLanguages`, which is read at launch, so a change applies once SimView relaunches.
struct SettingsView: View {
  @EnvironmentObject private var store: Store
  /// "" follows the system; otherwise the code of a language SimView is localised in.
  @State private var language = Self.storedLanguage
  private static let launchLanguage = storedLanguage

  private static var storedLanguage: String {
    let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    return (domain["AppleLanguages"] as? [String])?.first ?? ""
  }

  var body: some View {
    Form {
      Section {
        Toggle("Slim down simulators when they boot", isOn: $store.slimOnBoot)
          .disabled(!store.hasSimslim)
        Text(store.hasSimslim
             ? "Booted from SimView or anywhere else (Xcode, simctl). Simulators already running are left as they are."
             : "Needs simslim: brew install mobai-app/tap/simslim")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Picker("Language", selection: $language) {
          Text("System").tag("")
          Text(verbatim: "English").tag("en")
          Text(verbatim: "Français").tag("fr")
        }
        .onChange(of: language) { _, code in
          if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
          } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
          }
        }
        if language != Self.launchLanguage {
          Text("The new language applies when SimView relaunches.")
            .font(.callout)
            .foregroundStyle(.secondary)
          Button("Relaunch Now", action: Self.relaunch)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Opens SimView again once this instance has quit (so two never run side by side), then quits.
  private static func relaunch() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$1\"",
                         String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
    do { try process.run() } catch { return }
    NSApp.terminate(nil)
  }
}
