# 相關工具與參考資料

## Apple 官方

- [Enhance your app with machine-learning-based video effects（WWDC25）](https://developer.apple.com/videos/play/wwdc2025/300/)：介紹 VTFrameProcessor 的影格率轉換、超解析度、動態模糊等效果
- [VideoToolbox：Frame processing](https://developer.apple.com/documentation/videotoolbox/frame-processing)：API 文件
- [VTFrameRateConversionConfiguration](https://developer.apple.com/documentation/videotoolbox/vtframerateconversionconfiguration)
- [VTFrameRateConversionParameters](https://developer.apple.com/documentation/videotoolbox/vtframerateconversionparameters)
- [Compressor release notes](https://support.apple.com/102745)：Apple 的付費轉檔軟體，也有用機器學習把影片轉成 60／90／120 fps 的功能

## 其他補幀工具（給想比較的人）

| 工具 | 說明 |
|---|---|
| [RIFE](https://github.com/hzwer/ECCV2022-RIFE) | 最常見的開源 AI 補幀模型，很多免費工具都是用它 |
| [rife-ncnn-vulkan](https://github.com/nihui/rife-ncnn-vulkan) | RIFE 的免安裝版本，Mac 上也能跑 |
| Topaz Video | 付費的影片強化軟體，有多種補幀模型（Apollo、Chronos 等），需要訂閱 |
| FFmpeg `minterpolate` 濾鏡 | 傳統的動作補償補幀，不用 AI，品質較普通 |

## 研究方向

- 近年也有用擴散模型（生成式 AI）做補幀的研究，例如 [FC-VFI（2026）](https://arxiv.org/abs/2603.04899)、[GIMM-VFI](https://arxiv.org/abs/2407.08680)，畫質可能更好，但目前速度還不適合一般使用。
