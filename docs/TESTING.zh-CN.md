# 首轮真机测试（experimental）

目标：先证明 USB 镜像链路可用，再验证扩展桌面。CI 构建通过不等于真机通过。

## 准备

- Mac：macOS 13 或以上，Xcode Command Line Tools、Homebrew。
- Android 8 或以上，支持 USB Accessory / AOA 的手机或平板。
- 可传数据的 USB 线。首次只接一台 Android，退出 Android File Transfer / OpenMTP 等占用 USB 的软件。
- 程序同时检查 USB 接口，不仅按品牌识别，避免误操作同品牌 SSD/键鼠。若找不到手机，解锁并在手机 USB 选项选择“文件传输 / MTP”后重试；不要求 USB 调试。
- AOA 不要求 USB 调试。若厂商 ROM 不支持 AOA，开启调试也不能保证解决。

## 安装与启动

1. 从 GitHub Actions 的成功构建下载 android-debug-apk，解压后在手机安装 app-debug.apk。这是调试签名实验包，不是正式商店版本。
2. Mac 执行：

```bash
xcode-select --install # 已安装可跳过
brew install libusb pkg-config
git clone https://github.com/configcrate/android-usb-mac-display.git
cd android-usb-mac-display
bash macos/scripts/usbdisplay-run.sh
```

首次会请求屏幕录制权限。在系统设置→隐私与安全性→屏幕录制，允许所用终端（Terminal / iTerm 等），完全退出并重新打开终端，再运行脚本。

3. 插上数据线，手机解锁并允许 USB 附件访问，选择 USB Display 应用。Mac 启动失败时，根据错误提示处理并重跑；未插线时不会宣称已经连接，也不会后台自动等待。
4. 要从手机点按/拖拽操作 Mac，还需在 Mac 系统设置给该终端辅助功能权限。仅看画面不需要辅助功能。
5. 按 Ctrl-C 停止，检查虚拟显示器与 USB 资源已释放。

可只构建 Mac、不运行：

```bash
cd macos
swift build -c release
swift test
.build/release/usbdisplayctl doctor
```

Actions 的 host 文件仍依赖 Homebrew libusb 的路径，暂不是完全便携/公证的安装包。建议先按源码构建，以匹配你的 Mac 架构。

## 测试顺序

先用默认 1280×720 / 30 fps / 8 Mbps 主屏镜像。检查以下每项：

- 首次 USB 授权能弹出；拒绝后不崩溃；重新插线可重试。
- 画面确实变化；移动鼠标、播放视频；停在静态页面最后一帧不丢失。
- 单指点击、拖动窗口，手指松开后鼠标不持续按住。无多指滚动和软键盘功能承诺。
- 应用进后台再恢复，Surface 重建后可重新得到关键帧。
- 手机锁屏不暴露 Mac 内容；恢复后重新显示。
- 拔线后两端清晰显示断开；重新插线并重跑 Mac 命令可连接。至少重复 20 次。
- 连续运行 30 分钟，记录温度、电量、画面停顿；一次在 Mac/手机开机超过 2 小时后测试 RTT。
- 没有手机、不支持 AOA、纯充电线、多手机、USB 被占用时，有明确错误，不误报成功。

镜像通过后测试真正扩展桌面：

```bash
bash macos/scripts/usbdisplay-run.sh --backend virtual
```

在 Mac 设置→显示器确认多一个 USB Display；设为扩展而非镜像，把窗口拖到新屏。检查屏幕左右/上下排列的触摸定位。此模式使用私有 CGVirtualDisplay API，系统升级后可能失效；失败不会自动伪装成镜像。

最后逐步提高到 1920×1080：

```bash
bash macos/scripts/usbdisplay-run.sh --width 1920 --height 1080 --fps 30 --bitrate 12000000
```

60 fps、4K、25ms 均不作为首轮通过标准或已经达到的性能。USB RTT 是往返通信时间，不是从 Mac 画面变化到手机显示的完整延迟。

## 回报信息

请附上 Mac 芯片/型号、macOS 版本、手机型号/Android 版本、线材/扩展坞、命令、终端完整错误、是否镜像/扩展、是否首次权限弹窗。

```bash
cd macos
.build/debug/usbdisplayctl doctor
system_profiler SPUSBDataType
```

USB 系统报告可能包含序列号；公开提交前删掉序列号、用户名等个人信息。不要上传凭证。

## 已知限制

还没有开发者签名、公证 Mac 安装器或正式 APK 签名。厂商 AOA 兼容性、USB 设备所有权、私有虚拟显示器行为与性能需要真机确认。程序不修改系统驱动、无服务器、无账号、无遥测，但会采集并通过 USB 发送屏幕；只连接自己信任的设备。

Built by [ConfigCrate](https://configcrate.com/).
