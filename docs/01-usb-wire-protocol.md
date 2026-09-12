# USB 视频线协议 Wire Protocol v1

Mac 为 **Host（Controller）**，Android 为 **Device（Accessory）**。所有数据经 USB Bulk 端点传输，不经网络。

## 1. 字节序与对齐

- 全部小端序（little-endian）。
- 结构体按 1 字节对齐，避免隐式 padding。
- 控制结构体固定 32 字节。

## 2. 帧头 FrameHeader（16B）

| Offset | Size | Field         | 说明 |
|--------|------|---------------|------|
| 0      | 4    | magic         | `0x55 0x53 0x42 0x44`（"USBD"） |
| 4      | 1    | version       | 协议版本，当前 `1` |
| 5      | 1    | type          | 见下表 |
| 6      | 2    | flags         | bit0 KEYFRAME, bit1 CONFIG_EPOCH_CHANGED |
| 8      | 4    | seq           | 单调递增帧序号 |
| 12     | 4    | payload_len   | 后续有效载荷字节数（不含本头，不含 padding） |

## 3. 帧类型

| type | 名称      | 方向 | 载荷 |
|------|-----------|------|------|
| 0x01 | VIDEO     | Mac→Android | H.264 Annex-B NAL 单元 |
| 0x02 | CONFIG    | Mac→Android | SPS+PPS 已内嵌于 VIDEO 关键帧，此帧用于**编解码参数变更**（分辨率/帧率/码率） |
| 0x10 | TOUCH     | Android→Mac | `TouchEvent` |
| 0x11 | KEY       | Android→Mac | `KeyEvent` |
| 0x20 | PING      | 双向 | 4B 单调时间戳（μs，发送端本地时钟） |
| 0x21 | PONG      | 双向 | 原样回显对端 PING 的 4B 时间戳 + 4B 本端单调时间戳 |
| 0x30 | REQUEST_KEYFRAME | Android→Mac | 空载荷 |
| 0x40 | STATS     | 双向 | TLV，见 §6 |

## 4. 触摸事件 TouchEvent（16B）

| Offset | Size | Field    | 说明 |
|--------|------|----------|------|
| 0      | 4    | seq      | 事件序号 |
| 4      | 2    | x        | 归一化 0..65535（相对视频画布，非屏幕像素） |
| 6      | 2    | y        | 归一化 0..65535 |
| 8      | 2    | pressure | 0..65535 |
| 10     | 1    | action   | 0=DOWN 1=MOVE 2=UP 3=CANCEL |
| 11     | 1    | pointer_count | 多点触摸指针数 |
| 12     | 2    | pointer_id | 指针 ID |
| 14     | 2    | reserved | 保留，填 0 |

坐标用归一化值而非像素：Mac 侧虚拟显示器分辨率随时可调，Android 侧画布有 letterbox，归一化可让两端解耦。

## 5. 分包规则

- **USB Bulk 单次传输上限 16 MiB**（platform 限制），但为控延迟，单次写不超过 **2 MiB**。
- 一个 FrameHeader + payload 可跨越多个 Bulk 传输；接收端按 `payload_len` 流式重组。
- 接收端必须容忍**部分读**：`UsbDeviceConnection.bulkTransfer` 返回任意长度都是合法的。
- 关键帧大于 2 MiB 时按 §5 拆分连续写，接收端看到 `seq`/`flags` 与长度累加即知是同帧续传。

## 6. STATS TLV

每 500ms 交换一次，用于端到端延迟测量与自适应码率。

| Tag | 名称            | 类型 | 说明 |
|-----|-----------------|------|------|
| 1   | rtt_us          | u32  | 往返时延 |
| 2   | encode_us       | u32  | VideoToolbox 编码耗时 P50 |
| 3   | decode_us       | u32  | 硬件解码耗时 P50 |
| 4   | queue_frames    | u32  | Android 解码队列积压帧数 |
| 5   | dropped_frames  | u32  | 累计丢帧 |
| 6   | target_bitrate  | u32  | Android 建议的码率（bps），Mac 据此调整 |

## 7. 握手序列

```
Mac                                  Android
 |  ── Accessory 模式握手（USB 描述符层，非本协议） ──►
 |  ◄── HELLO(version=1, caps=H264|AV1) ──
 |  ── CONFIG(width,height,fps,bitrate,codec) ──►
 |  ── VIDEO(seq=0, KEYFRAME, SPS+PPS+IDR) ──►
 |  ◄── REQUEST_KEYFRAME（解码器就绪 / 丢帧后） ──
 |  ── PING/PONG 每 1s ──►◄──
 |  ── STATS 每 500ms ──►◄──
```

**关键约束：Mac 必须在 Android 报告"解码器 Surface 就绪"后才开始推送 IDR**，否则首批帧会被丢弃且浪费 USB 带宽。
