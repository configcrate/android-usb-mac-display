# android-usb-mac-display

把闲置 Android 手机变成 Mac 的**有线副屏**。

- **Mac 端**：虚拟显示器 → VideoToolbox 硬件 H.264 编码 → USB Bulk 传输
- **Android 端**：USB 接收 → MediaCodec 硬件解码 → Surface 直出渲染，触摸回传
- **核心目标**：走 USB 有线，把端到端延迟压到 **25ms 以内**，彻底避开 WiFi 抖动

> 状态：v0.1 骨架，全链路代码已就位，协议层与常量一致性有测试覆盖。
> 尚需在真机上打通 AOA 握手与 USB 传输的具体 IOKit/Java 调用。

## 为什么必须有线

WiFi 投屏（AirPlay / scrcpy over TCP）的延迟分布是**长尾**的：

| 通道 | 典型 P50 | 典型 P99 | 问题 |
|------|---------|---------|------|
| WiFi 5GHz | 30–60 ms | 200ms+ | 邻居 AP 干扰、信道争抢、重传 |
| USB 2.0 Bulk | 8–15 ms | 20 ms | 带宽稳定，无共享介质 |

WiFi 的**平均值**可能看起来还行，但 P99 抖动会让鼠标"甩尾"，这是交互体验的致命伤。
USB 是有线独占，P99 与 P50 差距很小，手感才是"跟手"的。

## 快速开始

> 第一次用请直接看 **[新手教程 docs/00-quickstart.md](docs/00-quickstart.md)**，一页讲完从插线到出画面。

### 一键：Mac 端体检 + 缺什么自动装

```bash
git clone <本仓库> android-usb-mac-display && cd android-usb-mac-display

bash macos/scripts/usbdisplay-doctor.sh          # 体检，缺工具会问你要不要装
bash macos/scripts/usbdisplay-doctor.sh --yes    # 无人值守：缺什么直接装
bash macos/scripts/usbdisplay-doctor.sh --check  # 只体检，不动系统
```

检查七项：macOS 版本 / Node.js / Xcode CLT(`swift`) / 手机连线 / `adb` / 协议自检 / Mac 端能否构建，
最后给出「还差几项、逐条怎么处理」。

### 一键：投屏

```bash
bash macos/scripts/usbdisplay-run.sh --fps 30    # 参数会透传给 usbdisplayctl
```

### 手机端要装 App 吗？要

手机端必须装一个约 500 KB 的 **「USB 副屏」APK**，负责收流 → 硬解 → 上屏 → 回传触摸。装好不用手动开，
Mac 一启动就会通过 AOA 自动把它拉起。

**目前没有上架任何应用商店**（Google Play / 国内商店都没有），分发方式是自己装 APK：

```bash
bash macos/scripts/build-android-apk.sh --install   # 在 Mac 上构建并 adb install
```

或直接用 CI 构建好的产物（不用装 Android SDK）：每次推送 `main` 都会产出 `usbdisplay-debug-apk`，
在流水线页面下载 `app-debug.apk` 传到手机安装即可。详见 [新手教程 §3](docs/00-quickstart.md)。

> 上不了架的原因：Mac 侧依赖 `CGVirtualDisplay` 私有 API（上架必被拒），手机侧是 AOA accessory 开发者形态。
> 想公开分发需先补完 AOA 真机验证 + 切到 DriverKit 虚拟显示驱动。

### 不用手机、不用编译也能验证的部分

```bash
make check                                        # 13 项协议测试 + 17 项一致性检查
node protocol/tests/test_protocol.js
node protocol/tests/check_consistency.js
```

### 手动分步（想自己控制每一步时）

```bash
# Mac 端
cd macos && swift build
swift run usbdisplayctl doctor
swift run usbdisplayctl run --width 1920 --height 1080 --fps 60

# Android 端（gradle wrapper 已入库，无需预装 Gradle；首跑会下载 Gradle 8.7）
cd android && ./gradlew :app:installDebug
```

## 常用命令

| 命令 | 作用 |
|------|------|
| `make doctor` | Mac 端一键体检，可自动补装缺失工具 |
| `make run` | 一键投屏 |
| `make apk` / `make apk-install` | 构建手机端 APK；带 `-install` 会 adb 装到手机 |
| `make check` | 不依赖硬件的全部检查（CI 用这个） |

## 文档

| 文档 | 内容 |
|------|------|
| [docs/00-quickstart.md](docs/00-quickstart.md) | **新手教程**：从插线到出画面，含一键脚本与排错表 |
| [docs/01-usb-wire-protocol.md](docs/01-usb-wire-protocol.md) | USB 线协议：帧头、分包规则、握手序列 |
| [docs/02-architecture.md](docs/02-architecture.md) | 端到端架构、延迟预算、为什么用 Bulk 而非 Iso |
| [docs/03-macos-virtual-display.md](docs/03-macos-virtual-display.md) | 虚拟显示器三条路线对比与选型建议 |
| [docs/04-android-usb-and-decode.md](docs/04-android-usb-and-decode.md) | AOA vs ADB 取舍、MediaCodec 低延迟配置 |

## 协议定义在两处，靠测试保证一致

协议常量同时存在于三个文件：

```
protocol/frame.h                                  ← C，权威定义
macos/Sources/USBDisplayCore/FrameProtocol.swift  ← Swift
android/.../transport/FrameProtocol.kt            ← Kotlin
```

三端命名风格不同（`USBD_TYPE_VIDEO` / `typeVideo` / `TYPE_VIDEO`），
任何一处漏改都会造成"能编译、能跑、但连不通"的玄学问题。
`node protocol/tests/check_consistency.js` 会归一化命名后逐项比对，在 CI 中卡住这类漂移。

## 目录结构

```
.
├── protocol/                   协议权威定义与测试
│   ├── frame.h                 帧结构（C，编译期尺寸断言）
│   ├── aoa.h                   Android Open Accessory 常量
│   └── tests/
│       ├── test_protocol.js    编解码 / 分包 / 错位恢复测试
│       └── check_consistency.js 三端常量一致性检查
├── macos/                      Mac 端（Swift Package）
│   ├── scripts/                一键脚本（体检 / 投屏 / 构建 APK）
│   │   ├── usbdisplay-doctor.sh      环境体检，缺什么自动装
│   │   ├── usbdisplay-run.sh         一键编译 + 投屏
│   │   └── build-android-apk.sh      构建 / 安装手机端 APK
│   └── Sources/
│       ├── USBDisplayCore/
│       │   ├── FrameProtocol.swift   协议编解码
│       │   ├── FrameSink.swift       传输层抽象
│       │   ├── VirtualDisplay.swift  CGVirtualDisplay 私有 API 封装
│       │   ├── ScreenCapturer.swift  ScreenCaptureKit 采集
│       │   ├── H264Encoder.swift     VideoToolbox 编码
│       │   ├── AOATransport.swift    AOA 握手与 Bulk 传输
│       │   ├── InputInjector.swift   触摸 → CGEvent
│       │   └── DisplayLinkSession.swift  会话编排 + 自适应码率
│       └── usbdisplayctl/             CLI 入口
└── android/                    Android 端（Gradle，wrapper 已入库）
    ├── gradlew                 无需预装 Gradle
    └── app/src/main/java/dev/configcrate/usbdisplay/
        ├── transport/          USB 接收 + 协议 + 回传
        ├── decode/             MediaCodec 低延迟解码
        ├── render/             SurfaceView 渲染与坐标映射
        └── input/              触摸采集与抖动过滤
```

## 延迟优化要点速查

**Mac 侧**
- 禁 B 帧（`AllowFrameReordering=false`）+ `MaxFrameDelayCount=1` → 省 1 帧 ≈ 16ms
- `EnableLowLatencyRateControl` 把 VBV 缓冲压到最小
- 采集用 ScreenCaptureKit，输出 IOSurface 背衬的 CVPixelBuffer，零拷贝进编码器
- **绝不**用 `CGWindowListCreateImage`（同步全屏抓取，单帧 20ms+）
- 单次 USB 传输 ≤ 2MiB，避免大帧堵住小帧

**Android 侧**
- `KEY_LOW_LATENCY=1`（API 30+）
- Surface 直出，**不**读 outputBuffer 再上屏
- `releaseOutputBuffer(index, true)` 第二个参数必须是 `true`
- 直接喂 Annex-B 流，让 MediaCodec 自己解析 SPS/PPS
- 触摸 MOVE 事件抖动过滤，避免挤占 USB 带宽

## 已知限制

- **CGVirtualDisplay 是私有 API**，无法上架 App Store。生产级方案需 DriverKit 虚拟显示驱动（需向 Apple 申请权限，周期数周）。默认使用 ScreenCaptureKit 采集主屏，零安装摩擦。
- **手机端 APK 未上架任何应用商店**（Google Play / 国内商店均无）。当前分发方式是 CI 产物或本地构建后 adb 安装，属于开发者自用形态。正式公开分发的前提是：AOA 传输层真机验证补完 + 换用 DriverKit 虚拟显示驱动。
- **部分厂商 ROM 移除了 AOA 支持**（尤其国产定制系统）。已把传输层抽象成 `FrameSink`，便于切换到 ADB 隧道兜底。
- **AOA 的 IOKit 调用与 Android 侧的 `ParcelFileDescriptor` 读写**目前是结构化骨架，需在真机上补完具体调用并验证。
- 分辨率超过 1080p60 时 USB 2.0 带宽可能吃紧，需 USB 3.x 或降低帧率。

## License

MIT
