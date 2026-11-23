import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A screenshot or a screen recording taken from SimView.
struct Capture: Identifiable, Hashable {
  let url: URL
  let date: Date
  let bytes: Int64
  var id: URL { url }
  var isVideo: Bool { ["mp4", "mov"].contains(url.pathExtension.lowercased()) }

  /// "iPhone 17 Pro 2026-11-19 at 18.30.12" → "iPhone 17 Pro".
  var simulatorName: String {
    let name = url.deletingPathExtension().lastPathComponent
    guard let range = name.range(of: #" \d{4}-\d{2}-\d{2} at .*$"#, options: .regularExpression) else { return name }
    return String(name[..<range.lowerBound])
  }
}

/// The captures folder, watched so the sidebar follows what is added, renamed or deleted (Finder included).
final class CaptureLibrary: ObservableObject {
  static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures/SimView", isDirectory: true)
  private static let extensions: Set<String> = ["png", "jpg", "jpeg", "mp4", "mov"]

  @Published private(set) var items: [Capture] = []
  @Published private(set) var thumbnails: [URL: NSImage] = [:]
  private var requested: Set<URL> = []
  private var watcher: DispatchSourceFileSystemObject?

  init() {
    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    reload()
    watch()
  }

  /// Where a new capture goes. Write to `temporary` (hidden, so the sidebar skips it while it is being
  /// written), then `finish` moves it into place.
  func newFile(for simulator: String, ext: String) -> (temporary: URL, final: URL) {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let base = "\(simulator) \(format.string(from: Date()))"
    var final = Self.folder.appendingPathComponent("\(base).\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: final.path) {
      final = Self.folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
    }
    return (Self.folder.appendingPathComponent(".\(UUID().uuidString).\(ext)"), final)
  }

  static func finish(_ temporary: URL, _ final: URL) {
    let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if size > 0 { try? FileManager.default.moveItem(at: temporary, to: final) } else { try? FileManager.default.removeItem(at: temporary) }
  }

  func reload() {
    let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
    let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles])) ?? []
    let found = urls.compactMap { url -> Capture? in
      guard Self.extensions.contains(url.pathExtension.lowercased()), let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
      return Capture(url: url, date: values.creationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0))
    }.sorted { $0.date > $1.date }
    if found != items { items = found }
    let live = Set(found.map(\.url))
    thumbnails = thumbnails.filter { live.contains($0.key) }
    requested.formIntersection(live)
    found.filter { !requested.contains($0.url) }.forEach(makeThumbnail)
  }

  private func makeThumbnail(_ capture: Capture) {
    requested.insert(capture.url)
    let request = QLThumbnailGenerator.Request(fileAt: capture.url, size: CGSize(width: 96, height: 96),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if let image = thumbnail?.nsImage { self.thumbnails[capture.url] = image } else { self.requested.remove(capture.url) }
      }
    }
  }

  private func watch() {
    let fd = Darwin.open(Self.folder.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    source.setEventHandler { [weak self] in self?.reload() }
    source.setCancelHandler { close(fd) }
    source.resume()
    watcher = source
  }

  // MARK: Actions

  /// One pasteboard item per file: the file itself (Finder, Slack, Mail…) and, for an image, its pixels
  /// (apps that only take an image, and the simulators through the clipboard sync).
  func copy(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(sorted(urls).map { url in
      let item = NSPasteboardItem()
      item.setString(url.absoluteString, forType: .fileURL)
      if urls.count == 1, ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) {
        item.setData(data, forType: url.pathExtension.lowercased() == "png" ? .png : NSPasteboard.PasteboardType("public.jpeg"))
      }
      return item
    })
  }

  func trash(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.recycle(urls) { [weak self] _, _ in DispatchQueue.main.async { self?.reload() } }
  }

  func open(_ urls: [URL]) { sorted(urls).forEach { NSWorkspace.shared.open($0) } }
  func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [Self.folder] : sorted(urls)) }

  /// In the sidebar's order.
  private func sorted(_ urls: [URL]) -> [URL] {
    let set = Set(urls)
    return items.map(\.url).filter { set.contains($0) }
  }
}

// MARK: - Sidebar panel

struct CapturesPanel: View {
  @EnvironmentObject private var library: CaptureLibrary
  @State private var selection = Set<URL>()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Text("Captures").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        if !library.items.isEmpty {
          Text(library.items.count, format: .number).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        Spacer()
        Button { library.reveal([]) } label: { Image(systemName: "folder") }
          .buttonStyle(.borderless)
          .help("Show the captures folder in Finder")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)

      if library.items.isEmpty {
        ContentUnavailableView {
          Label("No Captures", systemImage: "photo.on.rectangle")
        } description: {
          Text("⌘S: take a screenshot\n⌘R: record the active simulator")
        }
        .frame(maxHeight: .infinity)
      } else {
        List(selection: $selection) {
          ForEach(library.items) { capture in
            CaptureRow(capture: capture)
              .tag(capture.url)
              .onDrag { NSItemProvider(contentsOf: capture.url) ?? NSItemProvider() }
          }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: URL.self) { urls in
          if !urls.isEmpty {
            Button("Open") { library.open(Array(urls)) }
            Button("Copy") { library.copy(Array(urls)) }
            Button("Show in Finder") { library.reveal(Array(urls)) }
            Divider()
            Button("Move to Trash") { trash(urls) }
          }
        } primaryAction: { urls in
          library.open(Array(urls))
        }
        // SwiftUI writes the returned providers to the pasteboard; ours goes in right after, with the image data.
        .onCopyCommand {
          let urls = Array(selection)
          DispatchQueue.main.async { library.copy(urls) }
          return []
        }
        .onDeleteCommand { trash(selection) }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
          guard !selection.isEmpty else { return .ignored }
          trash(selection)
          return .handled
        }
        .onChange(of: library.items) { _, items in selection.formIntersection(items.map(\.url)) }
      }
    }
  }

  private func trash(_ urls: Set<URL>) {
    library.trash(Array(urls))
    selection.subtract(urls)
  }
}

struct CaptureRow: View {
  @EnvironmentObject private var library: CaptureLibrary
  let capture: Capture

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
        if let image = library.thumbnails[capture.url] {
          Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        if capture.isVideo {
          Image(systemName: "play.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: Circle())
        }
      }
      .frame(width: 36, height: 48)
      VStack(alignment: .leading, spacing: 2) {
        Text(capture.simulatorName).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.vertical, 2)
    .help(capture.url.lastPathComponent)
  }

  private var detail: String {
    let kind = capture.isVideo ? String(localized: "Video") : String(localized: "Screenshot")
    let date = Calendar.current.isDateInToday(capture.date)
      ? capture.date.formatted(date: .omitted, time: .shortened)
      : capture.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    return "\(kind) · \(date) · \(ByteCountFormatter.string(fromByteCount: capture.bytes, countStyle: .file))"
  }
}
