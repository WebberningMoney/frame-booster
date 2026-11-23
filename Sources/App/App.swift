// App.swift — FrameBooster 的視窗程式（把影片拖進來就開始轉）。
//
// 白話說明：
//   - 先在下拉選單選「目標幀率」（60／120／144／240，預設 120）和「品質／速度優先」，再拖影片進來。
//     這兩個設定在影片「加入時」就記下來，之後改設定只影響新加入的影片
//     （所以可以把同一支影片先用 120、再用 60 各轉一次）。
//   - 一次只轉一支，其他的排隊等（同時轉好幾支反而會更慢）。
//   - 轉好的檔案放在原影片旁邊，檔名加上「_120fps」之類的字。原影片不會被修改。
//   - 影片原本就已經是目標幀率以上時，顯示「略過」，不會轉。
//   - 實際轉檔都在 Converter.swift；選項與裝置清單在 FPSPresets.swift；這裡只負責畫面和排隊。

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct FrameBoosterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var queue = JobQueue.shared

    var body: some Scene {
        WindowGroup("FrameBooster") {
            ContentView()
                .environmentObject(queue)
                .frame(minWidth: 600, minHeight: 480)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// 把影片拖到 Dock 或 Finder 裡的 App 圖示上時，會走到這裡。
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in JobQueue.shared.add(urls) }
    }
}

// MARK: - 資料：每一支影片是一個 Job，JobQueue 負責排隊

final class Job: ObservableObject, Identifiable {
    enum Status: Equatable { case waiting, running, done, skipped(String), failed(String), cancelled }
    let id = UUID()
    let input: URL
    let targetFPS: Int32       // 加入時選的目標幀率
    let highQuality: Bool      // 加入時選的品質／速度
    @Published var progress: Double = 0
    @Published var status: Status = .waiting
    @Published var output: URL?
    @Published var seconds: Double = 0
    init(input: URL, targetFPS: Int32, highQuality: Bool) {
        self.input = input; self.targetFPS = targetFPS; self.highQuality = highQuality
    }
    /// 例如「→ 120 FPS・品質優先」
    var settingsText: String { "→ \(targetFPS) FPS・\(highQuality ? "品質優先" : "速度優先")" }
}

@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()
    @Published var jobs: [Job] = []
    @Published var highQuality = true
    @Published var targetFPS: Int32 = FPSPreset.defaultFPS
    @Published private(set) var isRunning = false
    private var current: FrameRateConverter?

    func add(_ urls: [URL]) {
        let videos = urls.flatMap { Self.expand($0) }
        jobs.append(contentsOf: videos.map { Job(input: $0, targetFPS: targetFPS, highQuality: highQuality) })
        startNext()
    }

    /// 拖進來的是資料夾時，改成加入資料夾裡（第一層）的所有影片。
    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [url] }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return items.filter { u in
            guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
            return t.conforms(to: .movie)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func startNext() {
        guard !isRunning, let job = jobs.first(where: { $0.status == .waiting }) else { return }
        isRunning = true
        job.status = .running
        var opts = ConvertOptions()
        opts.targetFPS = job.targetFPS
        opts.highQuality = job.highQuality
        let conv = FrameRateConverter(input: job.input, options: opts)
        current = conv
        conv.progressHandler = { p in
            DispatchQueue.main.async { job.progress = p }
        }
        let start = Date()
        Task.detached {
            do {
                let out = try await conv.run()
                await MainActor.run {
                    job.output = out
                    job.progress = 1
                    job.seconds = Date().timeIntervalSince(start)
                    job.status = .done
                }
            } catch {
                let cancelled = conv.isCancelled
                let skipped = (error as? ConvertError)?.isSkip == true
                let message = error.localizedDescription
                await MainActor.run {
                    job.status = cancelled ? .cancelled : (skipped ? .skipped(message) : .failed(message))
                }
            }
            await MainActor.run {
                self.current = nil
                self.isRunning = false
                self.startNext()
            }
        }
    }

    func cancelCurrent() { current?.cancel() }

    func cancelAll() {
        for j in jobs where j.status == .waiting { j.status = .cancelled }
        current?.cancel()
    }

    func clearFinished() {
        jobs.removeAll { $0.status != .waiting && $0.status != .running }
    }
}

// MARK: - 畫面

struct ContentView: View {
    @EnvironmentObject var queue: JobQueue
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            dropZone
            HStack(spacing: 8) {
                Text("目標幀率")
                Picker("目標幀率", selection: $queue.targetFPS) {
                    ForEach(FPSPreset.all) { preset in
                        Text(preset.menuTitle).tag(preset.fps).help(preset.fullDevices)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 440, alignment: .leading)
                .help(FPSPreset.preset(for: queue.targetFPS).fullDevices)
                Spacer()
            }
            HStack {
                Picker("", selection: $queue.highQuality) {
                    Text("品質優先").tag(true)
                    Text("速度優先").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("品質優先：補出來的畫面比較自然，但比較慢。速度優先：比較快，但動作很快的畫面可能比較糊。改了只影響之後加入的影片。")
                Spacer()
                Button("取消全部") { queue.cancelAll() }.disabled(!queue.isRunning)
                Button("清除已完成") { queue.clearFinished() }
            }
            if queue.jobs.isEmpty {
                Spacer()
                Text("轉好的影片會放在原影片旁邊，檔名加上「_\(queue.targetFPS)fps」。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(queue.jobs) { job in JobRow(job: job) }
                    .listStyle(.inset)
            }
        }
        .padding(18)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 34))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("把影片拖到這裡").font(.title3.weight(.semibold))
            Text("把 30 FPS 的影片補成 60～240 FPS，在高更新率的螢幕上看起來更順")
                .font(.caption).foregroundStyle(.secondary)
            Button("選擇影片…") { pickFiles() }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in JobQueue.shared.add([url]) } }
                }
            }
            return true
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        panel.prompt = "轉換"
        if panel.runModal() == .OK { queue.add(panel.urls) }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(spacing: 12) {
            statusIcon.frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.input.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch job.status {
                case .waiting:
                    Text("等待中　\(job.settingsText)").font(.caption).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: job.progress)
                    Text(String(format: "%.0f%%　%@", job.progress * 100, job.settingsText))
                        .font(.caption).foregroundStyle(.secondary)
                case .done:
                    Text(String(format: "完成（%.0f 秒）→ %@", job.seconds, job.output?.lastPathComponent ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                case .skipped(let msg):
                    Text("略過：\(msg)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                case .failed(let msg):
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3)
                case .cancelled:
                    Text("已取消").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if job.status == .done, let out = job.output {
                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "forward.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}
