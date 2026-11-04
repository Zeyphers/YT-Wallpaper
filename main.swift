import SwiftUI
import AVFoundation

struct Video: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var thumb: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
}

enum Fill: String, CaseIterable {
    case crop = "Crop to fill", fit = "Fit", stretch = "Stretch"
    var gravity: AVLayerVideoGravity {
        switch self { case .crop: .resizeAspectFill; case .fit: .resizeAspect; case .stretch: .resize }
    }
}

// Video-only H.264 over HLS: hardware-decoded, no audio downloaded, and AVPlayer can't start YouTube's
// plain DASH .mp4 URLs (it stalls forever), so HLS first, then anything H.264, then anything.
func format(_ h: Int) -> String {
    "bv*[vcodec^=avc1][height<=\(h)][protocol^=m3u8]/bv*[vcodec^=avc1][height<=\(h)]/b[height<=\(h)]/b"
}
let resolutions = [360, 480, 720, 1080]  // YouTube's H.264 tops out at 1080p

@MainActor final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()
    let defaults = UserDefaults.standard
    let player = AVPlayer()
    var windows: [NSWindow] = []
    var statusObs: NSKeyValueObservation?
    var lastRecover = Date.distantPast

    @Published var videos: [Video] = [] {
        didSet { defaults.set(try? JSONEncoder().encode(videos), forKey: "videos") }
    }
    @Published var fill = Fill.crop {
        didSet {
            defaults.set(fill.rawValue, forKey: "fill")
            windows.forEach { ($0.contentView?.layer as? AVPlayerLayer)?.videoGravity = fill.gravity }
        }
    }
    @Published var height = 1080 {
        didSet {
            defaults.set(height, forKey: "height")
            if let v = videos.first(where: { $0.id == current }), oldValue != height { play(v, at: player.currentTime().seconds) }
        }
    }
    @Published var shuffle = false { didSet { defaults.set(shuffle, forKey: "shuffle") } }
    @Published var current: String? { didSet { defaults.set(current, forKey: "current") } }
    @Published var paused = false
    @Published var status = ""

    init() {
        videos = (defaults.data(forKey: "videos")).flatMap { try? JSONDecoder().decode([Video].self, from: $0) } ?? []
        fill = Fill(rawValue: defaults.string(forKey: "fill") ?? "") ?? .crop
        shuffle = defaults.bool(forKey: "shuffle")
        height = resolutions.contains(defaults.integer(forKey: "height")) ? defaults.integer(forKey: "height") : 1080
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.next() }
        }
        nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.recover() }
        }
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.buildWindows() }
        }
        // Don't decode video nobody can see.
        let ws = NSWorkspace.shared.notificationCenter, dnc = DistributedNotificationCenter.default()
        for (c, n) in [(ws, NSWorkspace.screensDidSleepNotification), (dnc, .init("com.apple.screenIsLocked"))] as [(NotificationCenter, Notification.Name)] {
            c.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { self.player.pause() } }
        }
        for (c, n) in [(ws, NSWorkspace.screensDidWakeNotification), (dnc, .init("com.apple.screenIsUnlocked"))] as [(NotificationCenter, Notification.Name)] {
            c.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { if !self.paused { self.player.play() } } }
        }
        DispatchQueue.main.async {
            if let v = self.videos.first(where: { $0.id == self.defaults.string(forKey: "current") }) ?? self.videos.first { self.play(v) }
        }
    }

    // One desktop-level window per screen; all share one AVPlayer so the video is decoded once.
    func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            win.ignoresMouseEvents = true
            win.isReleasedWhenClosed = false
            win.backgroundColor = .black
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = fill.gravity
            let view = NSView()
            view.layer = layer
            view.wantsLayer = true
            win.contentView = view
            win.setFrame(screen.frame, display: false)
            if current != nil { win.orderFront(nil) }
            return win
        }
    }

    func play(_ v: Video, at seconds: Double = 0) {
        current = v.id
        status = "Loading \(v.title)…"
        if windows.isEmpty { buildWindows() }
        windows.forEach { $0.orderFront(nil) }
        Task {
            do {
                let out = try await ytdlp(["--no-playlist", "-f", format(height), "--print", "url", "--", "https://www.youtube.com/watch?v=\(v.id)"])
                guard current == v.id else { return }  // user picked something else meanwhile
                guard let line = out.split(separator: "\n").first, let url = URL(string: String(line)) else { throw Failure("no stream URL") }
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 30  // keep memory low on 8h videos
                statusObs = item.observe(\.status) { item, _ in
                    if item.status == .failed { DispatchQueue.main.async { self.recover() } }
                }
                player.replaceCurrentItem(with: item)
                if seconds.isFinite, seconds > 0 { await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
                if !paused { player.play() }
                status = ""
            } catch {
                status = "Couldn't play \(v.title): \(error.localizedDescription)"
            }
        }
    }

    // Stream URLs expire after ~6h; re-resolve and resume where we were. Twice in 30s means the video is broken: skip it.
    func recover() {
        guard let v = videos.first(where: { $0.id == current }) else { return }
        if Date().timeIntervalSince(lastRecover) < 30 { status = "\(v.title) failed, skipping"; return next() }
        lastRecover = Date()
        play(v, at: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
    }

    func next() {
        guard !videos.isEmpty else { return stop() }
        let i = videos.firstIndex { $0.id == current } ?? -1
        if videos.count == 1, i == 0, player.currentItem != nil {
            player.seek(to: .zero); if !paused { player.play() }; return
        }
        let j = shuffle ? videos.indices.filter { $0 != i }.randomElement()! : (i + 1) % videos.count
        play(videos[j])
    }

    func stop() {
        current = nil
        player.replaceCurrentItem(with: nil)
        windows.forEach { $0.orderOut(nil) }
    }

    func togglePause() {
        paused.toggle()
        paused ? player.pause() : player.play()
    }

    func remove(_ v: Video) {
        videos.removeAll { $0.id == v.id }
        if current == v.id { next() }
    }

    func addFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme),
              let host = url.host, host.hasSuffix("youtube.com") || host == "youtu.be" else {
            status = "Copy a YouTube link first"; return
        }
        status = "Adding…"
        Task {
            do {
                // Single videos (list= ignored) or whole playlist links.
                let out = try await ytdlp(["--flat-playlist", "--no-playlist", "--print", "%(id)s\t%(title)s", "--", url.absoluteString])
                let new = out.split(separator: "\n").compactMap { line -> Video? in
                    let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    return p.count == 2 && !videos.contains { $0.id == p[0] } ? Video(id: p[0], title: p[1]) : nil
                }
                videos += new
                status = new.isEmpty ? "Already in the list" : ""
                if current == nil, let first = new.first { play(first) }
            } catch {
                status = "Couldn't add: \(error.localizedDescription)"
            }
        }
    }
}

struct Failure: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

// Runs yt-dlp off the main thread. Finder-launched apps don't get Homebrew's PATH (yt-dlp needs deno from there too).
func ytdlp(_ args: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["yt-dlp", "--quiet", "--no-warnings"] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return cont.resume(throwing: error) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { cont.resume(returning: String(decoding: data, as: UTF8.self)) }
            else {
                let msg = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init)
                cont.resume(throwing: Failure(msg ?? "yt-dlp failed (is it installed? brew install yt-dlp)"))
            }
        }
    }
}

struct MenuView: View {
    @ObservedObject var w: Wallpaper

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { w.addFromClipboard() } label: { Label("Paste YouTube link", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v")
                Spacer()
                Button { w.togglePause() } label: { Image(systemName: w.paused ? "play.fill" : "pause.fill") }
                    .help(w.paused ? "Play" : "Pause")
                Button { w.next() } label: { Image(systemName: "forward.fill") }.help("Next")
            }
            if !w.status.isEmpty {
                Text(w.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if w.videos.isEmpty {
                Text("Copy a YouTube link, then click Paste (or ⌘V).").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) { ForEach(w.videos) { row($0) } }
                }
                .frame(height: min(CGFloat(w.videos.count) * 62, 372))
            }
            Divider()
            Picker("Scaling", selection: $w.fill) {
                ForEach(Fill.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Resolution", selection: $w.height) {
                ForEach(resolutions, id: \.self) { Text("\($0)p") }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Toggle("Shuffle", isOn: $w.shuffle)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    func row(_ v: Video) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: v.thumb) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if w.current == v.id {
                        Image(systemName: w.paused ? "pause.fill" : "play.fill").foregroundStyle(.white).shadow(radius: 3)
                    }
                }
            Text(v.title).font(.callout).lineLimit(2)
                .fontWeight(w.current == v.id ? .semibold : .regular)
            Spacer(minLength: 0)
            Button { w.remove(v) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Remove")
        }
        .padding(4)
        .background(w.current == v.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { w.play(v) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(v.title)
    }
}

@main struct YTWallpaperApp: App {
    @ObservedObject var w = Wallpaper.shared

    var body: some Scene {
        MenuBarExtra("YT Wallpaper", systemImage: "play.rectangle.on.rectangle") { MenuView(w: w) }
            .menuBarExtraStyle(.window)
    }
}
