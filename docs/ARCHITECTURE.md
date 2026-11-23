# FrameBooster 是怎麼組成的

> 給想看懂或修改程式的人。一般使用者請看 [README](../README.md)。

## 一張圖看懂

```text
原始影片 (.mov/.mp4)
   │
   ▼
AVAssetReader ──解碼──► 一張張原始畫面 ──► FrameGenerator（排時間格線）
   │                                          │
   │                            落在格子上 → 直接用原圖
   │                            在兩格之間 → VTFrameProcessor（Apple AI）補出畫面
   │                                          │
   └──聲音（原封不動）──────────────┐          ▼
                                   ▼   AVAssetWriter ──HEVC 壓縮──► 原檔名_120fps.mov
```

全部用 macOS 內建的框架（AVFoundation、VideoToolbox、CoreVideo），沒有任何第三方套件，也不連網。

## 檔案一覽

| 檔案 | 負責什麼 |
|---|---|
| `Sources/Converter.swift` | 核心。`FrameRateConverter` 負責整個轉檔流程；`FrameGenerator` 決定每一格放什麼畫面；`VideoInfo` 讀影片資訊 |
| `Sources/App/App.swift` | 視窗版（SwiftUI）：拖放、排隊、進度條、品質／速度切換 |
| `Sources/CLI/main.swift` | 命令列版：讀參數、顯示進度、`--info` |
| `Resources/Info.plist` | App 的名稱、版本、最低系統版本（15.4）、可以接受拖放影片 |
| `assets/AppIcon.iconset` | 圖示原始圖片，編譯時用 `iconutil` 組成 `.icns` |
| `scripts/build.sh` | 用 `swiftc` 編譯兩個程式到 `build/`，並做本機簽章（ad-hoc） |
| `scripts/selftest.sh` | 轉換 `test/sample_30fps.mp4`，檢查畫面數、幀率、聲音 |
| `安裝.command` | 檢查電腦 → 編譯 → 自我測試 → 複製到「應用程式」 |
| `解除安裝.command` | 確認後從「應用程式」移除 App |

為什麼不用 Xcode 專案：用 `swiftc` 直接編譯，只需要免費的「命令列開發者工具」，不用安裝好幾 GB 的 Xcode，專案檔也比較單純。

## 補幀怎麼算：時間格線

輸出影片有一條固定的時間格線：**每 1/120 秒一格**，第 0 格對齊第一張原始畫面的時間。

每讀到一張新的原始畫面 **b**，就處理「上一張 **a** 到 b 之間」的格子：

| 格子的位置 | 做法 |
|---|---|
| 剛好在 a 上（位置比例 < 0.002） | 直接用 a 的原圖 |
| 在 a、b 中間（例如 0.25、0.5、0.75） | 把這些比例一次交給 AI，補出那幾刻的畫面 |
| a、b 相隔超過 0.5 秒（`maxInterpolationGap`） | 不補，全部延續 a（避免螢幕錄影停住時硬補出怪畫面） |
| 最後一張原始畫面之後 | 延續它原本的長度（沒有下一張可以補） |

用「時間」而不是「第幾張」來算，所以：

- 30 FPS → 每兩張之間剛好 3 格補幀＋1 格原圖。
- 29.97 FPS、或幀率忽快忽慢（手機在暗處常這樣）的影片，也會對齊到正確的時間；偶爾某兩張之間是 2 格或 4 格補幀。
- 時間重複或倒退的畫面會被略過。

## Apple 的 AI 補幀（VTFrameProcessor）

- macOS 15.4 起提供，在 WWDC25 的〈Enhance your app with machine-learning-based video effects〉介紹。
- 用法：`startSession(configuration:)` 開始 → 每一對畫面呼叫一次 `process(parameters:completionHandler:)` → `endSession()`。
- `VTFrameRateConversionConfiguration`：設定解析度、品質優先（`.quality`）或速度優先（`.normal`）。
- `VTFrameRateConversionParameters`：來源畫面 a、下一張 b、要補的位置比例（`interpolationPhase`）、裝結果的空白畫面。
- 連續處理時用 `.sequential` 模式（引擎可以沿用上一輪算好的動作資訊）；中間有跳過時改用 `.random`。
- 引擎對記憶體格式有要求（`sourcePixelBufferAttributes`），所以解碼出來的畫面會先用 `VTPixelTransferSession` 複製到符合要求的記憶體。
- 新舊 SDK 的 Swift 介面略有不同（例如 `isSupported` / `processorSupported`），程式用 `#if compiler(>=6.2)` 兩邊都支援。

## 色彩與 HDR

- 讀取原始影片的色彩標記（色域、轉換曲線、矩陣）。
- 是 HDR（HLG 或 PQ）或 10-bit 影片 → 用 10-bit 處理，輸出 HEVC Main10，並標上原本的色彩標記，iPhone 會當 HDR 播放。
- 一般影片 → 8-bit。
- 色彩標記如果寫入器不接受，就不標（避免整個轉檔失敗）。

## 聲音

- 能原封不動複製就直接複製（不重新壓縮，音質不變）。
- 格式放不進 `.mov` 時，才重新壓成 AAC 立體聲（48 kHz、256 kbps）。
- 影像和聲音在不同的工作線上同時寫入；寫入器出錯時，等聲音最多 5 秒就放棄，避免卡死。

## 輸出設定

| 項目 | 設定 | 原因 |
|---|---|---|
| 容器 | `.mov` | Apple 裝置原生支援，可以裝的聲音格式比 `.mp4` 多 |
| 影像編碼 | HEVC（H.265），硬體編碼 | 檔案小、Apple 裝置都能硬體解碼 |
| 位元率 | 原檔的 2 倍（最低 6 Mbps、最高 250 Mbps） | 畫面變 4 倍，但補出來的畫面和前後很像，很好壓縮。這個倍數還沒有在實機上調校過 |
| 關鍵畫面間隔 | 每 2 秒一張 | 拖動進度條時反應比較快 |
| 方向 | 沿用原檔的旋轉設定 | 直拍的手機影片不會變橫的 |
| 檔名 | `原檔名_120fps.mov`，重複時加「 2」「 3」… | 絕不覆蓋任何檔案 |

## 設計決定

| 決定 | 原因 |
|---|---|
| 用 Apple 內建 AI，不用 RIFE 等開源模型 | 不用下載模型、不用 Python 環境，直接用 Apple 晶片的神經網路引擎；Apple 也在 Compressor／Final Cut Pro 用類似技術做影格重定時 |
| 一次只轉一支 | 補幀和 HEVC 編碼都很吃硬體，同時轉多支不會比較快 |
| 安裝時一定跑自我測試 | 這個專案無法在雲端沙盒測試，用測試影片在使用者的 Mac 上確認「真的轉得出來、真的是 120 FPS」才安裝 |
| 不做剪接點偵測（目前） | 120 FPS 下剪接點的殘影只有約 1/40 秒；之後若有需要再加 |

## 只能在真的 Mac 上驗證的事

雲端沙盒（Linux）沒有 macOS 的框架，下面這些都要在 Mac 上確認：

- 能不能編譯（Swift 版本、SDK 版本差異）
- AI 補幀的品質與速度
- HDR 影片轉完是否仍是 HDR、在 iPhone 上播放是否正常
- 聲音是否同步
- 直拍影片方向是否正確
- 拖放、Dock 圖示拖放、「在 Finder 中顯示」
- macOS 的檔案存取詢問（桌面、下載項目、文件）
