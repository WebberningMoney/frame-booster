// App.swift — FrameBooster 的視窗程式（拖進影片 → 勾選 → 按「開始轉檔」）。
//
// 白話說明：
//   - 把影片拖進來（或按「選擇影片…」）後，影片先停在「等待中」，而且**預設是勾選的**，不會馬上開始。
//   - 每一列前面有勾選框：可以只勾其中幾支（按住 Shift 再勾，可以一次勾一整段），也有「全選／全不選」。
//   - 選好「目標幀率」（60／120／144／240，預設 120）、「輸出位置」（預設原影片旁邊），
//     以及「進階設定」裡的「補幀方式」（精細／快速）和「輸出畫質」（高／標準／省空間），
//     再按「開始轉檔」：**勾選的**影片都用「按下那一刻」的設定轉；沒勾的留著不動。
//   - 已經轉完（或略過、失敗、取消）的影片也可以再勾選，用新的設定再轉一次（舊的輸出檔保留，新的另存一個檔）。
//     轉過的影片會自動取消勾選，避免下一輪不小心又轉一次。
//   - 每一列會依「目前的」目標幀率和輸出畫質，顯示原檔大小和預估轉完的大小，改設定就會跟著更新。
//   - 轉檔中「開始轉檔」不能按；這時新拖進來的影片會停在「等待中」，這一輪結束後再勾選、再按一次。
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
                .frame(minWidth: 720, minHeight: 600)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// 把影片拖到 Dock 或 Finder 裡的 App 圖示上時，會走到這裡（一樣先放在「等待中」）。
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            JobQueue.shared.add(urls)
            NSApp.activate()
        }
    }
}

// MARK: - 資料：每一支影片是一個 Job，JobQueue 負責排隊

/// 按下「開始轉檔」那一刻的設定。這一輪的每支影片都用同一份。
struct JobSettings {
    let targetFPS: Int32
    let highQuality: Bool             // 補幀方式（true＝精細）
    let outputQuality: OutputQuality
    let outputDirectory: URL?         // nil＝原影片旁邊

    /// 例如「→ 120 FPS・精細・標準畫質」（有選輸出資料夾時加上「・存到「影片輸出」」）
    var text: String {
        var t = "→ \(targetFPS) FPS・\(highQuality ? "精細" : "快速")・\(outputQuality.displayName)畫質"
        if let dir = outputDirectory { t += "・存到「\(dir.lastPathComponent)」" }
        return t
    }
}

/// 一支影片的轉檔工作。內容只在主執行緒上修改（背景工作會用 MainActor.run／DispatchQueue.main 切回來），
/// 所以標成 @unchecked Sendable，讓它可以被帶進背景工作而不產生警告。
///
/// 狀態的順序：
///   waiting（拖進來、還沒按開始）→ queued（按了開始，排隊中）→ running（轉檔中）
///   → done（完成）／skipped（不需要轉）／failed（失敗）／cancelled（取消）
final class Job: ObservableObject, Identifiable, @unchecked Sendable {
    enum Status: Equatable { case waiting, queued, running, done, skipped(String), failed(String), cancelled }
    let id = UUID()
    let input: URL
    @Published var settings: JobSettings?   // 按「開始轉檔」時才填入
    @Published var progress: Double = 0
    @Published var remaining: Double?       // 預估還要幾秒；剛開始算不準時是 nil
    @Published var status: Status = .waiting
    @Published var output: URL?
    @Published var seconds: Double = 0
    @Published var isChecked = true         // 勾選框；新加入的預設勾選
    @Published var basics: VideoBasics?     // 預估檔案大小用的影片資料（加入後在背景讀取）
    init(input: URL) { self.input = input }

    /// 可以勾選（＝可以被這一輪轉換）的狀態：還沒開始的，或已經結束的（可以再轉一次）
    var isSelectable: Bool { status == .waiting || isFinished }

    var isFinished: Bool {
        switch status {
        case .done, .skipped, .failed, .cancelled: return true
        default: return false
        }
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
    /// 這一輪是否還在轉（從按下「開始轉檔」到這一輪全部結束）
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

    /// 還沒按開始的影片數
    var waitingCount: Int { jobs.filter { $0.status == .waiting }.count }
    /// 勾選、而且可以轉的影片數（「開始轉檔」會轉這些）
    var checkedCount: Int { jobs.filter { $0.isChecked && $0.isSelectable }.count }
    /// 有沒有可以勾選的影片（決定要不要顯示「全選／全不選」）
    var hasSelectable: Bool { jobs.contains { $0.isSelectable } }
    /// 上一次點勾選框的那一列，給 Shift 連選用
    private var lastToggledID: UUID?
    /// 有沒有已結束（可以清除）的工作
    var hasFinished: Bool { jobs.contains { $0.isFinished } }

    /// 拖進來或選進來的影片：先放在「等待中」，按「開始轉檔」才會開始。
    func add(_ urls: [URL]) {
        let videos = urls.flatMap { Self.expand($0) }
        let newJobs = videos.map { Job(input: $0) }
        jobs.append(contentsOf: newJobs)
        // 在背景讀取每支影片的基本資料，讀到後每一列就能顯示原檔大小和預估大小
        for job in newJobs {
            let url = job.input
            Task.detached {
                let basics = try? await FrameRateConverter.basics(for: url)
                await MainActor.run { job.basics = basics }
            }
        }
    }

    /// 勾選或取消勾選一列。按住 Shift 時，從上一次點的那一列到這一列，整段都設成一樣。
    func setChecked(_ job: Job, _ checked: Bool, extendRange: Bool) {
        objectWillChange.send()
        if extendRange, let lastID = lastToggledID,
           let a = jobs.firstIndex(where: { $0.id == lastID }),
           let b = jobs.firstIndex(where: { $0.id == job.id }) {
            for j in jobs[min(a, b)...max(a, b)] where j.isSelectable { j.isChecked = checked }
        } else {
            job.isChecked = checked
        }
        lastToggledID = job.id
    }

    /// 「全選」／「全不選」：只影響可以勾選的列
    func setAllChecked(_ checked: Bool) {
        objectWillChange.send()
        for j in jobs where j.isSelectable { j.isChecked = checked }
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

    /// 按下「開始轉檔」：把目前的設定套用到所有「勾選」的影片（等待中的，或已結束要再轉一次的），排進這一輪並開始。
    /// 排進去的影片會自動取消勾選。沒勾的留著不動。
    /// 這一輪還在轉時不能再按（轉檔中新加入的影片會留在「等待中」，等這一輪結束後再勾選、再按一次）。
    func startRound() {
        guard !isRunning else { return }
        objectWillChange.send()
        let settings = JobSettings(targetFPS: targetFPS, highQuality: highQuality,
                                   outputQuality: outputQuality, outputDirectory: outputDirectory)
        for job in jobs where job.isChecked && job.isSelectable {
            job.settings = settings
            job.progress = 0
            job.remaining = nil
            job.output = nil
            job.seconds = 0
            job.isChecked = false
            job.status = .queued
        }
        startNext()
    }

    private func startNext() {
        guard !isRunning, let job = jobs.first(where: { $0.status == .queued }), let settings = job.settings else { return }
        isRunning = true
        job.status = .running
        var opts = ConvertOptions()
        opts.targetFPS = settings.targetFPS
        opts.highQuality = settings.highQuality
        opts.outputQuality = settings.outputQuality
        opts.outputDirectory = settings.outputDirectory
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
                self.startNext()      // 這一輪還有排隊的就繼續；沒有就結束這一輪
            }
        }
    }

    /// 「取消轉檔」：停止這一輪（正在轉的那支，做到一半的檔案會被刪掉；排隊中的不轉了）。
    /// 還沒按開始的「等待中」影片不受影響。
    func cancelRound() {
        for j in jobs where j.status == .queued { j.status = .cancelled }
        current?.cancel()
    }

    /// 從清單移除一支還沒開始、或已經結束的影片（不會刪除任何檔案）。
    func remove(_ job: Job) {
        guard job.isSelectable else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
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
                        .help("Apple 補幀引擎的設定。精細（預設）：引擎以畫面品質為優先，補出來的畫面通常比較自然，但比較慢。快速：引擎以速度為優先。Apple 沒有公開兩者內部的差別，也沒有其他參數可以調。按「開始轉檔」時套用；轉檔中改設定，會用在下一輪。")
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
                        .help("存檔時用多少資料量記錄畫面（＝檔案大小）。高：檔案約為標準的 1.5 倍，細節最多。標準（預設）。省空間：約為標準的 0.6 倍，畫面可能比較糊。按「開始轉檔」時套用；轉檔中改設定，會用在下一輪。")
                        Spacer()
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 4)
            }
            HStack {
                Button {
                    queue.startRound()
                } label: {
                    Text(queue.isRunning ? "轉檔中…"
                         : queue.checkedCount > 0 ? "開始轉檔（已勾選 \(queue.checkedCount) 支）" : "開始轉檔")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(queue.isRunning || queue.checkedCount == 0)
                .help("用目前的目標幀率、輸出位置和進階設定，轉換所有「勾選」的影片（沒勾的不會轉）。")
                Spacer()
                Button("取消轉檔") { queue.cancelRound() }
                    .disabled(!queue.isRunning)
                    .help("停止這一輪：正在轉的那支會停下（做到一半的檔案會刪掉），排隊中的不轉了。「等待中」的影片不受影響。")
                Button("清除已完成") { queue.clearFinished() }
                    .disabled(!queue.hasFinished)
                    .help("把已完成、略過、失敗、取消的影片從清單拿掉（不會刪除任何檔案）。")
            }
            if queue.isRunning && queue.waitingCount > 0 {
                Text("轉檔中新加入的 \(queue.waitingCount) 支影片，會在這一輪結束後，勾選後再按一次「開始轉檔」才開始。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if queue.jobs.isEmpty {
                Spacer()
                Text(queue.outputDirectory.map { "轉好的影片會放在「\($0.lastPathComponent)」資料夾，檔名加上「_\(queue.targetFPS)fps」。" }
                     ?? "轉好的影片會放在原影片旁邊，檔名加上「_\(queue.targetFPS)fps」。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                if queue.hasSelectable {
                    HStack(spacing: 8) {
                        Button("全選") { queue.setAllChecked(true) }
                        Button("全不選") { queue.setAllChecked(false) }
                        Text("小技巧：勾一支後，按住 Shift 再勾另一支，中間整段都會勾起來")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .controlSize(.small)
                }
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
    @EnvironmentObject var queue: JobQueue   // 讀目前的目標幀率和輸出畫質，算預估大小

    /// 檔案大小的顯示方式，例如「85.3 MB」「1.2 GB」
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            // 勾選框：只有「等待中」或「已結束（可以再轉一次）」的可以勾；按住 Shift 可以連選一整段
            Toggle("", isOn: Binding(
                get: { job.isChecked && job.isSelectable },
                set: { queue.setChecked(job, $0, extendRange: NSEvent.modifierFlags.contains(.shift)) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!job.isSelectable)
                .help(job.isSelectable ? "勾選的影片，按「開始轉檔」時會用目前的設定轉換。按住 Shift 再勾，可以一次勾一整段。"
                                       : "排隊中或轉檔中的影片不能勾選")
            statusIcon.frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.input.lastPathComponent).lineLimit(1).truncationMode(.middle)
                switch job.status {
                case .waiting:
                    Text(job.isChecked ? "等待中（已勾選，按「開始轉檔」後開始）" : "等待中（沒有勾選，不會轉）")
                        .font(.caption).foregroundStyle(.secondary)
                case .queued:
                    Text("排隊中　\(job.settings?.text ?? "")").font(.caption).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: job.progress)
                    Text(String(format: "%.0f%%・%@　%@", job.progress * 100,
                                job.remaining.map { "剩餘" + Job.formatRemaining($0) } ?? "計算剩餘時間中…",
                                job.settings?.text ?? ""))
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
                if let line = sizeLine {
                    Text(line).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if job.status == .done, let out = job.output {
                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
            if job.isSelectable {
                Button { queue.remove(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("從清單移除（不會刪除任何檔案）")
            }
        }
        .padding(.vertical, 4)
    }

    /// 每一列的大小資訊：
    ///   - 等待中：依「目前的」目標幀率和輸出畫質預估（改設定會即時更新）
    ///   - 已結束、而且又勾選要再轉：一樣顯示預估
    ///   - 排隊中／轉檔中：依這一輪套用的設定預估
    private var sizeLine: String? {
        guard let b = job.basics else { return job.status == .waiting ? "讀取影片資訊中…" : nil }
        let original = Self.sizeFormatter.string(fromByteCount: b.fileBytes)
        let fps: Int32, quality: OutputQuality
        switch job.status {
        case .waiting:
            fps = queue.targetFPS; quality = queue.outputQuality
        case .queued, .running:
            guard let st = job.settings else { return nil }
            fps = st.targetFPS; quality = st.outputQuality
        default:
            guard job.isChecked else { return nil }
            fps = queue.targetFPS; quality = queue.outputQuality
        }
        if b.wouldSkip(targetFPS: fps) {
            return String(format: "原檔 %@・已經是 %.0f FPS，轉成 %ld FPS 會略過", original, b.nominalFPS, Int(fps))
        }
        let est = Self.sizeFormatter.string(fromByteCount: b.estimatedBytes(targetFPS: fps, quality: quality))
        return "原檔 \(original) → 預估約 \(est)（\(fps) FPS・\(quality.displayName)畫質，實際可能小一些）"
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.status {
        case .waiting: Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "forward.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}
