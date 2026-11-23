# 給 AI 助理（Claude 等）的協作守則

> 這份檔案是寫給「幫忙改這個專案的 AI 助理」看的。每次開始工作前請先讀完並照做。
> 一般使用者不需要看這份，請看 [README](README.md)。

## 1. 開始工作前：先設定 git

在這個專案資料夾執行：

```bash
git config core.hooksPath scripts/git-hooks      # 啟用專案內建的自動檢查
git config commit.gpgsign false                  # 不要自動簽章
git config user.name  "$(git log -1 --format=%an origin/main)"   # 作者＝專案擁有者（Webber Huang）
git config user.email "$(git log -1 --format=%ae origin/main)"
git config framebooster.owneremail "$(git log -1 --format=%ae origin/main)"
git config core.quotepath false                  # 讓中文檔名正常顯示
```

為什麼：

- **作者必須是專案擁有者**，AI 助理只放在 commit 訊息最後的 `Co-Authored-By:`。
  雲端沙盒的預設 git 身分是 Claude，在擁有者的其他專案曾讓一整串 commit 的作者都變成 Claude，事後得改寫歷史。
- **不要簽章**。沙盒會用它自己的金鑰簽 commit，那把金鑰沒有登記在擁有者的 GitHub 帳號，GitHub 會標成 **Unverified**。
- `scripts/git-hooks/` 的檢查會在 commit 和 push 前擋下上面兩種情況；推送後請再用
  `gh api repos/WebberningMoney/frame-booster/commits --jq '.[0] | .author.login, .commit.verification.reason'` 確認（應為擁有者、`unsigned`）。
- 需要改寫歷史或強制推送時，**一定要先問擁有者**。

## 2. 每次改了程式或畫面：一定要重新檢查文件與註解

**每一次**變更程式碼或畫面，都要 review 並更新相關說明。請照這個順序做：

1. **程式註解**：改到的檔案，開頭那段白話說明還正確嗎？改到的函式，註解有沒有過時？
2. **畫面文字**：新增的選項有沒有用 `.help(...)` 加上滑鼠停留說明？提示文字是不是白話？
3. **README.md**：每天怎麼用、名詞小辭典、效果與限制、隱私、常見問題、檔案列表。
4. **docs/ARCHITECTURE.md**：處理流程、時間格線怎麼算、檔案一覽、設計決定。
5. **CHANGELOG.md**：在 `[Unreleased]` 記下這次改了什麼（用使用者看得懂的話）。
6. **測試**：在 Mac 上執行 `bash scripts/build.sh && bash scripts/selftest.sh`（安裝時也會自動跑）。

commit 時如果改了程式卻沒有動到任何文件，`pre-commit` 會擋下來。

## 3. 寫作風格

- 所有文件、註解、畫面文字都用**繁體中文**，而且要**最白話**：讓沒有程式或影片背景的人也能輕鬆看懂。
- 專業名詞第一次出現要解釋，或改用白話說法（例：frame interpolation →「補幀」、bitrate →「位元率（每秒用多少資料量記錄畫面）」）。
- 判斷與建議一律寫成「可能」「可以試試」，不要把推測寫成定論。
  **沒有在真的 Mac 上量過的數字（速度、檔案大小）不要寫成事實。**
- 畫面要簡單乾淨：細節收進說明文字或 README。

## 4. 工作方式

- 需求有疑問時，**先跟擁有者釐清再動手寫程式**。
- 這個專案只能在 Mac（Apple 晶片、macOS 15.4 以上）上編譯和執行：AI 補幀、HEVC 壓縮都是 macOS 內建功能，
  雲端沙盒（Linux）**沒辦法編譯也沒辦法測試**。修改後要誠實說明「哪些已在 Mac 上驗證、哪些還沒有」，
  並請擁有者雙擊 `安裝.command`（會自動編譯＋自我測試），或讀取 `build/install_log.txt` 確認結果。
- **絕不修改、覆蓋或刪除原始影片**。輸出一律寫成新檔（`原檔名_120fps.mov`），檔名重複時自動加上編號。
  轉檔失敗或取消時，只刪除這次做到一半的輸出檔。
- 這個工具**完全不連網**。若要新增任何對外連線，先問擁有者，並寫進 README 的「隱私」一節。
- 不可復原的動作（例如解除安裝）在腳本裡都要有確認步驟。
