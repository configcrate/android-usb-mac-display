# 新手教程：把闲置手机变成 Mac 副屏

> 只想跑起来的话，看这一页就够了。全部命令都在 **Mac 的终端**里执行。
> 遇到问题直接跳到最后的[排错表](#七出问题了查这里)。

## 零、先看这张图

```
你的手机  ←──── USB 数据线 ────→  你的 Mac
（当显示器）                      （出画面）
  装「USB 副屏」App              跑一条命令
```

三个关键认知，先说清楚避免绕弯：

1. **必须是数据线**，不是充电线。市面上大量线只接了电源，插上手机只会充电，Mac 完全看不到它。
2. **Mac 是主动方**。你先在 Mac 上跑命令，Mac 通过 USB 把手机"叫起来"。
3. **手机端要装一个 App**（约 500 KB）。它负责收流、硬解、上屏；不装的话 Mac 能连上但手机没反应。

## 一、你要准备什么

| 项 | 要求 | 备注 |
|---|---|---|
| Mac | macOS 13+（Ventura 及以上） | 12.x 也能用，采集会走旧接口 |
| 手机 | Android 8.0+（API 26+） | 需要支持 AOA；极少数定制 ROM 阉割了，见[排错表](#七出问题了查这里) |
| 线 | **能传数据的 USB 线** | 不确定就换一根，这是第一大坑 |
| 手机设置 | 解锁屏幕 → 弹出"允许访问设备数据"时点**允许** | 部分 ROM 需要打开「开发者选项 → USB 调试」 |

不需要：不需要 root，不需要联网（除了首次装 APK / 首次跑 gradlew），不需要 Gradle（仓库自带 wrapper），
不需要在手机上装一堆开发工具。

> 手机端的安装包（APK）由本仓库 CI 自动产出，不用你自己编译 —— 见下面的第 3 步。

## 二、Mac 端：一条命令体检

```bash
git clone <本仓库地址> android-usb-mac-display
cd android-usb-mac-display

# 体检：现在能不能跑？缺什么？怎么补？
bash macos/scripts/usbdisplay-doctor.sh
```

脚本会依次检查七件事，并把结论直接告诉你：

```
① 系统与本机条件       macOS 版本、机器架构、显示器数量
② 运行时工具           Node.js、Xcode Command Line Tools（swift）
③ 硬件与连线           手机上没插？USB 2.0 还是 3.0？
④ adb                  装 APK 与兜底通道都要它
⑤ 协议自检             纯 JS，秒级，不需要手机也不需要编译
⑥ Mac 端构建           swift build 能不能过
⑦ Android 端           SDK 有没有、手机 App 装没装
```

缺东西时会**问你要不要装**，你说 y 它才动手：

```
  ✗ 缺少 adb（安装手机 APK、以及 ADB 隧道兜底需要它）
  ? 用 brew 安装 android-platform-tools（含 adb）？约 10 MB [y/N]
```

三种跑法：

```bash
bash macos/scripts/usbdisplay-doctor.sh           # 交互式，装之前问你
bash macos/scripts/usbdisplay-doctor.sh --yes     # 无人值守，缺什么直接装
bash macos/scripts/usbdisplay-doctor.sh --check   # 只体检，绝不改动系统
```

它会装的东西只有这几样，都可追溯：Homebrew（官网脚本）、Node.js（brew）、
Xcode Command Line Tools（`xcode-select --install`，系统弹窗）、adb（brew）。
**不会**静默改你的 shell 配置，**不会**往系统目录装东西。

> 想要图形化版本：`open macos/Package.swift` 用 Xcode 打开，
> `swift run usbdisplayctl doctor` 是脚本内部调用的同一个自检。

## 三、手机端：装「USB 副屏」APK

**是的，手机端必须装一个 App。** 它负责：接收 USB 传来的 H.264 流 → 硬件解码 → 全屏渲染 → 把触摸回传给 Mac。

目前**没有上架应用商店**（Google Play / 国内商店都没有）。原因有二，都在[已知限制](../README.md#已知限制)里：
Mac 侧用的是 `CGVirtualDisplay` 私有 API（上架必被拒），手机侧走的是 AOA accessory 通道，属于开发者自用形态。
所以现在的分发方式是**自己装 APK**，有两种，选一种：

### 方式 A：直接用 CI 构建好的 APK（推荐，不用装 Android SDK）

每次推送到 `main`，CI 都会构建一个 debug APK 并留在流水线产物里。

1. 打开仓库的**流水线 / CI 页面**，找最近一次 `main` 的构建
2. 进去下载 `usbdisplay-debug-apk` 这个产物（里面是 `app-debug.apk`）
3. 传到手机，点开安装

传到手机的三种方式，任选：
- 用数据线拷进手机的 Download 目录，然后在手机文件管理器里点开（需允许"安装未知应用"）
- 已经装了 adb：`adb install -r app-debug.apk`
- 微信/QQ 发给自己，手机上点开

### 方式 B：在 Mac 上自己编

```bash
# 需要 JDK 17 + Android SDK；缺 SDK 时脚本会试着用 brew 装
bash macos/scripts/build-android-apk.sh --install
```

`--install` 会构建并直接 `adb install` 到手机。不加 `--install` 只构建，产物路径会打印出来。

用的是仓库自带的 Gradle Wrapper（`android/gradlew`），所以**不需要预先装 Gradle**；
首跑它会自己下载 Gradle 8.7（约 130 MB），慢是正常的。
不想在 Mac 上装 Android SDK（好几个 GB）的话，用**方式 A**。

想验证 APK 有没有问题，也可以直接跑 Android 单元测试：

```bash
cd android && ./gradlew :app:testDebugUnitTest
```

> 这个 APK 是 **debug 签名**的，只适合自己和朋友用。
> 要给别人长期用，得换成 release 签名（`--release` 构建，但需要自备 keystore），
> 且建议先等 AOA 传输层的真机验证补完 —— 现在它还是结构化骨架。

### App 装好后

不用手动打开。插上线、Mac 端一启动，手机会**自动被拉起**到全屏画面。

App 的 `AndroidManifest.xml` 里监听的是 `USB_ACCESSORY_ATTACHED` 广播：

```xml
<intent-filter>
    <action android:name="android.hardware.usb.action.USB_ACCESSORY_ATTACHED" />
</intent-filter>
```

匹配规则写在 `res/xml/accessory_filter.xml`（manufacturer=ConfigCrate / model=USB Display），
和 Mac 侧 AOA `SEND_STRING` 发的内容一一对应，这样不会和 Android Auto 抢设备。

## 四、开始投屏

```bash
# 一键：检查 + 编译 + 启动
bash macos/scripts/usbdisplay-run.sh
```

也可以带参数，常见几个：

```bash
bash macos/scripts/usbdisplay-run.sh --fps 30                      # 手机发烫 / 掉帧时
bash macos/scripts/usbdisplay-run.sh --width 2560 --height 1440    # 2K 屏（USB 3 口更稳）
bash macos/scripts/usbdisplay-run.sh --backend virtual             # 真副屏，见下方说明
```

正常流程长这样：

```
① 环境快检      ✓ 检测到 Android 手机已插上
② 编译 Mac 端   ✓ 编译完成（首次 1–3 分钟）
③ 启动投屏      → 开始 AOA 握手... → 已切换到 accessory 模式 → 等待 Android 就绪... → 推流
```

手机上出现画面后，**屏幕上显示的统计浮层**能直接看出健康度：

```
1920x1080@60
码率建议 12 Mbps
RTT 3.2 ms
解码 4.1 ms
积压 0 帧
帧 8341  关键帧请求 2
```

- `RTT` 是 USB 往返，正常情况下是个位数毫秒
- `解码` 稳定在 5ms 以内说明硬解正常
- `积压` 长期 > 2 说明带宽不够，程序会自动降码率；也可以手动 `--fps 30`
- `关键帧请求` 不断增长说明链路在丢帧，先查线

`Ctrl-C` 退出，虚拟显示器会被释放。

## 五、"采集主屏"还是"真副屏"？

这是最容易被忽略的一点。默认是**镜像主屏**，不是把窗口拖过去：

| 模式 | 命令 | 效果 | 阶段 |
|---|---|---|---|
| 镜像（默认） | `--backend capture` | 手机显示和 Mac 主屏**一样**的画面 | 当前默认，最稳 |
| 真副屏 | `--backend virtual` | Mac 真的多一块显示器，窗口能拖上去 | 依赖私有 API，可能失效 |

`--backend virtual` 用的是 `CGVirtualDisplay` 私有 API，跑得通但 Apple 无兼容承诺，
**上架 App Store 必被拒**。所以默认走公开 API 的镜像模式，先保证低延迟链路是对的。
选型细节见 [docs/03-macos-virtual-display.md](03-macos-virtual-display.md)。

体检脚本里能看到它在你的系统上到底可不可用：

```bash
swift run usbdisplayctl doctor
```

## 六、触摸能反向操作吗

能。在手机画面上滑动/点击，事件会经 USB 回传统注入成 Mac 的鼠标事件（`InputInjector` → `CGEvent.post(.cghidEventTap)`）。
单指 = 鼠标移动 + 点击。首次运行 macOS 可能会弹**辅助功能权限**请求，需要在
「系统设置 → 隐私与安全性 → 辅助功能」里把它勾上，否则注入会被系统忽略。

## 七、出问题了查这里

| 现象 | 最可能的原因 | 怎么办 |
|---|---|---|
| 体检说「未检测到 Android 手机」 | 用了充电线 | 换一根确认能传数据的线；换 USB 口；别接扩展坞的充电口 |
| 同上，换线也不行 | 手机没授权 | 解锁屏幕，重新插拔，弹窗点「允许」；仍不行就开「开发者选项 → USB 调试」 |
| Mac 说握手成功，但手机黑屏/没反应 | **没装 APK** | 回到第 3 步装 APK。Mac 连上了但手机上没有任何 App 能接这个 accessory |
| 报「不支持 AOA」 | 定制 ROM 阉割了 AOA | 换台手机验证；或等 ADB 隧道兜底通道（传输层已抽象成 `FrameSink`，见 docs/04） |
| 有画面但卡顿、手机发烫 | 码率/分辨率过高 | `--fps 30`；降到 1280x720 试试；USB 2.0 下 1080p60 基本是上限 |
| 触摸没反应 | 缺辅助功能权限 | 系统设置 → 隐私与安全性 → 辅助功能，勾上终端/程序 |
| `swift build` 失败 | 缺 CLT 或 Xcode 未接受许可 | `xcode-select --install`；`sudo xcodebuild -license accept` |
| 提示三端常量不一致 | 改了协议只改了一头 | 跑 `make check`，按提示同步 Swift/Kotlin/C 三处 |
| `./gradlew` 报 `Permission denied` | 可执行位丢了 | `chmod +x android/gradlew` |
| `./gradlew` 报 `JAVA_HOME is not set` | 缺 JDK 17 | `brew install --cask temurin@17` 后再跑，或直接用 CI 的 APK |
| 构建卡在下载 Gradle 很久 | 首跑要下 Gradle 8.7 约 130 MB | 等它下完；换网络；或用方式 A 直接拿 CI 产物 |
| 想彻底回到干净状态 | —— | 关掉 App、`Ctrl-C` 退出、拔线；`make clean` 清构建产物 |

## 八、想深入看代码

| 你想搞明白 | 看这个 |
|---|---|
| 线上跑的字节格式 | [01-usb-wire-protocol.md](01-usb-wire-protocol.md) |
| 延迟预算怎么分配的、为什么是 Bulk | [02-architecture.md](02-architecture.md) |
| 虚拟显示器三条路怎么选 | [03-macos-virtual-display.md](03-macos-virtual-display.md) |
| AOA 还是 ADB、MediaCodec 怎么调 | [04-android-usb-and-decode.md](04-android-usb-and-decode.md) |

```bash
make check     # 13 项协议测试 + 17 项三端一致性检查，不需要硬件
```
