// main.swift — FrameBooster 的命令列版本（給想批次處理或寫腳本的人）。
// 實際轉檔都在 Converter.swift，這裡只負責讀參數、顯示進度。
//
//   frame-booster [--fps 120] [--fast] [--quality high|standard|compact] [--out-dir DIR | -o OUTPUT] VIDEO...
//   frame-booster --info VIDEO...

import Foundation

func printErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let usage = """
用法：
  frame-booster [--fps 120] [--fast] [--quality 畫質] [--out-dir 資料夾 | -o 輸出檔.mov] 影片1 [影片2 ...]
  frame-booster --info 影片...

  --fps N     目標幀率（預設 120；常用 60、120、144、240）
  --fast      補幀方式改成「快速」（預設是「精細」）
  --quality Q 輸出畫質（檔案大小）：high（高）、standard（標準，預設）、compact（省空間）
  --out-dir D 轉好的影片放到資料夾 D（預設放在原影片旁邊）
  -o PATH     輸出檔名（只能用在單一影片）；預設在原檔旁邊產生「原檔名_120fps.mov」
  --info      只顯示影片資訊（解析度、幀率、畫面數）
"""

var args = Array(CommandLine.arguments.dropFirst())
var options = ConvertOptions()
var infoOnly = false
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
