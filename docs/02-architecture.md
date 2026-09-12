# 端到端架构

## 数据流

```
┌────────────────────────── macOS (Host) ──────────────────────────┐
│                                                                  │
│  [虚拟显示器]                                                     │
│   CGVirtualDisplay / CGDisplayStream / ScreenCaptureKit           │
│        │ IOSurface (零拷贝)                                       │
│        ▼                                                          │
│  [编码器] VideoToolbox VTCompressionSession                       │
│   H.264 High profile, 实时模式, 强制低延迟 flag                    │
│   CVPixelBuffer 来自 IOSurface，无 CPU 拷贝                        │
│        │ CMBlockBuffer (Annex-B)                                  │
│        ▼                                                          │
│  [分帧器] 加 FrameHeader + 分包                                    │
│        │                                                          │
│        ▼                                                          │
│  [USB 传输] DriverKit USBDriverKit / IOKit IOUSBHostDevice        │
│   Bulk OUT 端点，多缓冲流水线，背压控制                            │
│                                                                  │
│  [输入回放] 接收 TOUCH → CGEventPost                               │
└──────────────────────────────────────────────────────────────────┘
                              │ USB-C 线缆
┌────────────────────────── Android (Device) ──────────────────────┐
│                                                                  │
│  [USB 接收] UsbManager + Accessory 模式 / AOA                       │
│   Bulk IN 端点，专用读线程，无锁环形缓冲                            │
│        │                                                          │
│        ▼                                                          │
│  [解帧] 流式重组 FrameHeader + payload                             │
│        │                                                          │
│        ▼                                                          │
│  [硬解] MediaCodec (Surface 直出)                                  │
│   low-latency 模式, 不解码到 ByteBuffer 再上屏                     │
│        │                                                          │
│        ▼                                                          │
│  [渲染] SurfaceView / TextureView，保持原始宽高比，无额外缩放        │
│                                                                  │
│  [触摸采集] onTouchEvent → 归一化 → Bulk OUT 回传                   │
└──────────────────────────────────────────────────────────────────┘
```

## 延迟预算（目标 < 25ms 玻璃到玻璃）

| 环节 | 目标 | 手段 |
|------|------|------|
| 采集（IOSurface 就绪） | 1–3 ms | ScreenCaptureKit `.screen` 或 CGDisplayStream，避免 CGWindowListCreateImage |
| VideoToolbox 编码 | 2–6 ms | `kVTCompressionPropertyKey_RealTime=true`、`EnableLowLatencyRateControl=true`、B 帧数为 0、`MaxFrameDelayCount=1` |
| 分帧 + 写 USB | 1–2 ms | 单次 ≤ 2 MiB，预分配缓冲，避免 malloc |
| USB 传输 | 1–4 ms | Bulk 而非 Isochronous；USB3 SuperSpeed 理论 5Gbps；流水线多缓冲 |
| Android 解帧 | < 1 ms | 环形缓冲 + 按长度流式读，不做中间 ByteArray 拷贝 |
| MediaCodec 解码 | 2–6 ms | `KEY_LOW_LATENCY=1`（API 30+）、Surface 直出、`KEY_OPERATING_RATE` 匹配帧率 |
| 上屏 | 1–2 ms | SurfaceView（不与 UI 线程合成）、关闭系统动画 |
| 触摸回传 | 2–5 ms | 高优先级线程，合并 MOVE 事件，避免每像素一发 |

## 为什么用 Bulk 而不是 Isochronous

USB 的 Isochronous 端点保证带宽与时序，但**不保证送达**（无重传），且 macOS 上对 Iso 的用户态支持很弱。
视频帧有完整性要求（H.264 帧内任一字节损坏即整帧报废），因此用 **Bulk + 重传** 更合适。

代价是 Bulk 的延迟取决于主机调度器配额。缓解手段：
1. 单次传输控制在 2 MiB 以内，避免长时间占用总线。
2. 多 URB（异步 IO）排队，让 USB 控制器始终有活干。
3. 关键帧分段写，防止小帧被大帧"堵住"。

> 如果实测吞吐不足（USB2 上限 60 MB/s，1080p60 H.264 约 8–15 Mbps 完全够用），
> 才需要考虑 Iso 或多端点分流。

## 自适应码率闭环

Android 每 500ms 上报 `queue_frames` 与 `dropped_frames`：

- `queue_frames` 持续 > 2 → 说明解码跟不上 → 降码率 10%
- `queue_frames` 持续 = 0 且 `rtt` < 3ms → 有富余 → 尝试升码率 5%
- 出现丢帧 → 立即请求关键帧 + 码率降 20%

调整通过 VideoToolbox 的 `kVTCompressionPropertyKey_AverageBitRate` 动态设置，无需重建 session。
