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

```bash
# 1. 先跑协议检查（不需要任何硬件/编译器）
node protocol/tests/test_protocol.js
node protocol/tests/check_consistency.js

# 2. Mac 端环境自检
cd macos && swift build
swift run usbdisplayctl doctor

# 3. Mac 端启动投屏
swift run usbdisplayctl run --width 1920 --height 1080 --fps 60

# 4. Android 端
cd android && ./gradlew :app:installDebug
# 插上 USB 线，App 会自动被拉起
```

## 文档

| 文档 | 内容 |
|------|------|
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
└── android/                    Android 端（Gradle）
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
- **部分厂商 ROM 移除了 AOA 支持**（尤其国产定制系统）。已把传输层抽象成 `FrameSink`，便于切换到 ADB 隧道兜底。
- **AOA 的 IOKit 调用与 Android 侧的 `ParcelFileDescriptor` 读写**目前是结构化骨架，需在真机上补完具体调用并验证。
- 分辨率超过 1080p60 时 USB 2.0 带宽可能吃紧，需 USB 3.x 或降低帧率。

## License

MIT
