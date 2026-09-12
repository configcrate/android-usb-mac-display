# Android 侧 USB 与解码

## 1. USB 角色：Android 必须是 Device 还是 Host？

关键抉择，直接决定 USB 连接方式。

| 方案 | Mac 角色 | Android 角色 | 说明 |
|------|----------|--------------|------|
| **A. AOA / Accessory** | Host | Accessory | Mac 主动打开 Android 的 accessory 接口。Android 侧零配置，插线即用 |
| **B. Android 作 Host** | Device（需 USB Gadget） | Host | Mac 需要被识别成 UVC/自定义设备，Mac 侧门槛极高 |
| **C. ADB 隧道** | Host（`adb`） | Device | 把视频流塞进 `adb forward` 的 TCP 端口 |

### 推荐：方案 A（AOA + Bulk 端点）

理由：
- Mac 是天生的 USB Host，Android 手机作 accessory 是标准玩法（Android Auto 就是这么做的）。
- AOA 的 `ACCESSORY` 接口允许自定义 Bulk IN / Bulk OUT 端点，**正是我们要的双向通道**。
- Android 侧无需 root、无需特殊权限，`UsbManager` 直接拿到 `UsbAccessory` 即可 `openAccessory()`。

Mac 侧握手流程（libusb / IOUSBHost）：

```
1. 找到 Android 设备（VID/PID 或匹配 interface class 0xFF 时用 controlTransfer 读 "aoa" 字符串）
2. GET_PROTOCOL (controlTransfer bRequest=51, wValue=0)  → 确认支持 AOA
3. SEND_STRING (bRequest=52, index=0) 发送 "USBDisplay"
4. ACCESSORY_START (bRequest=53) → Android 重新枚举，以 accessory 身份出现
5. 重新枚举后找到 interface class 0xFF subClass 0xFF prot 0x00 的 AOA 接口
6. 取到两个 Bulk 端点（一个 IN 一个 OUT），开始传输
```

AOA 常量的完整定义见 `protocol/aoa.h`。

### 降级：方案 C（ADB 隧道）

如果 AOA 在某些厂商 ROM 上不可靠，用 ADB 作为兜底：Mac 侧 `adb forward tcp:51423 tcp:51423`，
协议层不变，只是把 Bulk 换成 TCP socket。**协议设计上应把传输层抽象成 `FrameSink` 接口**，
这样 AOA / ADB / 甚至 USB Tethering 都能复用同一套分帧逻辑。

## 2. 为什么不用 MediaProjection / 不用 ADB 反向

- `MediaProjection` 是 Android **投屏出去**的能力，方向反了。
- 正确方向是 Android **当显示器**，接收 Mac 的画面。

## 3. MediaCodec 低延迟配置

```kotlin
val fmt = MediaFormat.createVideoFormat("video/avc", width, height).apply {
    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024)
    // API 30+ 才有真低延迟模式
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
    }
    // 告诉编解码器预期帧率，便于它做帧率匹配
    setInteger(MediaFormat.KEY_OPERATING_RATE, frameRate)
    setInteger(MediaFormat.KEY_PRIORITY, 0) // 0 = realtime
}
val codec = MediaCodec.createDecoderByType("video/avc")
codec.configure(fmt, surface, null, 0)
codec.start()
```

**关键三点**：

1. **Surface 直出**：`configure(fmt, surface, ...)`，绝不 `outputBuffer` 读出来再 memcpy 上屏。
2. **`KEY_LOW_LATENCY=1`**：API 30 以下没有这个 key，低端机只能靠"喂帧即解码"缓解。
3. **`releaseOutputBuffer(index, true)` 里第二个参数必须是 `true`**（render 到 surface），不是时间戳版本。

## 4. 喂帧策略：直接喂 NAL 还是喂完整 Annex-B？

**推荐：把 Annex-B 字节流直接 `queueInputBuffer`**，MediaCodec 的 H.264 解码器能自动识别 start code
并处理 SPS/PPS（只要关键帧里带 SPS+PPS，即 Annex-B 的 `00 00 00 01 67 ... 00 00 00 01 68 ... 00 00 00 01 65 ...`）。

**不要**尝试自己拆 NAL 再算 `BUFFER_FLAG_CODEC_CONFIG`——那需要把 SPS/PPS 单独抽出且只在第一次喂，
在动态分辨率变更时会踩坑（必须重新 configure）。

前提：Mac 侧的 `VTCompressionSession` 输出要用 `kVTCompressionPropertyKey_...`，实际是
**设置 `AVCC` 格式后自己转 Annex-B**。VideoToolbox 默认输出 AVCC（4 字节长度前缀），
需要在 `AVCC → Annex-B` 转换：

```
for each NAL in AVCC:
    write 00 00 00 01
    write NAL bytes
```

同时在 SPS 前插入 start code，并保证关键帧的 SPS/PPS 都在 IDR 之前到达。

## 5. 输入回传的时序

Android 触摸事件在 UI 线程产生，**不能直接在 UI 线程写 USB**（会掉帧）。正确做法：

```
onTouchEvent (UI thread)
   → 归一化坐标 → 塞进无锁环形队列（ArrayBlockingQueue, capacity 64）
   → 立刻 return false（不消费事件，让系统手势仍可用？视需求）
TouchSender thread (THREAD_PRIORITY_URGENT_AUDIO)
   → 批量取出（一次最多 8 个 MOVE 事件合并）
   → 写 Bulk OUT
```

**MOVE 事件必须合并**：60Hz 触摸采样下，手指快速滑动每帧可产生 3–5 个 MOVE。
全部回传会挤占 USB 带宽（视频是 Bulk IN，触摸是 Bulk OUT，共用总线调度）。
合并策略：队列里同一 `pointer_id` 的连续 MOVE 只保留最后一个。

## 6. 权限与 manifest

```xml
<uses-feature android:name="android.hardware.usb.host" android:required="false" />
<uses-feature android:name="android.hardware.usb.accessory" android:required="true" />

<activity ...>
    <intent-filter>
        <action android:name="android.hardware.usb.action.USB_ACCESSORY_ATTACHED" />
    </intent-filter>
    <meta-data android:name="android.hardware.usb.action.USB_ACCESSORY_ATTACHED"
               android:resource="@xml/accessory_filter" />
</activity>
```

`res/xml/accessory_filter.xml` 中声明 Mac 侧 `SEND_STRING` 发过去的 model/manufacturer。
