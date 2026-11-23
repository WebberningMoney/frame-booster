// main.swift — FrameBooster 的命令列版本（給想批次處理或寫腳本的人）。
// 實際轉檔都在 Converter.swift，這裡只負責讀參數、顯示進度。
//
//   frame-booster [--fps 120] [--fast] [-o OUTPUT] VIDEO...
//   frame-booster --info VIDEO...

import Foundation

func printErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let usage = """
用法：
  frame-booster [--fps 120] [--fast] [-o 輸出檔.mov] 影片1 [影片2 ...]
  frame-booster --info 影片...

  --fps N     目標幀率（預設 120；常用 60、120、144、240）
  --fast      速度優先（預設是品質優先）
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
    conv.progressHandler = { p in
        let elapsed = Date().timeIntervalSince(start)
        let eta = p > 0.02 ? elapsed / p - elapsed : 0
        let bar = String(repeating: "█", count: Int(p * 30)) + String(repeating: "░", count: 30 - Int(p * 30))
        let line = String(format: "\r%@%@ %@ %5.1f%%  剩餘約 %.0f 秒   ", label, url.lastPathComponent, bar, p * 100, eta)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    do {
        let out = try await conv.run()
        printErr(String(format: "\n✅ 完成（%.1f 秒）：%@", Date().timeIntervalSince(start), out.path))
    } catch let e as ConvertError where e.isSkip {
        printErr("\n⏭ 略過 \(url.lastPathComponent)：\(e.message)")
    } catch {
        printErr("\n❌ \(url.lastPathComponent)：\(error.localizedDescription)")
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
