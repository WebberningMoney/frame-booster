// App.swift — FrameBooster 的視窗程式（把影片拖進來就開始轉）。
//
// 白話說明：
//   - 先選「目標幀率」（60／120／144／240，預設 120）和「輸出位置」（預設原影片旁邊），再拖影片進來。
//     「進階設定」裡還有「補幀方式」（精細／快速）和「輸出畫質」（高／標準／省空間）。
//     這些設定在影片「加入時」就記下來，之後改設定只影響新加入的影片
//     （所以可以把同一支影片先用 120、再用 60 各轉一次）。
//   - 「輸出位置」選過的資料夾會記住（存在 App 的偏好設定裡），下次打開還在。
//   - 一次只轉一支，其他的排隊等（同時轉好幾支反而會更慢）。
//   - 轉好的檔案放在原影片旁邊（或選定的資料夾），檔名加上「_120fps」之類的字。原影片不會被修改。
//   - 轉檔中會顯示百分比和預估剩餘時間。
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
                .frame(minWidth: 640, minHeight: 560)
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

/// 一支影片的轉檔工作。內容只在主執行緒上修改（背景工作會用 MainActor.run／DispatchQueue.main 切回來），
/// 所以標成 @unchecked Sendable，讓它可以被帶進背景工作而不產生警告。
final class Job: ObservableObject, Identifiable, @unchecked Sendable {
    enum Status: Equatable { case waiting, running, done, skipped(String), failed(String), cancelled }
    let id = UUID()
    let input: URL
    let targetFPS: Int32              // 加入時選的目標幀率
    let highQuality: Bool             // 加入時選的補幀方式（true＝精細）
    let outputQuality: OutputQuality  // 加入時選的輸出畫質
    let outputDirectory: URL?         // 加入時選的輸出資料夾（nil＝原影片旁邊）
    @Published var progress: Double = 0
    @Published var remaining: Double?  // 預估還要幾秒；剛開始算不準時是 nil
    @Published var status: Status = .waiting
    @Published var output: URL?
    @Published var seconds: Double = 0
    init(input: URL, targetFPS: Int32, highQuality: Bool, outputQuality: OutputQuality, outputDirectory: URL?) {
        self.input = input; self.targetFPS = targetFPS; self.highQuality = highQuality
        self.outputQuality = outputQuality; self.outputDirectory = outputDirectory
    }
    /// 例如「→ 120 FPS・精細・標準畫質」（有選輸出資料夾時加上「・存到 影片輸出」）
    var settingsText: String {
        var t = "→ \(targetFPS) FPS・\(highQuality ? "精細" : "快速")・\(outputQuality.displayName)畫質"
        if let dir = outputDirectory { t += "・存到「\(dir.lastPathComponent)」" }
        return t
    }
    /// 例如「約 12 秒」「約 3 分 5 秒」
    static func formatRemaining(_ seconds: Double) -> String {
        let t = max(Int(seconds.rounded()), 0)
        return t < 60 ? "約 \(t) 秒" : "約 \(t / 60) 分 \(t % 60) 秒"
    }
}

@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()
    @Published var jobs: [Job] = []
    @Published var highQuality = true
    @Published var targetFPS: Int32 = FPSPreset.defaultFPS
    @Published var outputQuality: OutputQuality = .standard
    @Published var showAdvanced = false
    /// 輸出資料夾（nil＝原影片旁邊）。改了就存進 App 的偏好設定，下次打開還在。
    @Published var outputDirectory: URL? {
        didSet { UserDefaults.standard.set(outputDirectory?.path, forKey: Self.outputDirectoryKey) }
    }
    @Published private(set) var isRunning = false
    private var current: FrameRateConverter?
    private static let outputDirectoryKey = "outputDirectory"

    init() {
        // 讀回上次選的輸出資料夾；資料夾已經不存在就改回「原影片旁邊」
        if let path = UserDefaults.standard.string(forKey: Self.outputDirectoryKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }

    func add(_ urls: [URL]) {
        let videos = urls.flatMap { Self.expand($0) }
        jobs.append(contentsOf: videos.map {
            Job(input: $0, targetFPS: targetFPS, highQuality: highQuality,
                outputQuality: outputQuality, outputDirectory: outputDirectory)
        })
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
        opts.outputQuality = job.outputQuality
        opts.outputDirectory = job.outputDirectory
        let conv = FrameRateConverter(input: job.input, options: opts)
        current = conv
        let start = Date()
        conv.progressHandler = { p in
            // 預估剩餘時間＝已花時間 ÷ 進度 − 已花時間。剛開始（不到 3% 或 2 秒）太不準，先不顯示。
            let elapsed = Date().timeIntervalSince(start)
            let remaining: Double? = (p > 0.03 && elapsed > 2) ? elapsed / p - elapsed : nil
            DispatchQueue.main.async { job.progress = p; job.remaining = remaining }
        }
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

/// 拖放區的狀態（影片拖到上面時要變色）。
/// 注意：這裡刻意不用 SwiftUI 的 `@State`。新版 SDK 的 `@State` 是「巨集」，編譯時需要只有完整 Xcode 才有的
/// SwiftUIMacros 外掛；只裝「命令列開發者工具」會編譯失敗。改用 ObservableObject＋@StateObject 就沒有這個問題。
final class DropState: ObservableObject {
    @Published var targeted = false
}

struct ContentView: View {
    @EnvironmentObject var queue: JobQueue
    @StateObject private var drop = DropState()
    private var dropTargeted: Bool { drop.targeted }

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
            HStack(spacing: 8) {
                Text("輸出位置")
                Text(queue.outputDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "原影片旁邊")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(queue.outputDirectory?.path ?? "轉好的影片放在原影片所在的資料夾")
                Button("選擇資料夾…") { pickOutputFolder() }
                    .help("把轉好的影片統一放到某個資料夾。選過的資料夾會記住，下次打開還在。")
                if queue.outputDirectory != nil {
                    Button("改回原影片旁邊") { queue.outputDirectory = nil }
                }
                Spacer()
            }
            DisclosureGroup("進階設定", isExpanded: $queue.showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("補幀方式").frame(width: 64, alignment: .leading)
                        Picker("補幀方式", selection: $queue.highQuality) {
                            Text("精細").tag(true)
                            Text("快速").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .help("Apple 補幀引擎的設定。精細（預設）：引擎以畫面品質為優先，補出來的畫面通常比較自然，但比較慢。快速：引擎以速度為優先。Apple 沒有公開兩者內部的差別，也沒有其他參數可以調。改了只影響之後加入的影片。")
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text("輸出畫質").frame(width: 64, alignment: .leading)
                        Picker("輸出畫質", selection: $queue.outputQuality) {
                            ForEach(OutputQuality.allCases) { q in Text(q.displayName).tag(q) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                        .help("存檔時用多少資料量記錄畫面（＝檔案大小）。高：檔案約為標準的 1.5 倍，細節最多。標準（預設）。省空間：約為標準的 0.6 倍，畫面可能比較糊。改了只影響之後加入的影片。")
                        Spacer()
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 4)
            }
            HStack {
                Spacer()
                Button("取消全部") { queue.cancelAll() }.disabled(!queue.isRunning)
                Button("清除已完成") { queue.clearFinished() }
            }
            if queue.jobs.isEmpty {
                Spacer()
                Text(queue.outputDirectory.map { "轉好的影片會放在「\($0.lastPathComponent)」資料夾，檔名加上「_\(queue.targetFPS)fps」。" }
                     ?? "轉好的影片會放在原影片旁邊，檔名加上「_\(queue.targetFPS)fps」。")
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
        .onDrop(of: [UTType.fileURL], isTargeted: $drop.targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in JobQueue.shared.add([url]) } }
                }
            }
            return true
        }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        panel.message = "選擇轉好的影片要放在哪個資料夾"
        if panel.runModal() == .OK, let url = panel.url { queue.outputDirectory = url }
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
                    Text(String(format: "%.0f%%・%@　%@", job.progress * 100,
                                job.remaining.map { "剩餘" + Job.formatRemaining($0) } ?? "計算剩餘時間中…",
                                job.settingsText))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
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
