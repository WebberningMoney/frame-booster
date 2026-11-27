// Converter.swift — FrameBooster 的核心：把影片「補幀」成更高的幀率（例如 30 → 120 FPS）。
//
// 白話說明：
//   影片其實是一張一張的照片（影格）快速播放。30 FPS 代表每秒 30 張。
//   要變成 120 FPS，就要在每兩張原始畫面之間「猜」出 3 張中間的畫面。
//   猜畫面這件事交給 Apple 內建在 macOS 裡的 AI（VideoToolbox 的 VTFrameProcessor，
//   macOS 15.4 起提供，在 Apple 晶片上執行），不需要另外下載模型，也完全不連網。
//
// 處理流程（細節見 docs/ARCHITECTURE.md）：
//   1. AVAssetReader 把原始影片一張張解開（解碼）。
//   2. FrameGenerator 在「每 1/120 秒一格」的時間格線上排好要輸出的畫面：
//      剛好落在原始畫面上的格子直接用原圖，中間的格子交給 AI 補出來。
//   3. AVAssetWriter 把所有畫面壓成 HEVC（H.265）存成 .mov；聲音原封不動複製過去。
//   原始影片只會被讀取，絕不會被修改或刪除。
//   也能讀 VP9 格式的影片（網站下載的 .mp4 常見）：程式會先打開 macOS 內建、預設沒啟用的 VP9 解碼器。
//   輸出檔會標上「用原本的幀率正常播放」，避免 iPhone「照片」把 120 FPS 影片當成慢動作。
//
// 進階設定「動作太大時不補幀」打開時，每兩張原始畫面會先量「動作分數」（Motion.swift），
// 分數超過門檻就不補幀、直接重複前一張原始畫面，避免 AI 在動得很猛的地方猜錯、產生波紋。
//
// 另外提供 VideoBasics：快速讀出影片長度、資料量等，讓畫面在轉檔前先「預估轉好後的大小」；
// 預估和實際壓縮用的是同一個位元率公式（videoBitrate）。

import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import CoreMedia

/// 輸出畫質：決定壓縮時「每秒用多少資料量」記錄畫面（位元率），也就是檔案大小。
/// 和補幀方式（精細／快速）無關：補幀決定「補出來的畫面像不像」，這裡決定「存檔時壓得多狠」。
enum OutputQuality: String, CaseIterable, Identifiable {
    case high, standard, compact
    var id: String { rawValue }
    /// 畫面上顯示的名字
    var displayName: String {
        switch self { case .high: return "高"; case .standard: return "標準"; case .compact: return "省空間" }
    }
    /// 乘在「標準」位元率上的倍數
    var bitrateMultiplier: Double {
        switch self { case .high: return 1.5; case .standard: return 1.0; case .compact: return 0.6 }
    }
    /// 最低位元率（每秒多少 bit），避免原本壓得很小的影片轉完太糊
    var minimumBitrate: Double {
        switch self { case .high: return 8_000_000; case .standard: return 6_000_000; case .compact: return 3_000_000 }
    }
}

struct ConvertOptions {
    var targetFPS: Int32 = 120
    /// 補幀方式：true＝精細（Apple 引擎的「品質優先」），false＝快速（「效能優先」）。
    var highQuality: Bool = true
    /// 輸出畫質（檔案大小）
    var outputQuality: OutputQuality = .standard
    /// 輸出資料夾。nil 代表放在原影片旁邊。
    var outputDirectory: URL? = nil
    /// 兩張原始畫面相隔超過這麼多秒時就不補幀，直接延續前一張
    ///（例如螢幕錄影時畫面停住很久，硬補只會產生怪畫面）。
    var maxInterpolationGap: Double = 0.5
    /// 直接指定輸出檔（命令列的 -o）。nil 代表自動命名：「原檔名_120fps.mov」，放在 outputDirectory 或原影片旁邊。
    var outputURL: URL? = nil
    /// 「動作太大時不補幀」的門檻（動作分數，見 Motion.swift）。nil＝關閉（每個地方都補幀，預設）。
    var motionThreshold: Double? = nil
    /// 標記版影片：因為動作太大而沒補幀的畫面，在四個角落加紅色小方塊（調整門檻時用）。
    /// 自動命名時檔名會多「_標記」，例如「原檔名_60fps_標記.mov」。只有 motionThreshold 有設定時才有作用。
    var markSkipped = false
}

struct ConvertError: LocalizedError {
    let message: String
    /// true＝不是出錯，而是「不需要轉」（例如影片已經是目標幀率以上），畫面上顯示成「略過」。
    let isSkip: Bool
    init(_ message: String, isSkip: Bool = false) { self.message = message; self.isSkip = isSkip }
    var errorDescription: String? { message }
}

/// 影片的基本資訊（`frame-booster --info` 和安裝時的自我測試會用到）。
struct VideoInfo: CustomStringConvertible {
    var width = 0, height = 0
    var nominalFPS: Float = 0
    var frameCount = 0
    var duration: Double = 0
    var codec = ""
    var audioTracks = 0
    var transfer = ""
    /// 「用原本的幀率正常播放」標記：1＝正常速度、0＝慢動作、-1＝沒有標記
    var fullFrameRate = -1
    var measuredFPS: Double { duration > 0 ? Double(frameCount) / duration : 0 }
    var description: String {
        String(format: "%ldx%ld  codec=%@  nominal=%.2f fps  frames=%ld  duration=%.3fs  measured=%.2f fps  audioTracks=%ld  transfer=%@  fullFrameRate=%@",
               width, height, codec, nominalFPS, frameCount, duration, measuredFPS, audioTracks, transfer.isEmpty ? "-" : transfer,
               fullFrameRate < 0 ? "-" : String(fullFrameRate))
    }
}

// 關於「@unchecked Sendable」：
//   影像和聲音在不同的工作線上同時處理，Swift 編譯器會檢查「被帶到別條工作線的東西是否安全」（Sendable）。
//   AVFoundation 的讀寫物件沒有標成 Sendable，但這個程式保證每個物件只在固定的一條工作線上使用
//  （或有上鎖），所以用 @unchecked Sendable 告訴編譯器「這裡由我們自己負責」，避免一大堆警告。

/// 預估檔案大小用的影片基本資料。
struct VideoBasics {
    let duration: Double        // 秒
    let nominalFPS: Float
    let videoDataRate: Double   // 原檔影像每秒多少 bit
    let width: Int
    let height: Int
    let audioDataRate: Double   // 原檔聲音每秒多少 bit（聲音會原封不動複製）
    let fileBytes: Int64        // 原檔大小

    /// 用這組設定轉換時，會不會被「略過」（影片已經是目標幀率以上）
    func wouldSkip(targetFPS: Int32) -> Bool { nominalFPS >= Float(targetFPS) - 0.5 }

    /// 預估輸出檔大小（byte）＝（影像位元率＋聲音位元率）× 長度 ÷ 8。
    /// 實測（M2 Pro、720p、1 分 55 秒、120 FPS 高畫質）實際比預估多約 2%，可能是 .mov 檔本身的格式資料。
    func estimatedBytes(targetFPS: Int32, quality: OutputQuality) -> Int64 {
        let video = FrameRateConverter.videoBitrate(sourceDataRate: videoDataRate, width: width, height: height,
                                                    nominalFPS: nominalFPS, targetFPS: targetFPS, quality: quality)
        return Int64((video + audioDataRate) * duration / 8)
    }
}

/// 可以被工作線共用的小盒子（只在同一條工作線上讀寫）。
private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

/// 影像這條工作線要用到的物件，包在一起交給它。
private final class VideoPipe: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let generator: FrameGenerator
    init(reader: AVAssetReader, writer: AVAssetWriter, input: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, generator: FrameGenerator) {
        self.reader = reader; self.writer = writer; self.input = input
        self.adaptor = adaptor; self.generator = generator
    }
}

/// 一條聲音軌要用到的物件（每個聲音軌各一條工作線）。
private final class AudioPipe: @unchecked Sendable {
    let writer: AVAssetWriter
    let output: AVAssetReaderTrackOutput
    let input: AVAssetWriterInput
    init(writer: AVAssetWriter, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.writer = writer; self.output = output; self.input = input
    }
}

/// 記住「第一個發生的錯誤」。好幾條工作線同時在跑，所以要上鎖避免互相覆蓋。
private final class FirstError: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Error?
    var value: Error? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ e: Error) { lock.lock(); if _value == nil { _value = e }; lock.unlock() }
}

final class FrameRateConverter: @unchecked Sendable {
    let inputURL: URL
    let options: ConvertOptions
    /// 進度回報（0～1），會在背景執行緒呼叫。
    var progressHandler: ((Double) -> Void)?

    private let cancelLock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelled }
    func cancel() { cancelLock.lock(); _cancelled = true; cancelLock.unlock() }

    /// 「動作太大時不補幀」打開時，轉完後記錄：量了幾組相鄰畫面、其中幾組因為動作太大沒有補幀。
    private(set) var analyzedPairs = 0
    private(set) var skippedPairs = 0
    /// 標記版：紅色小方塊畫不上去時的原因（nil＝沒問題）。命令列會顯示出來。
    private(set) var markerProblem: String?

    init(input: URL, options: ConvertOptions = ConvertOptions()) {
        self.inputURL = input
        self.options = options
    }

    // MARK: - 輸出檔名（不會覆蓋已存在的檔案，會自動加上 2、3…）

    /// suffix：檔名最後再加的字（標記版影片用「_標記」）。
    static func defaultOutputURL(for input: URL, fps: Int32, in directory: URL? = nil, suffix: String = "") -> URL {
        let dir = directory ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + "_\(fps)fps" + suffix
        var url = dir.appendingPathComponent(base).appendingPathExtension("mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("mov")
            n += 1
        }
        return url
    }

    // MARK: - 主流程

    /// 轉換一支影片，完成後回傳輸出檔的位置。失敗或取消時會刪掉做到一半的輸出檔（不會動到原檔）。
    func run() async throws -> URL {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Frame rate conversion")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let fps = options.targetFPS
        Self.enableExtraDecoders()
        let asset = AVURLAsset(url: inputURL)

        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ConvertError("無法讀取這個檔案（\(inputURL.lastPathComponent)）。macOS 只支援 .mov / .mp4 / .m4v 等格式，.webm / .mkv 需要先轉成 mp4。\n\(error.localizedDescription)")
        }
        guard let vTrack = videoTracks.first else { throw ConvertError("檔案裡沒有影片軌。") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let (naturalSize, transform, nominalFPS, dataRate, formatDescs) = try await vTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let duration = try await asset.load(.duration)
        let width = Int(naturalSize.width.rounded()), height = Int(naturalSize.height.rounded())

        if nominalFPS >= Float(fps) - 0.5 {
            throw ConvertError(String(format: "這支影片已經是 %.0f FPS，不需要轉成 %ld FPS。", nominalFPS, Int(fps)), isSkip: true)
        }

        // ---- 原始影片的色彩資訊：iPhone 拍的 HDR 要維持 HDR（10-bit），一般影片用 8-bit ----
        var transfer: String?
        var colorProps: [String: Any]?
        var bits = 8
        if let fd = formatDescs.first,
           let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
            transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String
            let primaries = ext[kCVImageBufferColorPrimariesKey as String] as? String
            let matrix = ext[kCVImageBufferYCbCrMatrixKey as String] as? String
            if let p = primaries, let t = transfer, let m = matrix {
                colorProps = [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
            }
            if let b = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int { bits = b }
        }
        let hlg = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        let isHDR = transfer == hlg || transfer == pq
        let wantTenBit = isHDR || bits > 8

        // ---- 準備 Apple 的 AI 補幀引擎（品質優先 / 速度優先） ----
        #if compiler(>=6.2)
        let supported = VTFrameRateConversionConfiguration.isSupported
        #else
        let supported = VTFrameRateConversionConfiguration.processorSupported
        #endif
        guard supported else { throw ConvertError("這台 Mac 不支援 Apple 的影格率轉換（需要 Apple 晶片與 macOS 15.4 以上）。") }

        guard let config = VTFrameRateConversionConfiguration(
            frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
            qualityPrioritization: options.highQuality ? .quality : .normal,
            revision: VTFrameRateConversionConfiguration.defaultRevision) else {
            throw ConvertError("Apple 影格率轉換不支援這個解析度（\(width)x\(height)）。")
        }

        #if compiler(>=6.2)
        let supportedFormats: [OSType] = config.supportedPixelFormats
        #else
        let supportedFormats: [OSType] = config.frameSupportedPixelFormats.map { $0.uint32Value }
        #endif
        let f10 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let f8 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let f8full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let pixelFormat: OSType
        if wantTenBit && supportedFormats.contains(f10) { pixelFormat = f10 }
        else if supportedFormats.contains(f8) { pixelFormat = f8 }
        else if supportedFormats.contains(f8full) { pixelFormat = f8full }
        else if let first = supportedFormats.first { pixelFormat = first }
        else { pixelFormat = f8 }
        let tenBitOut = (pixelFormat == f10)

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }

        let srcAttrs: [String: Any] = config.sourcePixelBufferAttributes
        let dstAttrs: [String: Any] = config.destinationPixelBufferAttributes
        let srcPool = try Self.makePool(srcAttrs, width: width, height: height, format: pixelFormat)
        let dstPool = try Self.makePool(dstAttrs, width: width, height: height, format: pixelFormat)

        var transferSessionOpt: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSessionOpt) == noErr,
              let transferSession = transferSessionOpt else { throw ConvertError("無法建立像素轉換工作階段。") }
        defer { VTPixelTransferSessionInvalidate(transferSession) }

        // ---- 「動作太大時不補幀」：打開時才準備動作分析（關閉時完全不會多做事） ----
        var motion: MotionAnalyzer?
        if options.motionThreshold != nil {
            motion = try MotionAnalyzer(sourceWidth: width, sourceHeight: height)
        }

        // ---- 讀取器：把原始影片解碼成一張張畫面 ----
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ConvertError("無法解碼這支影片。") }
        reader.add(videoOut)

        // ---- 寫入器：HEVC 壓縮。位元率（＝檔案大小）依兩件事決定：
        //      1. 畫面變成幾倍：倍數 ÷ 2，最少 1.5 倍（30→60 約 1.5 倍、→120 約 2 倍、→144 約 2.4 倍、→240 約 4 倍）。
        //         補出來的畫面和前後很像、很好壓縮，所以不需要跟著畫面數等比例增加。
        //      2. 輸出畫質：高 ×1.5、標準 ×1、省空間 ×0.6。 ----
        if let dir = options.outputDirectory {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  FileManager.default.isWritableFile(atPath: dir.path) else {
                throw ConvertError("輸出資料夾不存在或無法寫入：\(dir.path)")
            }
        }
        let marking = options.markSkipped && options.motionThreshold != nil
        let outURL = options.outputURL ?? Self.defaultOutputURL(for: inputURL, fps: fps, in: options.outputDirectory,
                                                                 suffix: marking ? "_標記" : "")
        // 安全檢查：絕不覆蓋原影片（例如命令列 -o 不小心指定成原檔）
        if outURL.standardizedFileURL.resolvingSymlinksInPath() == inputURL.standardizedFileURL.resolvingSymlinksInPath() {
            throw ConvertError("輸出檔不能和原影片是同一個檔案。")
        }
        // 只有命令列明確用 -o 指定檔名時，才會取代同名的舊輸出檔；自動命名一定不會重複。
        if FileManager.default.fileExists(atPath: outURL.path) {
            try FileManager.default.removeItem(at: outURL)
        }
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        // 標記「這支影片要用原本的幀率、正常速度播放」。沒有這個標記時，iPhone 的「照片」和 Mac 的
        // QuickTime Player 會把 120 FPS 以上的影片當成「慢動作」，中間一段放慢播放（要手動把速度調回 100%）。
        writer.metadata = [Self.fullFrameRatePlaybackItem()]

        let bitrate = Int(Self.videoBitrate(sourceDataRate: Double(dataRate), width: width, height: height,
                                            nominalFPS: nominalFPS, targetFPS: fps, quality: options.outputQuality))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(fps),
            AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
        ]
        if tenBitOut {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let colorProps {
            var withColor = videoSettings
            withColor[AVVideoColorPropertiesKey] = colorProps
            if writer.canApply(outputSettings: withColor, forMediaType: .video) { videoSettings = withColor }
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ConvertError("HEVC 編碼器不接受這個設定（\(width)x\(height)）。")
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        guard writer.canAdd(videoIn) else { throw ConvertError("無法建立輸出影片軌。") }
        writer.add(videoIn)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: nil)

        // 聲音：能原封不動複製就直接複製；格式放不進 .mov 時才重新壓成 AAC 立體聲。
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for aTrack in audioTracks {
            let fds = try await aTrack.load(.formatDescriptions)
            let passOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            let passIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fds.first)
            if reader.canAdd(passOut) && writer.canAdd(passIn) {
                reader.add(passOut); writer.add(passIn)
                audioPairs.append((passOut, passIn))
                continue
            }
            let pcmOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
            ])
            let aacIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 256_000,
            ])
            if reader.canAdd(pcmOut) && writer.canAdd(aacIn) {
                reader.add(pcmOut); writer.add(aacIn)
                audioPairs.append((pcmOut, aacIn))
            }
        }

        guard reader.startReading() else {
            let reason = reader.error?.localizedDescription ?? "未知錯誤"
            if let fd = formatDescs.first, let name = Self.webCodecName(fd) {
                throw ConvertError("這支影片的畫面是 \(name) 格式（常見於從網站下載的影片），這台 Mac 沒辦法讀取。"
                                   + "可以先用免費的 HandBrake 把它轉成 H.264 或 H.265 的 MP4，再拖進來。（\(reason)）")
            }
            throw ConvertError("無法開始讀取影片：\(reason)")
        }
        guard writer.startWriting() else {
            throw ConvertError("無法開始寫入：\(writer.error?.localizedDescription ?? "未知錯誤")")
        }

        // ---- 畫面產生器（只在 videoQueue 這條工作線上使用） ----
        let gen = FrameGenerator(
            targetFPS: fps, maxGap: options.maxInterpolationGap,
            fallbackFrameDuration: nominalFPS > 0 ? 1.0 / Double(nominalFPS) : 1.0 / 30.0,
            processor: processor, srcPool: srcPool, dstPool: dstPool,
            transferSession: transferSession, readerOutput: videoOut,
            motion: motion, motionThreshold: options.motionThreshold ?? .infinity, markSkipped: marking)

        // 先讀第一張畫面，用它的時間當作輸出檔的起點，之後聲音才能開始寫入。
        guard try gen.prime() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw ConvertError("影片裡讀不到任何畫面。")
        }
        writer.startSession(atSourceTime: gen.origin)

        let group = DispatchGroup()        // 等影像寫完
        let audioGroup = DispatchGroup()
        let failure = FirstError()
        let totalSeconds = max(duration.seconds, 0.001)
        let lastReported = Box(-1.0)

        // 影像：寫入器說「還吃得下」時，就一直餵下一張畫面
        group.enter()
        let videoQueue = DispatchQueue(label: "framebooster.video")
        let videoDone = Box(false)
        let vp = VideoPipe(reader: reader, writer: writer, input: videoIn, adaptor: adaptor, generator: gen)
        videoIn.requestMediaDataWhenReady(on: videoQueue) { [self] in
            if videoDone.value { return }
            let finish = {
                if videoDone.value { return }
                videoDone.value = true
                vp.input.markAsFinished()
                group.leave()
            }
            while vp.input.isReadyForMoreMediaData {
                if self.isCancelled { failure.set(ConvertError("已取消")); vp.reader.cancelReading(); finish(); return }
                do {
                    guard let item = try vp.generator.next() else { finish(); return }
                    let (buffer, time) = item
                    if !vp.adaptor.append(buffer, withPresentationTime: time) {
                        failure.set(vp.writer.error ?? ConvertError("寫入影格失敗"))
                        vp.reader.cancelReading(); finish(); return
                    }
                    let p = min(max((time - vp.generator.origin).seconds / totalSeconds, 0), 1)
                    if p - lastReported.value >= 0.005 { lastReported.value = p; self.progressHandler?(p) }
                } catch {
                    failure.set(error); vp.reader.cancelReading(); finish(); return
                }
            }
        }

        // 聲音：同時在另一條工作線複製
        for (i, (out, input)) in audioPairs.enumerated() {
            audioGroup.enter()
            let q = DispatchQueue(label: "framebooster.audio.\(i)")
            let done = Box(false)
            let ap = AudioPipe(writer: writer, output: out, input: input)
            input.requestMediaDataWhenReady(on: q) {
                if done.value { return }
                while ap.input.isReadyForMoreMediaData {
                    if ap.writer.status != .writing {
                        done.value = true; audioGroup.leave(); return
                    }
                    if let sb = ap.output.copyNextSampleBuffer() {
                        if !ap.input.append(sb) {
                            done.value = true; ap.input.markAsFinished(); audioGroup.leave(); return
                        }
                    } else {
                        done.value = true; ap.input.markAsFinished(); audioGroup.leave(); return
                    }
                }
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }

        if let err = failure.value {
            // 讀取已經停止，聲音很快就會結束；但寫入器出錯時可能不再要資料，所以最多等 5 秒。
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async { c.resume(returning: audioGroup.wait(timeout: .now() + 5) == .success) }
            }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw err
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw ConvertError("讀取影片時發生錯誤：\(reader.error?.localizedDescription ?? "未知錯誤")")
        }
        // 影像寫完了，等聲音寫完（最多等 2 分鐘，避免卡死）。
        let audioFinished: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { c.resume(returning: audioGroup.wait(timeout: .now() + 120) == .success) }
        }
        if !audioFinished || writer.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw ConvertError("寫入音訊失敗：\(writer.error?.localizedDescription ?? "逾時")")
        }
        if let end = gen.lastOutputTime {
            writer.endSession(atSourceTime: end + CMTime(value: 1, timescale: fps))
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outURL)
            throw ConvertError("寫入輸出檔失敗：\(writer.error?.localizedDescription ?? "未知錯誤")")
        }
        analyzedPairs = gen.analyzedPairs
        skippedPairs = gen.skippedPairs
        markerProblem = gen.markerProblem
        progressHandler?(1)
        return outURL
    }

    // MARK: - 小工具

    static func makePool(_ attrs: [String: Any], width: Int, height: Int, format: OSType) throws -> CVPixelBufferPool {
        var a = attrs
        a[kCVPixelBufferWidthKey as String] = width
        a[kCVPixelBufferHeightKey as String] = height
        a[kCVPixelBufferPixelFormatTypeKey as String] = format
        if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                             a as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw ConvertError("無法配置影格記憶體（\(status)）。") }
        return pool
    }

    /// 輸出影片的位元率（每秒多少 bit）。實際轉檔和「預估檔案大小」都用這一個算法，兩邊才會一致。
    static func videoBitrate(sourceDataRate: Double, width: Int, height: Int,
                             nominalFPS: Float, targetFPS: Int32, quality: OutputQuality) -> Double {
        let source = sourceDataRate > 0 ? sourceDataRate : Double(width * height) * 8
        let frameRatio = Double(targetFPS) / Double(max(nominalFPS, 1))
        let factor = max(1.5, frameRatio / 2) * quality.bitrateMultiplier
        return min(max(source * factor, quality.minimumBitrate), 300_000_000)
    }

    /// 讀取「預估檔案大小」需要的影片基本資料（只讀檔頭資訊，很快）。
    static func basics(for url: URL) async throws -> VideoBasics {
        let asset = AVURLAsset(url: url)
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw ConvertError("沒有影片軌") }
        let (size, fps, rate) = try await v.load(.naturalSize, .nominalFrameRate, .estimatedDataRate)
        let duration = try await asset.load(.duration)
        var audioRate = 0.0
        for a in try await asset.loadTracks(withMediaType: .audio) {
            audioRate += Double(try await a.load(.estimatedDataRate))
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return VideoBasics(duration: max(duration.seconds, 0), nominalFPS: fps, videoDataRate: Double(rate),
                           width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                           audioDataRate: audioRate, fileBytes: bytes)
    }

    /// 打開 macOS 內建、但預設沒有啟用的影片解碼器（目前是 VP9）。
    /// VP9 是 Google 的影片格式，網站下載的 .mp4 有時候是這種格式。Apple 晶片的 Mac 有能力解 VP9，
    /// 但 App 要先呼叫 VTRegisterSupplementalVideoDecoderIfAvailable 開啟（Safari、Firefox、FFmpeg 也是這樣做）。
    /// 重複呼叫沒有關係；不支援的電腦上什麼事都不會發生。
    static func enableExtraDecoders() {
        VTRegisterSupplementalVideoDecoderIfAvailable(CMVideoCodecType(0x7670_3039))   // 'vp09'
    }

    /// 如果影片是網站常用、但 Mac 不一定能讀的格式（VP9、VP8、AV1），回傳它的名字；其他格式回傳 nil。
    static func webCodecName(_ fd: CMFormatDescription) -> String? {
        switch CMFormatDescriptionGetMediaSubType(fd) {
        case 0x7670_3039: return "VP9"   // 'vp09'
        case 0x7670_3038: return "VP8"   // 'vp08'
        case 0x6176_3031: return "AV1"   // 'av01'
        default: return nil
        }
    }

    /// 「用原本的幀率正常播放」標記（Apple 從 iOS 18／macOS 15 起支援的 QuickTime 影片資訊）。
    /// 值是 1＝正常速度播放；0＝當成慢動作。iPhone 自己拍的一般影片也會帶這個標記。
    static func fullFrameRatePlaybackItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyFullFrameRatePlaybackIntent.rawValue as NSString
        item.value = NSNumber(value: 1)
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    /// 讀取影片資訊。畫面數是實際一張張數出來的（不解碼，所以很快），比檔案標示的幀率可靠。
    static func info(for url: URL) async throws -> VideoInfo {
        enableExtraDecoders()
        let asset = AVURLAsset(url: url)
        var info = VideoInfo()
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw ConvertError("沒有影片軌") }
        let (size, fps, fds) = try await v.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
        info.width = Int(size.width); info.height = Int(size.height); info.nominalFPS = fps
        if let fd = fds.first {
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((sub >> $0) & 0xff))) }
            info.codec = String(chars)
            if let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
                info.transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String ?? ""
            }
        }
        info.audioTracks = try await asset.loadTracks(withMediaType: .audio).count
        // 有沒有「用原本的幀率正常播放」標記（自我測試會檢查轉好的影片有這個標記）
        let meta = (try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? []
        let intentKey = AVMetadataKey.quickTimeMetadataKeyFullFrameRatePlaybackIntent.rawValue
        if let item = meta.first(where: { ($0.key as? String) == intentKey }),
           let n = try? await item.load(.numberValue) {
            info.fullFrameRate = n.intValue
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(out)
        _ = reader.startReading()
        var first: CMTime?, last = CMTime.zero, lastDur = CMTime.zero
        while let sb = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sb)
            if n == 0 { continue }
            info.frameCount += n
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if first == nil || pts < first! { first = pts }
            if pts > last { last = pts; lastDur = CMSampleBufferGetDuration(sb) }
        }
        if let first {
            let d = lastDur.isValid && lastDur.seconds > 0 ? lastDur : CMTime(value: 1, timescale: CMTimeScale(max(fps, 1).rounded()))
            info.duration = (last - first + d).seconds
        }
        return info
    }
}

// MARK: - 畫面產生器

/// 決定「輸出的每一格要放什麼畫面」。
///
/// 輸出影片的時間格線是固定的：每 1/120 秒一格（第 0 格對齊第一張原始畫面）。
/// 每讀到一張新的原始畫面 b，就處理「上一張 a 到 b 之間」的格子：
///   - 格子剛好在 a 上 → 直接用 a 的原圖。
///   - 格子在 a、b 中間 → 算出位置比例（例如 0.25、0.5、0.75），請 AI 補出那一刻的畫面。
///   - a、b 相隔太久（超過 maxGap）→ 不補，延續 a。
///   - 「動作太大時不補幀」打開、而且 a→b 的動作分數超過門檻 → 不補，延續 a（標記版會在這些畫面畫紅色小方塊）。
/// 用時間來算比例，所以 29.97 FPS、幀率忽快忽慢的手機影片也能對齊。
final class FrameGenerator: @unchecked Sendable {
    private let fps: Int32
    private let maxGap: Double
    private let fallbackDuration: Double
    private let processor: VTFrameProcessor
    private let srcPool: CVPixelBufferPool
    private let dstPool: CVPixelBufferPool
    private let transferSession: VTPixelTransferSession
    private let readerOutput: AVAssetReaderTrackOutput
    private let motion: MotionAnalyzer?
    private let motionThreshold: Double
    private let markSkipped: Bool

    /// 量過動作分數的相鄰畫面組數、其中因為動作太大沒補幀的組數
    private(set) var analyzedPairs = 0
    private(set) var skippedPairs = 0
    /// 標記版：紅色小方塊畫不上去時的原因（nil＝沒問題）
    private(set) var markerProblem: String?
    private(set) var origin = CMTime.zero
    private(set) var lastOutputTime: CMTime?
    private var prev: (buf: CVPixelBuffer, pts: CMTime)?
    private var lastGap: Double
    private var nextSlot: Int64 = 0
    private var pending: [(CVPixelBuffer, CMTime)] = []
    private var lastProcessedNext: CMTime?
    private var finished = false

    init(targetFPS: Int32, maxGap: Double, fallbackFrameDuration: Double,
         processor: VTFrameProcessor, srcPool: CVPixelBufferPool, dstPool: CVPixelBufferPool,
         transferSession: VTPixelTransferSession, readerOutput: AVAssetReaderTrackOutput,
         motion: MotionAnalyzer? = nil, motionThreshold: Double = .infinity, markSkipped: Bool = false) {
        self.motion = motion; self.motionThreshold = motionThreshold; self.markSkipped = markSkipped
        self.fps = targetFPS; self.maxGap = maxGap; self.fallbackDuration = fallbackFrameDuration
        self.lastGap = fallbackFrameDuration
        self.processor = processor; self.srcPool = srcPool; self.dstPool = dstPool
        self.transferSession = transferSession; self.readerOutput = readerOutput
    }

    private func slotTime(_ k: Int64) -> CMTime {
        origin + CMTime(value: k, timescale: fps)
    }

    /// 讀到第一張原始畫面為止。影片裡完全沒有畫面時回傳 false。
    func prime() throws -> Bool {
        while prev == nil && pending.isEmpty {
            if finished { return false }
            try pump()
        }
        return true
    }

    /// 取得下一張要輸出的畫面；全部做完時回傳 nil。
    func next() throws -> (CVPixelBuffer, CMTime)? {
        while pending.isEmpty {
            if finished { return nil }
            try pump()
        }
        let item = pending.removeFirst()
        lastOutputTime = item.1
        return item
    }

    private func pump() throws {
        guard let sb = readerOutput.copyNextSampleBuffer() else {
            // 影片讀完了：最後一張原始畫面後面沒有下一張可以補，就讓它停留原本的長度。
            if let p = prev {
                let end = p.pts.seconds + lastGap
                var k = nextSlot
                while slotTime(k).seconds < end - 1e-6 {
                    pending.append((p.buf, slotTime(k))); k += 1
                }
                if k == nextSlot { pending.append((p.buf, slotTime(k))); k += 1 }
                nextSlot = k
                prev = nil
            }
            finished = true
            return
        }
        guard let image = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        let buf = try copyToProcessorBuffer(image)

        guard let a = prev else {
            origin = pts
            nextSlot = 0
            prev = (buf, pts)
            return
        }
        let gap = (pts - a.pts).seconds
        if gap <= 1e-6 { return } // 時間重複或倒退的畫面：略過

        // 找出落在 [a 的時間, b 的時間) 之間的格子，算出各自的位置比例
        var slots: [(Int64, Float)] = []
        var k = nextSlot
        while true {
            let t = slotTime(k).seconds
            if t >= pts.seconds - 1e-6 { break }
            let phase = (t - a.pts.seconds) / gap
            slots.append((k, Float(max(phase, 0))))
            k += 1
        }
        nextSlot = k

        if !slots.isEmpty {
            if gap > maxGap {
                for (slot, _) in slots { pending.append((a.buf, slotTime(slot))) }
            } else {
                var interp: [(Int64, Float)] = []
                for (slot, phase) in slots {
                    if phase < 0.002 {
                        pending.append((a.buf, slotTime(slot)))
                    } else {
                        interp.append((slot, min(phase, 0.998)))
                    }
                }
                var tooMuchMotion = false
                if !interp.isEmpty, let analyzer = motion {
                    let score = try analyzer.score(from: a, to: (buf, pts))
                    analyzedPairs += 1
                    if score > motionThreshold { tooMuchMotion = true; skippedPairs += 1 }
                }
                if !interp.isEmpty && tooMuchMotion {
                    // 動作太大：不讓 AI 猜，重複 a（標記版：用一張畫了紅色小方塊的複本）
                    let held = try markSkipped ? markedCopy(of: a.buf) : a.buf
                    for (slot, _) in interp { pending.append((held, slotTime(slot))) }
                } else if !interp.isEmpty {
                    let outs = try interpolate(from: a, to: (buf, pts), phases: interp.map { $0.1 },
                                               times: interp.map { slotTime($0.0) })
                    for (i, (slot, _)) in interp.enumerated() { pending.append((outs[i], slotTime(slot))) }
                }
            }
        }
        lastGap = gap
        prev = (buf, pts)
    }

    /// 把解碼出來的畫面複製到 AI 引擎要求格式的記憶體裡（直接用解碼器的記憶體，引擎可能不接受）。
    private func copyToProcessorBuffer(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, srcPool, &out) == kCVReturnSuccess, let dst = out else {
            throw ConvertError("無法配置來源影格。")
        }
        let status = VTPixelTransferSessionTransferImage(transferSession, from: image, to: dst)
        guard status == noErr else { throw ConvertError("複製來源影格失敗（\(status)）。") }
        CVBufferPropagateAttachments(image, dst)
        return dst
    }

    /// 標記版影片用：複製一張畫面，在四個角落畫紅色小方塊（原本那張不動，因為它還會當成原始畫面輸出）。
    /// 複本用一般的 4:2:0 格式另外建立，不用 AI 引擎的記憶體池：
    /// 引擎要求的記憶體格式不一定能讓程式直接畫上去（第一版就因為這樣，紅色小方塊沒有出現）。
    private func markedCopy(of image: CVPixelBuffer) throws -> CVPixelBuffer {
        let tenBit = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
            .contains(CVPixelBufferGetPixelFormatType(image))
        let format = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image), format,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess, let dst = out else {
            throw ConvertError("無法配置標記用的影格。")
        }
        let status = VTPixelTransferSessionTransferImage(transferSession, from: image, to: dst)
        guard status == noErr else { throw ConvertError("複製標記用的影格失敗（\(status)）。") }
        CVBufferPropagateAttachments(image, dst)
        if let problem = SkipMarker.draw(on: dst), markerProblem == nil { markerProblem = problem }
        return dst
    }

    /// 請 Apple 的 AI 在 a、b 兩張畫面之間，依 phases（0～1 的位置比例）補出畫面。
    /// 連續處理時用 .sequential 模式，引擎可以沿用上一輪算好的動作資訊，比較快。
    private func interpolate(from a: (buf: CVPixelBuffer, pts: CMTime), to b: (buf: CVPixelBuffer, pts: CMTime),
                             phases: [Float], times: [CMTime]) throws -> [CVPixelBuffer] {
        var dstBuffers: [CVPixelBuffer] = []
        var dstFrames: [VTFrameProcessorFrame] = []
        for t in times {
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, dstPool, &out) == kCVReturnSuccess, let buf = out,
                  let frame = VTFrameProcessorFrame(buffer: buf, presentationTimeStamp: t) else {
                throw ConvertError("無法配置輸出影格。")
            }
            dstBuffers.append(buf); dstFrames.append(frame)
        }
        guard let src = VTFrameProcessorFrame(buffer: a.buf, presentationTimeStamp: a.pts),
              let next = VTFrameProcessorFrame(buffer: b.buf, presentationTimeStamp: b.pts) else {
            throw ConvertError("無法建立來源影格。")
        }
        let mode: VTFrameRateConversionParameters.SubmissionMode =
            (lastProcessedNext == a.pts) ? .sequential : .random

        #if compiler(>=6.2)
        let params = VTFrameRateConversionParameters(
            sourceFrame: src, nextFrame: next, opticalFlow: nil,
            interpolationPhase: phases, submissionMode: mode, destinationFrames: dstFrames)
        #else
        let params = VTFrameRateConversionParameters(
            sourceFrame: src, nextFrame: next, opticalFlow: nil,
            interpolationPhase: phases.map { NSNumber(value: $0) }, submissionMode: mode, destinationFrames: dstFrames)
        #endif
        guard let params else { throw ConvertError("影格插補參數無效。") }

        let sem = DispatchSemaphore(value: 0)
        let err = Box<Error?>(nil)
        processor.process(parameters: params) { _, error in
            err.value = error
            sem.signal()
        }
        sem.wait()
        if let e = err.value { throw ConvertError("AI 插補失敗：\(e.localizedDescription)") }
        lastProcessedNext = b.pts
        for buf in dstBuffers { CVBufferPropagateAttachments(a.buf, buf) }
        return dstBuffers
    }
}
