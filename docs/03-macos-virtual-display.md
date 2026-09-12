# macOS 虚拟显示器方案选型

目标：凭空造出一块**逻辑上存在、物理上不存在**的显示器，让 macOS 以为接了副屏，
从而可以把窗口拖上去、也能作为独立桌面被采集。

## 三条路线

### 路线 A：`CGVirtualDisplay`（私有 API，推荐做 PoC）

`CoreGraphics.framework` 中的私有类，`objc_getClass("CGVirtualDisplay")` 可拿到。
macOS 10.15+ 存在，Sonoma / Sequoia 仍可用。

```objc
CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
d.name = @"USB Display";
d.maxPixelsWide = 1920; d.maxPixelsHigh = 1080;
d.sizeInMillimeters = CGSizeMake(345, 195);
d.queue = dispatch_get_main_queue();
d.terminationHandler = ^(CGVirtualDisplay *o, CGVirtualDisplayTerminationReason r) {};

CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:d];

CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
s.hiDPI = 0;
s.modes = @[mode(1920,1080,60), mode(2560,1440,60)];
[vd applySettings:s];
```

**优点**：无需签名/审批，几十行就能跑通，能进系统显示器列表。
**缺点**：私有 API，上架 App Store 会被拒；跨大版本有失效风险。

### 路线 B：DriverKit 虚拟显示驱动（生产级）

用 `DriverKit` + `SystemExtensions` 框架写一个虚拟 HID/显示驱动。

- 需要 Apple 开发者账号 + `com.apple.developer.driverkit` 权限申请（**需向 Apple 单独申请**，周期数周）。
- 需要 `com.apple.developer.system-extension.install` 权限。
- 用户首次需在「系统设置 → 隐私与安全性」中允许系统扩展，并重启。
- 分发需 Developer ID 签名 + Notarization。

**优点**：官方支持，稳定，能长期维护。
**缺点**：门槛高、审批慢、用户侧安装摩擦大。

### 路线 C：ScreenCaptureKit 采集窗口，不造虚拟显示器

不假装有显示器，直接采集**指定窗口或整个主屏**，投到 Android 上。

```swift
let filter = SCContentFilter(display: display, excludingWindows: [])
let cfg = SCStreamConfiguration()
cfg.width = 1920; cfg.height = 1080; cfg.minimumFrameInterval = CMTime(value:1, timescale:60)
cfg.pixelFormat = kCVPixelFormatType_32BGRA
```

**优点**：公开 API，零安装摩擦，`SCStream` 输出的 `CVPixelBuffer` 可直接喂 VideoToolbox。
**缺点**：不是真正的副屏，窗口挪不过去；Android 上只是"镜像"。

## 推荐决策

**分阶段推进**：

| 阶段 | 方案 | 目的 |
|------|------|------|
| v0.1 | 路线 C（ScreenCaptureKit） | 最快跑通全链路，验证延迟与 USB 吞吐 |
| v0.2 | 路线 A（CGVirtualDisplay） | 验证"真副屏"体验，作为可选增强 |
| v1.0 | 路线 B（DriverKit） | 若决定做正式产品再投入 |

**强烈建议先做 v0.1**：链路能不能压到 25ms 是生死问题，而虚拟显示器只是"窗口能不能拖过去"的体验问题。
先验证前者。

## 采集实现要点

优先用 `ScreenCaptureKit`，退而求其次 `CGDisplayStream`（macOS 14 起标记 deprecated 但仍可用）。

关键配置：
- `pixelFormat = kCVPixelFormatType_32BGRA`（VideoToolbox 硬件编码器最友好）
- `minimumFrameInterval` 按目标帧率设置
- `queueDepth = 3`（越小延迟越低，但易丢帧）
- `showsCursor = true`
- 输出 `CVPixelBuffer` 的 `IOSurface` 直接是 VT 的输入，**零拷贝**

务必避开：
- `CGWindowListCreateImage`：同步全屏拷贝，单帧就可能 20ms+。
- `CGDisplayCreateImage`：同上。

## VideoToolbox 关键参数

```swift
VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
                     kVTProfileLevel_H264_High_AutoLevel)
VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering,
                     kCFBooleanFalse)          // 禁 B 帧，去重排序延迟
VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount, 1 as CFNumber)
VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
// macOS 12+: 低延迟码控
VTSessionSetProperty(session, kVTCompressionPropertyKey_EnableLowLatencyRateControl,
                     kCFBooleanTrue)
VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
```

推送帧时带上 `kVTEncodeFrameOptionKey_ForceKeyFrame` 可强制 IDR（响应 Android 的 REQUEST_KEYFRAME）。
