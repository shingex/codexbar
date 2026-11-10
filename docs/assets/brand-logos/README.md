# Active Card 品牌彩色Logo

来源：Lobe Icons @lobehub/icons 5.10.0，MIT许可。
仓库：https://github.com/lobehub/lobe-icons
固定提交：4b837f489c8fcff97c159917308a501632f92a25
源目录：packages/static-svg/icons

彩色资产内置于 codexBar/Assets.xcassets/BrandLogos，保留品牌色和渐变，不增加运行时下载或依赖。
适配：Gemini的透明渐变在本轮macOS原生SVG/PDF渲染中出现缺失，因此用WebKit将同一SVG离线渲染为512px透明PNG；原始SVG和render-svg.swift一并保留，可用 `swift render-svg.swift gemini-color.svg output.png` 重现。

SVG视口的em尺寸改为24px，图形路径不变；Kimi浅色模式只将白色主体改为黑色，蓝色品牌点不变，深色保留上游白色主体。

当前版本含Claude、Gemini、DeepSeek、Qwen、Kimi、Mistral彩色样式。其余品牌在该版本只有单色样式，沿用随系统深浅色适配的模板。
