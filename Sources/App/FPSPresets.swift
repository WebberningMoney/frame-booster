// FPSPresets.swift — 視窗版「目標幀率」下拉選單的選項，以及每個選項適合哪些裝置。
//
// 白話說明：
//   影片的 FPS 超過螢幕每秒能換幾次畫面（Hz）就沒有好處，只會讓檔案變大。
//   所以每個選項旁邊列出「螢幕夠快、能完整播出來」的代表裝置，幫使用者挑。
//   - menuTitle：下拉選單裡看到的那一行（簡短）
//   - fullDevices：滑鼠停在選單上時顯示的完整清單
//
// 裝置清單是 2026 年 11 月整理的，來源列在 README「FPS 選項與裝置對照」。
// 有新機種時，請同時更新這裡和 README。

struct FPSPreset: Identifiable, Hashable {
    let fps: Int32
    let shortDevices: String
    let fullDevices: String

    var id: Int32 { fps }
    var menuTitle: String { "\(fps) FPS — \(shortDevices)" }

    static let defaultFPS: Int32 = 120

    static let all: [FPSPreset] = [
        FPSPreset(
            fps: 60,
            shortDevices: "一般螢幕、電視、iPhone 17e、MacBook Air",
            fullDevices: """
            60 FPS：幾乎所有螢幕都能播，最通用。要上傳 YouTube、社群網站也選這個。
            • Apple：iPhone 17e、iPad Air、iPad、iPad mini、MacBook Air、iMac、Studio Display（一般版）
            • 電視：大多數電視；用 Apple TV 4K 播放時最高就是 60
            • 其他：一般辦公／家用螢幕
            """),
        FPSPreset(
            fps: 120,
            shortDevices: "iPhone 17／Pro、iPad Pro、MacBook Pro",
            fullDevices: """
            120 FPS：120Hz 螢幕，目前高階手機、平板、筆電的主流。
            • Apple：iPhone 17、iPhone Air、iPhone 17 Pro／Pro Max、iPad Pro、MacBook Pro、Studio Display XDR、Apple Vision Pro
            • Android 手機：Samsung Galaxy S26 系列、Google Pixel 10 Pro／Pro XL 等多數旗艦機
            • 遊戲機：Nintendo Switch 2、ROG Xbox Ally X
            • 電視：Sony Bravia 8 II、LG C5 等 120Hz 電視
            """),
        FPSPreset(
            fps: 144,
            shortDevices: "電競螢幕、電競手機、144Hz 電視",
            fullDevices: """
            144 FPS：電競螢幕與電競手機常見的規格。165Hz、185Hz 的裝置播 144 FPS 也很順。
            • 手機：RedMagic 11 Pro（144Hz）；OnePlus 15、ROG Phone 9 Pro 等更高更新率的手機也適用
            • 螢幕：AOC 24G51F、Samsung Odyssey G5、Dell SE2426HS 等入門電競螢幕
            • 電視：LG C5（搭配電腦）、TCL QM8K；165Hz 的 LG G5、Samsung S95F 也適用
            • Apple 目前沒有 144Hz 以上的裝置
            """),
        FPSPreset(
            fps: 240,
            shortDevices: "高階電競螢幕（ASUS ROG、MSI、Samsung Odyssey 等）",
            fullDevices: """
            240 FPS：高階電競螢幕。檔案最大、轉最久，只有接上 240Hz 螢幕才看得出差別。
            • 螢幕：ASUS ROG Swift OLED PG32UCDM、MSI MPG 321URX、Samsung Odyssey G8（4K 240Hz）、LG UltraGear 32GX870B、Dell SE2426HGS
            • 手機、電視、Apple 裝置目前都沒有這麼高的更新率
            """),
    ]

    static func preset(for fps: Int32) -> FPSPreset {
        all.first { $0.fps == fps } ?? all.first { $0.fps == defaultFPS }!
    }
}
