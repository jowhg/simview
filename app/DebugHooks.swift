import AppKit
import SwiftUI

/// Debug and test hooks, each enabled by an environment variable when launching the app from a shell
/// (e.g. `SIMVIEW_TRACE=1 build/SimView.app/Contents/MacOS/SimView`). None of them run otherwise.
///
/// - SIMVIEW_TRACE: every 2 s, print frame-view draw counts and each device's frames per second.
/// - SIMVIEW_ZOOMTEST: animate every device's size like a dragged slider and report how smooth it was.
/// - SIMVIEW_MODETEST=<dir>: switch between the "fit all" and "full height" layouts, dumping each to <dir>.
/// - SIMVIEW_RESIZETEST=<dir>: shrink the window and restore it, dumping the devices to <dir>.
/// - SIMVIEW_DEBUG_DIR=<dir>: dump the devices to <dir> shortly after launch.
/// - SIMVIEW_LEAVETEST=<device name>: focus that device, then take the keyboard away (clipboard sync check).
/// - SIMVIEW_PASTETEST=<device name>: focus that device and press Cmd+V.
extension Store {
  func installDebugHooks() {
    if ProcessInfo.processInfo.environment["SIMVIEW_TRACE"] != nil {
      var lastFrameCounts: [String: UInt] = [:]
      _ = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in
        print("trace: draws=\(SVDeviceFrameView.drawCount()) liveFrames=\(SVDeviceFrameView.liveCount())")
        for (udid, view) in self.frames {
          let count = view.screenView.frameCount
          let name = self.simulators.first { $0.id == udid }?.name ?? udid
          print("trace: \(name) frames/s=\((count - (lastFrameCounts[udid] ?? count)) / 2)")
          lastFrameCounts[udid] = count
        }
        fflush(stdout)
      }
    }
    if ProcessInfo.processInfo.environment["SIMVIEW_ZOOMTEST"] != nil {
      // Zoom like a continuously dragged slider (60 steps/s for 4 s), to measure how smooth it is.
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
        let start = Date()
        var last = start, steps = 0, worst = 0.0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
          let now = Date()
          worst = max(worst, now.timeIntervalSince(last))
          last = now
          let elapsed = now.timeIntervalSince(start)
          if elapsed > 4 {
            timer.invalidate()
            print("zoomtest: \(steps) steps in 4 s (target 240), longest gap \(Int(worst * 1000)) ms")
            fflush(stdout)
            return
          }
          steps += 1
          if let self { for sim in self.booted { self.scales[sim.id] = 0.65 + 0.35 * abs(sin(elapsed * .pi)) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        print("zoomtest: start"); fflush(stdout)
      }
    }
    if let dir = ProcessInfo.processInfo.environment["SIMVIEW_MODETEST"] {
      // Narrow the window, switch to "fit all" (animated) and back, dumping device sizes and the
      // longest main-thread gap during each transition.
      DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
        guard let self, let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "SimView" }) else { return }
        var frame = window.frame
        frame.size.width = 900
        window.setFrame(frame, display: true)
        func measure(_ label: String, _ mode: LayoutMode, then next: @escaping () -> Void) {
          var last = Date(), worst = 0.0, ticks = 0
          let probe = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            let now = Date(); worst = max(worst, now.timeIntervalSince(last)); last = now; ticks += 1
          }
          RunLoop.main.add(probe, forMode: .common)
          withAnimation(.easeInOut(duration: 0.25)) { self.layoutMode = mode }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            probe.invalidate()
            var sizes: [String] = []
            for (udid, view) in self.frames {
              let name = self.simulators.first(where: { $0.id == udid })?.name ?? udid
              sizes.append("\(name): \(Int(view.frame.width))×\(Int(view.frame.height))")
            }
            print("modetest \(label): \(sizes.sorted().joined(separator: ", ")) | longest gap \(Int(worst * 1000)) ms")
            fflush(stdout)
            self.debugDump(to: dir + "/" + label)
            next()
          }
        }
        measure("fitAll", .fitAll) { measure("fullHeight", .fullHeight) {} }
      }
    }
    if let dir = ProcessInfo.processInfo.environment["SIMVIEW_RESIZETEST"] {
      // Shrink the window to 65 % of its height and back (like a user resize), dumping the devices at
      // the smallest point (mid-resize) and once restored.
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "SimView" }) else { return }
        let original = window.frame
        var step = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
          step += 1
          let t = Double(step) / 90
          let factor = t <= 1 ? 1 - 0.35 * t : min(0.65 + 0.35 * (t - 1), 1)
          var frame = original
          frame.size.height = original.height * factor
          frame.origin.y = original.maxY - frame.height
          window.setFrame(frame, display: true)
          if step == 90 { self?.debugDump(to: dir + "/small") }
          if step >= 180 {
            timer.invalidate()
            window.setFrame(original, display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.debugDump(to: dir + "/restored") }
          }
        }
        RunLoop.main.add(timer, forMode: .common)
      }
    }
    if let dir = ProcessInfo.processInfo.environment["SIMVIEW_DEBUG_DIR"] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.debugDump(to: dir) }
    }
    if let name = ProcessInfo.processInfo.environment["SIMVIEW_LEAVETEST"] {
      // Focus that simulator, then take the keyboard away from it: what it copied must reach the Mac.
      DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
        guard let self, let sim = self.simulators.first(where: { $0.name == name }), let view = self.frames[sim.id],
              let window = view.window else { print("leavetest: no device \(name)"); fflush(stdout); return }
        window.makeFirstResponder(view.screenView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          window.makeFirstResponder(nil)
          print("leavetest: left \(name)"); fflush(stdout)
        }
      }
    }
    if let name = ProcessInfo.processInfo.environment["SIMVIEW_PASTETEST"] {
      // Focus that simulator and press Cmd+V the way the keyboard does: through NSApp, menus first.
      DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
        guard let self, let sim = self.simulators.first(where: { $0.name == name }), let view = self.frames[sim.id],
              let window = view.window else { print("pastetest: no device \(name)"); fflush(stdout); return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view.screenView)
        // Spelled out step by step: as one expression, older Swift compilers give up type-checking it.
        let menuItems: [NSMenuItem] = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
        let pasteItem: NSMenuItem? = menuItems.first { $0.keyEquivalent == "v" && $0.keyEquivalentModifierMask == .command }
        func key(_ type: NSEvent.EventType) -> NSEvent? {
          NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                           isARepeat: false, keyCode: 0x09)
        }
        // A window only gets key events once SimView is the active app; launched from a shell it is not.
        if window.isKeyWindow, let down = key(.keyDown), let up = key(.keyUp) { NSApp.sendEvent(down); NSApp.sendEvent(up) }
        else { NSApp.sendAction(#selector(NSText.paste(_:)), to: view.screenView, from: pasteItem) }
        var itemDescription = "none"
        if let item = pasteItem {
          let action: String = item.action.map(NSStringFromSelector) ?? "nil"
          itemDescription = "\"\(item.title)\" → \(action)"
        }
        print("pastetest: Cmd+V to \(name) (key window \(window.isKeyWindow)), input ready \(view.screenView.inputReady), menu item \(itemDescription)")
        fflush(stdout)
      }
    }
  }

  /// Write each device frame (chrome only: live layers do not render offscreen)
  /// to a PNG in `dir` and print each screen's connection state, so the layout can be checked headlessly.
  private func debugDump(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (udid, view) in frames {
      let name = simulators.first { $0.id == udid }?.name ?? udid
      print("debug: \(name) screen=\(view.screenView.screenReady) input=\(view.screenView.inputReady) frame=\(view.frame.size)")
      guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
      view.cacheDisplay(in: view.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    fflush(stdout)
  }
}
