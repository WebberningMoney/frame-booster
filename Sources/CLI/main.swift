// main.swift — FrameBooster 的命令列版本（給想批次處理或寫腳本的人）。
// 實際轉檔都在 Converter.swift，這裡只負責讀參數、顯示進度。
//
//   frame-booster [--fps 120] [--fast] [--quality high|standard|compact] [--out-dir DIR | -o OUTPUT]
//                 [--skip-motion less|normal|more | --motion-threshold N] [--mark-skipped] VIDEO...
//   frame-booster --info VIDEO...
//   frame-booster --analyze VIDEO...      動作分析報告（調整「動作太大時不補幀」的門檻用，見 docs/MOTION_TUNING.md）

import Foundation

func printErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let usage = """
用法：
  frame-booster [--fps 120] [--fast] [--quality 畫質] [--out-dir 資料夾 | -o 輸出檔.mov] 影片1 [影片2 ...]
  frame-booster --info 影片...
  frame-booster --analyze 影片...

  --fps N     目標幀率（預設 120；常用 60、120、144、240）
  --fast      補幀方式改成「快速」（預設是「精細」）
  --quality Q 輸出畫質（檔案大小）：high（高）、standard（標準，預設）、compact（省空間）
  --out-dir D 轉好的影片放到資料夾 D（預設放在原影片旁邊）
  -o PATH     輸出檔名（只能用在單一影片）；預設在原檔旁邊產生「原檔名_120fps.mov」
  --info      只顯示影片資訊（解析度、幀率、畫面數）

動作太大時不補幀（減少快速動作周圍的波紋；詳細說明見 docs/MOTION_TUNING.md）：
  --skip-motion L       打開，L 是 less（少跳過）、normal（適中）、more（多跳過），和 App 進階設定的三段一樣
  --motion-threshold N  打開，直接指定門檻數字（動作分數超過 N 的地方不補幀），調整門檻時用
  --mark-skipped        標記版：沒補幀的畫面在四個角落加紅色小方塊，檔名多「_標記」（要搭配上面其中一個）
  --analyze             只分析、不轉檔：每 0.5 秒列出動作分數，並存成「原檔名_動作分析.csv」
"""

var args = Array(CommandLine.arguments.dropFirst())
var options = ConvertOptions()
var infoOnly = false
var analyzeOnly = false
var inputs: [URL] = []

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-h", "--help":
        print(usage); exit(0)
    case "--fast":
        options.highQuality = false
    case "--info":
        infoOnly = true
    case "--analyze":
        analyzeOnly = true
    case "--skip-motion":
        i += 1
        guard i < args.count, let level = MotionSkipLevel(rawValue: args[i]) else {
            printErr("--skip-motion 只能是 less（少跳過）、normal（適中）或 more（多跳過）"); exit(2)
        }
        options.motionThreshold = level.threshold
    case "--motion-threshold":
        i += 1
        guard i < args.count, let v = Double(args[i]), v > 0 else { printErr("--motion-threshold 需要大於 0 的數字，例如 5"); exit(2) }
        options.motionThreshold = v
    case "--mark-skipped":
        options.markSkipped = true
    case "--quality":
        i += 1
        guard i < args.count, let q = OutputQuality(rawValue: args[i]) else { printErr("--quality 只能是 high、standard 或 compact"); exit(2) }
        options.outputQuality = q
    case "--out-dir":
        i += 1
        guard i < args.count else { printErr("--out-dir 需要資料夾"); exit(2) }
        options.outputDirectory = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath, isDirectory: true)
    case "--fps":
        i += 1
        guard i < args.count, let v = Int32(args[i]), v > 0, v <= 240 else { printErr("--fps 需要 1–240 的數字"); exit(2) }
        options.targetFPS = v
    case "-o", "--output":
        i += 1
        guard i < args.count else { printErr("-o 需要檔名"); exit(2) }
        options.outputURL = URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath)
    default:
        inputs.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
    }
    i += 1
}

if inputs.isEmpty { print(usage); exit(2) }
if options.outputURL != nil && inputs.count > 1 { printErr("-o 只能搭配一支影片使用"); exit(2) }
if options.outputURL != nil && options.outputDirectory != nil { printErr("-o 和 --out-dir 只能擇一"); exit(2) }
if options.markSkipped && options.motionThreshold == nil {
    printErr("--mark-skipped 要搭配 --skip-motion 或 --motion-threshold 一起用"); exit(2)
}

/// 進度條要畫在哪裡：
///   - 直接在終端機執行：畫在畫面上（原地更新）。
///   - 輸出被導到檔案或 tee（例如安裝時同時寫進 install_log.txt）：
///       設了環境變數 FRAMEBOOSTER_TTY_PROGRESS=1（安裝腳本會設）→ 進度條直接畫在終端機視窗（/dev/tty），紀錄檔保持乾淨；
///       沒設 → 只在紀錄裡記 25%、50%、75% 幾個階段，避免紀錄檔被塞爆。
let progressIsInteractive = isatty(STDERR_FILENO) != 0
let progressTTY: FileHandle? = progressIsInteractive ? FileHandle.standardError
    : (ProcessInfo.processInfo.environment["FRAMEBOOSTER_TTY_PROGRESS"] == "1" ? FileHandle(forWritingAtPath: "/dev/tty") : nil)
final class Milestone { var value = 0 }

/// 進度條畫完後換行：在終端機上，讓下一行訊息從新的一行開始。
func endProgressLine() {
    progressTTY?.write("\n".data(using: .utf8)!)
}

var failures = 0

if infoOnly {
    for url in inputs {
        do {
            let info = try await FrameRateConverter.info(for: url)
            print("\(url.lastPathComponent): \(info)")
        } catch {
            printErr("\(url.lastPathComponent): \(error.localizedDescription)"); failures += 1
        }
    }
    exit(failures == 0 ? 0 : 1)
}

/// 印出動作分析報告，並把表格存成 CSV（原影片旁邊，或 --out-dir 指定的資料夾）。
func printMotionReport(_ r: MotionReport, for url: URL, seconds: Double) {
    let levels = MotionSkipLevel.allCases
    print("")
    print("=== 動作分析：\(url.lastPathComponent) ===")
    print(String(format: "影片長度 %.1f 秒、原始約 %.0f FPS；分析花了 %.1f 秒", r.duration, r.sourceFPS, seconds))
    print("動作分數＝畫面裡動得最猛的那一小塊（約 1% 面積），在兩張原始畫面之間移動了「畫面長邊的百分之幾」（已扣掉整個畫面一起移動的部分）")
    print("")
    print("門檻對照（分數超過門檻的地方不補幀）：")
    for l in levels {
        print(String(format: "  %@：門檻 %.1f → 會跳過 %.1f%% 的畫面間隔", l.displayName, l.threshold, r.skippedPercent(threshold: l.threshold)))
    }
    print(String(format: "分數分布：中間值 %.1f、90%% 的地方在 %.1f 以下、最大 %.1f",
                 r.percentile(50), r.percentile(90), r.percentile(100)))
    print("")
    print("時間      動作分數   少跳過  適中  多跳過")
    for seg in r.segments {
        let marks = levels.map { seg.maxScore > $0.threshold ? "  ✂  " : "  ·  " }.joined(separator: " ")
        print(String(format: "%@   %6.1f    ", MotionReport.timeText(seg.start), seg.maxScore) + marks)
    }
    print("（✂＝這一段會被跳過、不補幀；·＝照常補幀）")
    let csvURL = MotionReport.csvURL(for: url, in: options.outputDirectory)
    do {
        try r.csv().write(to: csvURL, atomically: true, encoding: .utf8)
        print("表格已存成：\(csvURL.path)")
    } catch {
        printErr("（表格存檔失敗：\(error.localizedDescription)）")
    }
}

if analyzeOnly {
    for url in inputs {
        do {
            let start = Date()
            let shown = Milestone()     // 每 0.5% 才更新一次畫面，避免輸出太多
            let report = try await MotionReport.analyze(url) { p in
                let step = Int(p * 200)
                guard step > shown.value else { return }
                shown.value = step
                progressTTY?.write(String(format: "\r分析中 %@ %5.1f%%   ", url.lastPathComponent, p * 100).data(using: .utf8)!)
            }
            endProgressLine()
            printMotionReport(report, for: url, seconds: Date().timeIntervalSince(start))
        } catch {
            endProgressLine()
            printErr("❌ \(url.lastPathComponent)：\(error.localizedDescription)"); failures += 1
        }
    }
    exit(failures == 0 ? 0 : 1)
}

for (n, url) in inputs.enumerated() {
    let label = inputs.count > 1 ? "[\(n + 1)/\(inputs.count)] " : ""
    let conv = FrameRateConverter(input: url, options: options)
    let start = Date()
    let lastMilestone = Milestone()
    conv.progressHandler = { p in
        guard let tty = progressTTY else {
            let m = Int(p * 4)          // 0…4 → 每 25% 記一次
            if m > lastMilestone.value && m < 4 {
                lastMilestone.value = m
                printErr("  \(url.lastPathComponent)：\(m * 25)%")
            }
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let eta = p > 0.02 ? elapsed / p - elapsed : 0
        let bar = String(repeating: "█", count: Int(p * 30)) + String(repeating: "░", count: 30 - Int(p * 30))
        let line = String(format: "\r%@%@ %@ %5.1f%%  剩餘約 %.0f 秒   ", label, url.lastPathComponent, bar, p * 100, eta)
        tty.write(line.data(using: .utf8)!)
    }
    do {
        let out = try await conv.run()
        endProgressLine()
        printErr(String(format: "✅ 完成（%.1f 秒）：%@", Date().timeIntervalSince(start), out.path))
        if options.motionThreshold != nil {
            printErr("   動作太大、沒補幀：\(conv.skippedPairs) 處（共量了 \(conv.analyzedPairs) 處）")
        }
        if let problem = conv.markerProblem {
            printErr("   ⚠️ 標記版的紅色小方塊沒有畫上：\(problem)")
        }
    } catch let e as ConvertError where e.isSkip {
        endProgressLine()
        printErr("⏭ 略過 \(url.lastPathComponent)：\(e.message)")
    } catch {
        endProgressLine()
        printErr("❌ \(url.lastPathComponent)：\(error.localizedDescription)")
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
