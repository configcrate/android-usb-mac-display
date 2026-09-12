# Android USB Mac Display

[English](README.en.md) · [首轮测试步骤](docs/TESTING.zh-CN.md) · [ConfigCrate](https://configcrate.com/)

让 Android 手机或平板通过 USB 数据线显示 Mac 画面，支持单指点击与拖拽。

**状态：experimental，等待真机验证。不是稳定版。** 初始 CNB 骨架的 Mac USB 占位代码现已替换为实际 libusb AOA 收发；编译与协议测试由 GitHub Actions 检查，机型兼容、画面效果和性能仍需实测。

## 两种明确区分的模式

- 默认主屏镜像：1280×720、30 fps、8 Mbps，用来验证连接与显示。
- 实验扩展桌面：`--backend virtual` 使用私有 CGVirtualDisplay。失败会报错，不会偷偷切回镜像。macOS 更新可能影响兼容性。

## 快速开始

Mac 需要 macOS 13+。Android 需要 Android 8+ 与 AOA/USB Accessory 支持。

1. 安装 GitHub Actions 成功构建的 android-debug-apk 中的 APK。
2. Mac 安装 Xcode Command Line Tools 与 Homebrew 依赖：

```bash
xcode-select --install
brew install libusb pkg-config
git clone https://github.com/configcrate/android-usb-mac-display.git
cd android-usb-mac-display
bash macos/scripts/usbdisplay-run.sh
```

3. 允许终端屏幕录制权限，重启终端。插入数据线，手机解锁并允许 USB 附件。
4. 单指操控另需 Mac 辅助功能权限。按 Ctrl-C 退出。

AOA 不要求开启 USB 调试。只连接一台 Android，并退出可能占用 USB 的文件传输应用。连接失败后处理原因并重新运行。

详细测试与故障回报：[TESTING.zh-CN.md](docs/TESTING.zh-CN.md)。

## 实现与测试

Mac：Swift / ScreenCaptureKit / VideoToolbox；USB：libusb 的 AOA 1.0 握手与 Bulk；Android：Kotlin / MediaCodec Surface 输出。

完整逻辑帧串行发送；编码器最多一帧在途，避免无限积压；增量解析器验证长度上限；手机 Surface/解码器就绪才请求 IDR；断线清理资源。输出轮询也在静态画面下运行。

```bash
node protocol/tests/test_protocol.js
node protocol/tests/check_consistency.js
cd macos && swift test
# Android: cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

GitHub Actions 构建 Mac Apple Silicon/Intel 与 Android、测试生产解析器、提供实验 APK/host artifacts。host artifact 仍依赖 Homebrew libusb，不是完全便携安装包。

## 限制与安全

- 尚未完成真机兼容矩阵；不承诺 25ms、60 fps 或 4K 性能。
- USB RTT 不等于完整显示延迟。
- 没有 App Store 版本、Mac 开发者签名/公证、正式 APK 签名。
- 首版只实现单指鼠标点击/拖拽；不承诺多指滚动、键盘、音频。
- 只连接信任的 Android；屏幕内容会通过 USB 传给它。无云端、账号、遥测，不修改系统驱动。
- 早期架构文档描述的是设计目标，不构成已实现或已测试的保证；当前状态以本 README 与测试步骤为准。

来源：[CNB 原项目](https://cnb.cool/ConfigCrate/android-usb-mac-display)。MIT，见 [LICENSE](LICENSE)。libusb 单独遵循 LGPL-2.1-or-later；动态依赖，未复制其源码。

Built by [ConfigCrate](https://configcrate.com/).
