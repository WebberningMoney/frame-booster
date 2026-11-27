// Motion.swift — 「動作太大時不補幀」用到的東西（進階設定裡的選項，預設關閉）。
//
// 白話說明：
//   AI 補幀遇到「動得很猛」的地方（離鏡頭很近又快的手、甩動的頭髮、互相遮住的東西）容易猜錯，
//   在輪廓周圍產生像水波一樣的扭曲。打開這個選項後：
//     1. 每兩張原始畫面，先用 Apple 內建的「動作追蹤」（光流，optical flow：算出畫面裡每一塊往哪裡移動了多少）
//        量出「動作分數」。
//     2. 分數超過門檻 → 這兩張中間不讓 AI 補，直接重複前一張原始畫面（那一瞬間回到原本 30 FPS 的感覺）。
//     3. 沒超過 → 照常補幀。
//
// 動作分數怎麼算（白話）：
//   「畫面裡動得最猛的那一小塊（約 1% 的面積），在兩張畫面之間移動了多遠」，用「畫面長邊的百分之幾」表示。
//   例如 5 ＝ 移動了畫面長邊的 5%（1080p 直式影片的長邊 1920 像素，就是約 96 像素）。
//   會先扣掉「整個畫面一起移動」的部分（手持晃動、鏡頭平移），因為 AI 很擅長處理整體平移，
//   真正容易出錯的是「某個東西自己動得很猛」。
//
// 這個檔案裡有：
//   - MotionSkipLevel：App 裡的三段（少跳過／適中／多跳過）和各自的門檻數字
//   - MotionAnalyzer：算動作分數
//   - MotionReport：命令列「動作分析」的報告（只有數字，不轉檔）
//   - SkipMarker：「標記版影片」在被跳過的畫面四個角落畫紅色小方塊（調整門檻時用）
//
// 門檻數字是開發者先估的，還沒用真的影片驗證過。調整方法見 docs/MOTION_TUNING.md；
// 改門檻時，要同步更新那份文件裡的對照表。

import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import CoreMedia

/// App「進階設定」裡的三段。門檻越低，越多地方會被跳過（波紋越少，但越多瞬間回到 30 FPS 的感覺）。
enum MotionSkipLevel: String, CaseIterable, Identifiable {
    case less, normal, more
    var id: String { rawValue }

    /// 畫面上顯示的名字
    var displayName: String {
        switch self {
        case .less: return "少跳過"
        case .normal: return "適中"
        case .more: return "多跳過"
        }
    }

    /// 動作分數超過這個數字就不補幀。
    /// ⚠️ 開發者先估的數字，還沒用真的影片驗證；調整後要同步更新 docs/MOTION_TUNING.md 的對照表。
    var threshold: Double {
        switch self {
        case .less: return 8.0
        case .normal: return 5.0
        case .more: return 3.0
        }
    }
}

// MARK: - 算動作分數

/// 用 Apple 的動作追蹤（VTOpticalFlow，macOS 15.4 起）量兩張畫面之間的動作。
/// 為了快，先把畫面縮小（長邊 640 像素）再分析；分數用「畫面長邊的百分比」表示，所以縮小不影響分數的意思。
/// 只在一條工作線上使用。
final class MotionAnalyzer: @unchecked Sendable {
    /// 分析時把畫面長邊縮到這麼大
    static let analysisLongSide = 640

    private let processor = VTFrameProcessor()
    private let width: Int
    private let height: Int
    private let smallPool: CVPixelBufferPool
    private let flowPool: CVPixelBufferPool
    private let transfer: VTPixelTransferSession
    /// 最近縮小過的畫面（用時間對應），同一張畫面不用縮兩次
    private var cache: [(pts: CMTime, buf: CVPixelBuffer)] = []
    private var lastNext: CMTime?

    static var isSupported: Bool {
        #if compiler(>=6.2)
        return VTOpticalFlowConfiguration.isSupported
        #else
        return VTOpticalFlowConfiguration.processorSupported
        #endif
    }

    init(sourceWidth: Int, sourceHeight: Int) throws {
        guard MotionAnalyzer.isSupported else {
            throw ConvertError("這台 Mac 不支援 Apple 的動作追蹤，無法使用「動作太大時不補幀」。請把這個選項關掉再轉。")
        }
        let longSide = max(sourceWidth, sourceHeight, 1)
        let scale = min(1.0, Double(MotionAnalyzer.analysisLongSide) / Double(longSide))
        var w = max(Int((Double(sourceWidth) * scale).rounded()) / 2 * 2, 64)
        var h = max(Int((Double(sourceHeight) * scale).rounded()) / 2 * 2, 64)
        var candidate = VTOpticalFlowConfiguration(frameWidth: w, frameHeight: h, qualityPrioritization: .normal,
                                                   revision: VTOpticalFlowConfiguration.defaultRevision)
        if candidate == nil {
            // 縮小後的大小不被接受時，改用原尺寸分析（比較慢，但一定能跑）
            w = sourceWidth; h = sourceHeight
            candidate = VTOpticalFlowConfiguration(frameWidth: w, frameHeight: h, qualityPrioritization: .normal,
                                                   revision: VTOpticalFlowConfiguration.defaultRevision)
        }
        guard let config = candidate else { throw ConvertError("Apple 的動作追蹤不支援這個解析度（\(sourceWidth)x\(sourceHeight)）。") }
        width = w; height = h

        #if compiler(>=6.2)
        let formats: [OSType] = config.supportedPixelFormats
        #else
        let formats: [OSType] = config.frameSupportedPixelFormats.map { $0.uint32Value }
        #endif
        let f8 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let format = formats.contains(f8) ? f8 : (formats.first ?? f8)
        let srcAttrs: [String: Any] = config.sourcePixelBufferAttributes
        let dstAttrs: [String: Any] = config.destinationPixelBufferAttributes
        smallPool = try FrameRateConverter.makePool(srcAttrs, width: w, height: h, format: format)
        flowPool = try MotionAnalyzer.makeFlowPool(dstAttrs, width: w, height: h)

        var sessionOut: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &sessionOut) == noErr,
              let session = sessionOut else {
            throw ConvertError("無法建立動作分析用的像素轉換工作階段。")
        }
        transfer = session
        try processor.startSession(configuration: config)
    }

    deinit {
        processor.endSession()
        VTPixelTransferSessionInvalidate(transfer)
    }

    /// 動作分數：a → b 之間，「扣掉整體移動後、動得最猛的約 1% 面積」移動了畫面長邊的百分之幾。
    func score(from a: (buf: CVPixelBuffer, pts: CMTime), to b: (buf: CVPixelBuffer, pts: CMTime)) throws -> Double {
        let sa = try small(a.buf, pts: a.pts)
        let sb = try small(b.buf, pts: b.pts)
        guard let forward = newFlowBuffer(), let backward = newFlowBuffer(),
              let flow = VTFrameProcessorOpticalFlow(forwardFlow: forward, backwardFlow: backward),
              let src = VTFrameProcessorFrame(buffer: sa, presentationTimeStamp: a.pts),
              let next = VTFrameProcessorFrame(buffer: sb, presentationTimeStamp: b.pts) else {
            throw ConvertError("無法配置動作分析用的記憶體。")
        }
        // 連續的畫面用 .sequential，引擎可以沿用上一輪的資訊，比較快
        let mode: VTOpticalFlowParameters.SubmissionMode = (lastNext == a.pts) ? .sequential : .random
        guard let params = VTOpticalFlowParameters(sourceFrame: src, nextFrame: next, submissionMode: mode,
                                                   destinationOpticalFlow: flow) else {
            throw ConvertError("動作分析參數無效。")
        }
        let sem = DispatchSemaphore(value: 0)
        let err = MotionBox<Error?>(nil)
        processor.process(parameters: params) { _, error in
            err.value = error
            sem.signal()
        }
        sem.wait()
        if let e = err.value { throw ConvertError("動作分析失敗：\(e.localizedDescription)") }
        lastNext = b.pts
        let pixels = try Self.residualMotionPixels(forward)
        return pixels / Double(max(width, height)) * 100
    }

    /// 把畫面縮小到分析用的大小（同一張畫面只縮一次）
    private func small(_ image: CVPixelBuffer, pts: CMTime) throws -> CVPixelBuffer {
        if let hit = cache.first(where: { $0.pts == pts }) { return hit.buf }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, smallPool, &out) == kCVReturnSuccess, let dst = out else {
            throw ConvertError("無法配置動作分析用的畫面。")
        }
        let status = VTPixelTransferSessionTransferImage(transfer, from: image, to: dst)
        guard status == noErr else { throw ConvertError("縮小畫面失敗（\(status)）。") }
        cache.append((pts, dst))
        if cache.count > 2 { cache.removeFirst(cache.count - 2) }
        return dst
    }

    private func newFlowBuffer() -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, flowPool, &out) == kCVReturnSuccess else { return nil }
        return out
    }

    private static func makeFlowPool(_ attrs: [String: Any], width: Int, height: Int) throws -> CVPixelBufferPool {
        var a = attrs
        a[kCVPixelBufferWidthKey as String] = width
        a[kCVPixelBufferHeightKey as String] = height
        if a[kCVPixelBufferPixelFormatTypeKey as String] == nil {
            a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_TwoComponent16Half
        }
        if a[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                             a as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw ConvertError("無法配置動作資料的記憶體（\(status)）。") }
        return pool
    }

    /// 從動作資料（每個像素的 x、y 移動量）算出「扣掉整體移動後，第 99 百分位的移動距離」（單位：分析畫面的像素）。
    ///   1. 每隔一格取樣（夠準，又快 4 倍）。
    ///   2. x、y 各取中位數，當成「整個畫面一起移動」的量（手持晃動、平移），先扣掉。
    ///   3. 剩下的移動距離由小排到大，取第 99%（＝動得最猛的那約 1% 面積）。
    static func residualMotionPixels(_ flow: CVPixelBuffer) throws -> Double {
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { throw ConvertError("讀不到動作資料。") }
        let format = CVPixelBufferGetPixelFormatType(flow)
        let w = CVPixelBufferGetWidth(flow), h = CVPixelBufferGetHeight(flow)
        let rowBytes = CVPixelBufferGetBytesPerRow(flow)

        var xs: [Float] = [], ys: [Float] = []
        xs.reserveCapacity((w / 2 + 1) * (h / 2 + 1)); ys.reserveCapacity(xs.capacity)
        for row in stride(from: 0, to: h, by: 2) {
            let line = base + row * rowBytes
            for col in stride(from: 0, to: w, by: 2) {
                let dx: Float, dy: Float
                switch format {
                case kCVPixelFormatType_TwoComponent16Half:
                    dx = Float(line.load(fromByteOffset: col * 4, as: Float16.self))
                    dy = Float(line.load(fromByteOffset: col * 4 + 2, as: Float16.self))
                case kCVPixelFormatType_TwoComponent32Float:
                    dx = line.load(fromByteOffset: col * 8, as: Float.self)
                    dy = line.load(fromByteOffset: col * 8 + 4, as: Float.self)
                default:
                    throw ConvertError("不認得的動作資料格式（\(format)）。")
                }
                if dx.isFinite && dy.isFinite { xs.append(dx); ys.append(dy) }
            }
        }
        guard !xs.isEmpty else { return 0 }
        let mx = xs.sorted()[xs.count / 2]
        let my = ys.sorted()[ys.count / 2]
        var residual = [Float](repeating: 0, count: xs.count)
        for i in 0..<xs.count {
            let ex = xs[i] - mx, ey = ys[i] - my
            residual[i] = (ex * ex + ey * ey).squareRoot()
        }
        residual.sort()
        return Double(residual[Int(Double(residual.count - 1) * 0.99)])
    }
}

/// 給完成通知（在別的工作線呼叫）存結果用的小盒子
private final class MotionBox<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

// MARK: - 動作分析報告（命令列 --analyze：只分析、不轉檔）

/// 每 0.5 秒一段，記這一段裡最大的動作分數。
struct MotionReport {
    struct Segment {
        let start: Double      // 這一段從第幾秒開始
        let maxScore: Double   // 這一段裡最大的動作分數
    }
    static let segmentLength = 0.5

    var segments: [Segment] = []
    /// 每一組相鄰原始畫面的分數（算統計用）
    var pairScores: [Double] = []
    var duration: Double = 0
    var sourceFPS: Float = 0

    /// 這個門檻會跳過幾 % 的畫面間隔
    func skippedPercent(threshold: Double) -> Double {
        guard !pairScores.isEmpty else { return 0 }
        return Double(pairScores.filter { $0 > threshold }.count) / Double(pairScores.count) * 100
    }

    /// 分數的第 p 百分位（例如 50＝中間值、90＝比 90% 的地方都大）
    func percentile(_ p: Double) -> Double {
        guard !pairScores.isEmpty else { return 0 }
        let s = pairScores.sorted()
        return s[Int(Double(s.count - 1) * p / 100)]
    }

    /// 時間的寫法，例如「1:05.5」
    static func timeText(_ t: Double) -> String {
        let tenths = Int((t * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    /// 表格檔（CSV）的內容。開頭加 BOM，用 Excel／Numbers 打開時中文才不會變亂碼。
    func csv() -> String {
        var lines = ["\u{FEFF}時間,開始秒,動作分數,少跳過,適中,多跳過"]
        for s in segments {
            let marks = MotionSkipLevel.allCases.map { s.maxScore > $0.threshold ? "跳過" : "" }
            lines.append(String(format: "%@,%.1f,%.1f,", Self.timeText(s.start), s.start, s.maxScore)
                         + marks.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 分析一支影片：讀出每一張原始畫面，量相鄰兩張之間的動作分數。不轉檔、不寫影片。
    static func analyze(_ url: URL, maxGap: Double = 0.5, progress: ((Double) -> Void)? = nil) async throws -> MotionReport {
        FrameRateConverter.enableExtraDecoders()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ConvertError("檔案裡沒有影片軌。") }
        let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let analyzer = try MotionAnalyzer(sourceWidth: Int(size.width.rounded()), sourceHeight: Int(size.height.rounded()))

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard reader.canAdd(out) else { throw ConvertError("無法解碼這支影片。") }
        reader.add(out)
        guard reader.startReading() else {
            throw ConvertError("無法開始讀取影片：\(reader.error?.localizedDescription ?? "未知錯誤")")
        }

        var report = MotionReport()
        report.duration = duration
        report.sourceFPS = fps
        var segmentMax: [Int: Double] = [:]
        var prev: (buf: CVPixelBuffer, pts: CMTime)?
        var first: CMTime?
        while let sb = out.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard pts.isValid else { continue }
            if first == nil { first = pts }
            if let a = prev {
                let gap = (pts - a.pts).seconds
                if gap <= 1e-6 { continue }
                if gap <= maxGap {
                    let s = try analyzer.score(from: a, to: (image, pts))
                    report.pairScores.append(s)
                    let t = (a.pts - first!).seconds
                    let k = Int(t / segmentLength)
                    segmentMax[k] = max(segmentMax[k] ?? 0, s)
                }
            }
            prev = (image, pts)
            if duration > 0 { progress?(min((pts - first!).seconds / duration, 1)) }
        }
        if reader.status == .failed {
            throw ConvertError("讀取影片時發生錯誤：\(reader.error?.localizedDescription ?? "未知錯誤")")
        }
        report.segments = segmentMax.keys.sorted().map { Segment(start: Double($0) * segmentLength, maxScore: segmentMax[$0]!) }
        progress?(1)
        return report
    }

    /// 報告表格檔要存在哪裡：原影片旁邊（或指定的資料夾），檔名「原檔名_動作分析.csv」，不覆蓋已有的檔案。
    static func csvURL(for input: URL, in directory: URL? = nil) -> URL {
        let dir = directory ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + "_動作分析"
        var url = dir.appendingPathComponent(base).appendingPathExtension("csv")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("csv")
            n += 1
        }
        return url
    }
}

// MARK: - 標記版影片的紅色小方塊

/// 在畫面的四個角落畫紅色小方塊，標出「這張是因為動作太大而沒有補幀的畫面」。
/// 四個角落都畫，是因為直拍影片播放時會旋轉，左上角不一定還在左上角。
/// 只用在「標記版影片」（調整門檻時用），一般轉檔不會畫。
enum SkipMarker {
    static func draw(on buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else { return }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        // 紅色的 Y（亮度）、Cb、Cr 值（BT.709，8-bit）
        let (yv, cbv, crv) = fullRange ? (54, 99, 255) : (63, 102, 240)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let size = max(min(w, h) / 12, 8) / 2 * 2
        let corners = [(0, 0), (w - size, 0), (0, h - size), (w - size, h - size)]

        func put(_ line: UnsafeMutableRawPointer, _ index: Int, _ v8: Int) {
            if tenBit {
                line.storeBytes(of: UInt16(min(v8 * 4, 1023) << 6), toByteOffset: index * 2, as: UInt16.self)
            } else {
                line.storeBytes(of: UInt8(min(v8, 255)), toByteOffset: index, as: UInt8.self)
            }
        }
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let rb = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for (x0, y0) in corners {
                for r in y0..<min(y0 + size, h) {
                    let line = luma + r * rb
                    for c in x0..<min(x0 + size, w) { put(line, c, yv) }
                }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let rb = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let cw = CVPixelBufferGetWidthOfPlane(buffer, 1), ch = CVPixelBufferGetHeightOfPlane(buffer, 1)
            for (x0, y0) in corners {
                for r in (y0 / 2)..<min((y0 + size) / 2, ch) {
                    let line = chroma + r * rb
                    for c in (x0 / 2)..<min((x0 + size) / 2, cw) {
                        put(line, c * 2, cbv)
                        put(line, c * 2 + 1, crv)
                    }
                }
            }
        }
    }
}
