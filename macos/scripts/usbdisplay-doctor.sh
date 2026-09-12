#!/usr/bin/env bash
#
# usbdisplay-doctor.sh — Mac 端一键环境体检 + 缺什么装什么
#
# 目标：在 Mac 上跑这一条命令，就能知道「现在能不能开始」，缺的东西自动装。
#
#   bash macos/scripts/usbdisplay-doctor.sh           # 体检（缺工具会自动安装，装前问你一声）
#   bash macos/scripts/usbdisplay-doctor.sh --yes     # 全程不提问，缺什么直接装（适合脚本化）
#   bash macos/scripts/usbdisplay-doctor.sh --check   # 只体检，绝不安装，不碰你的系统
#   bash macos/scripts/usbdisplay-doctor.sh --json    # 机器可读结果，给 CI / 脚本用
#   bash macos/scripts/usbdisplay-doctor.sh --no-color
#
# 设计原则：
#   · 默认先检查再动手，安装前会让你确认；用 --yes 才无人值守
#   · 安装走了哪条路（brew / 官方 pkg / 系统自带）都会打印出来，可追溯
#   · 不静默改 shell 配置、不 sudo 装到系统目录
#
set -uo pipefail

# ---------------------------------------------------------------- 参数与基础

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ASSUME_YES=0
CHECK_ONLY=0
JSON_OUT=0
USE_COLOR=1

for arg in "$@"; do
  case "$arg" in
    -y|--yes)    ASSUME_YES=1 ;;
    --check)     CHECK_ONLY=1 ;;
    --json)      JSON_OUT=1 ;;
    --no-color)  USE_COLOR=0 ;;
    -h|--help)   awk '/^set -uo pipefail/{exit} NR>1 && /^#/{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $arg（试 --help）" >&2; exit 2 ;;
  esac
done

if [ "$JSON_OUT" = "1" ] || [ ! -t 1 ]; then USER_COLOR_OFF=1; fi

if [ "$USE_COLOR" = "1" ] && [ -z "${USER_COLOR_OFF:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=''; DIM=''; G=''; Y=''; R=''; C=''; N=''
fi

ok()   { [ "$JSON_OUT" = "1" ] || printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { [ "$JSON_OUT" = "1" ] || printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
bad()  { [ "$JSON_OUT" = "1" ] || printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
info() { [ "$JSON_OUT" = "1" ] || printf '  %s·%s %s\n' "$DIM" "$N" "$1"; }
step() { [ "$JSON_OUT" = "1" ] || printf '\n%s%s%s\n' "$B" "$1" "$N"; }

FAILED=0
WARNED=0
JSON_ITEMS=""

# 记录一条检查结果：record <state:ok|warn|fail> <key> <message>
record() {
  local state="$1" key="$2" msg="$3"
  case "$state" in
    ok)   ok "$msg" ;;
    warn) warn "$msg"; WARNED=$((WARNED + 1)) ;;
    fail) bad "$msg"; FAILED=$((FAILED + 1)) ;;
  esac
  local esc
  esc="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  JSON_ITEMS="${JSON_ITEMS}${JSON_ITEMS:+,}{\"state\":\"${state}\",\"key\":\"${key}\",\"message\":\"${esc}\"}"
}

has() { command -v "$1" >/dev/null 2>&1; }

# 是否允许安装
can_install() { [ "$CHECK_ONLY" = "0" ]; }

# 问一句（--yes 时直接过）
confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  [ "$CHECK_ONLY" = "1" ] && return 1
  [ ! -t 0 ] && return 1   # 非交互（CI/管道）不擅自安装
  printf '  %s?%s %s [y/N] ' "$C" "$N" "$1"
  local ans; read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- 平台确认

step "① 系统与本机条件"
if [ "${JSON_OUT}" = "1" ]; then :; else
  printf '  %s%s%s\n' "$DIM" "$(sw_vers 2>/dev/null | tr '\n' ' ' || uname -srm)" "$N"
fi

UNAME_S="$(uname -s)"
if [ "$UNAME_S" != "Darwin" ]; then
  record fail os "当前系统是 ${UNAME_S}，不是 macOS"
  info "本脚本必须在 Mac 上运行：Mac 是 USB Host，负责采集、编码、推流"
  if [ "$JSON_OUT" = "1" ]; then
    printf '{"ok":false,"failed":%d,"warned":%d,"items":[%s]}\n' "$FAILED" "$WARNED" "$JSON_ITEMS"
  else
    printf '\n%s结论：%s\n' "$B" "$(printf '%s请在 macOS 上重新运行本脚本%s' "$R" "$N")"
  fi
  exit 1
fi
OS_VERSION="$(sw_vers -productVersion 2>/dev/null | head -1 | tr -d '\r')"
[ -n "$OS_VERSION" ] || OS_VERSION="?"
record ok os "macOS ${OS_VERSION} · $(uname -m)"

ARCH="$(uname -m)"
MACOS_VER="${OS_VERSION}"
[ "$MACOS_VER" = "?" ] && MACOS_VER=0
MACOS_MAJOR="${MACOS_VER%%.*}"
if [ "${MACOS_MAJOR:-0}" -ge 13 ] 2>/dev/null; then
  record ok macos_version "macOS ${MACOS_VER} ≥ 13（ScreenCaptureKit 可用）"
elif [ "${MACOS_MAJOR:-0}" -ge 12 ] 2>/dev/null; then
  record warn macos_version "macOS ${MACOS_VER}：可用，但 ScreenCaptureKit 需要 12.3+，旧版本走 CGDisplayStream 回退"
else
  record fail macos_version "macOS ${MACOS_VER} 太旧，请升级到 13 或更高"
fi

# 是否在虚拟机 / 无内建屏（影响虚拟显示器）
DISPLAY_COUNT="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c 'Resolution:' || true)"
if [ "${DISPLAY_COUNT:-0}" -gt 0 ]; then
  record ok displays "检测到 ${DISPLAY_COUNT} 块显示器"
else
  record warn displays "未枚举到显示器；若确实接了屏，多为虚拟机/远程会话或 system_profiler 受限，可忽略"
fi

# ---------------------------------------------------------------- 运行时工具

step "② 运行时工具（缺了会自动装）"

install_brew() {
  can_install || return 1
  confirm "未找到 Homebrew，是否现在安装？（会用到 sudo，官网脚本）" || {
    warn "跳过安装 Homebrew"; return 1
  }
  info "从 https://brew.sh 安装 Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
  # Apple Silicon 走 /opt/homebrew，Intel 走 /usr/local
  for p in /opt/homebrew/bin /usr/local/bin; do
    [ -x "$p/brew" ] && export PATH="$p:$PATH"
  done
  has brew
}

ensure_brew() {
  if has brew; then return 0; fi
  if [ "$ARCH" = "arm64" ] && [ -x /opt/homebrew/bin/brew ]; then export PATH="/opt/homebrew/bin:$PATH"; return 0; fi
  if [ -x /usr/local/bin/brew ]; then export PATH="/usr/local/bin:$PATH"; return 0; fi
  install_brew
}

# Node.js（跑协议自检，纯 JS，秒级，不需要硬件）
if has node; then
  NODE_V="$(node --version 2>/dev/null)"
  NODE_MAJOR="${NODE_V#v}"; NODE_MAJOR="${NODE_MAJOR%%.*}"
  if [ "${NODE_MAJOR:-0}" -ge 18 ] 2>/dev/null; then
    record ok node "Node.js ${NODE_V}"
  else
    record warn node "Node.js ${NODE_V} 偏低（建议 ≥ 18），协议自检仍可跑"
  fi
else
  record fail node "缺少 Node.js（协议自检需要，不用它也能跑投屏）"
  if ensure_brew; then
    confirm "用 brew 安装 node？" && { brew install node && record ok node "Node.js 安装完成 $(node --version)"; }
  else
    warn "请手动安装：https://nodejs.org 或 brew install node"
  fi
fi

# Xcode / Swift 工具链：swift build 必须有
if xcode-select -p >/dev/null 2>&1; then
  CLT_PATH="$(xcode-select -p)"
  if has swift; then
    SWIFT_V="$(swift --version 2>/dev/null | head -1)"
    record ok swift "${SWIFT_V}"
    SWIFT_OK=1
  else
    record warn swift "已装 Xcode 工具链（${CLT_PATH}）但找不到 swift 命令"
    SWIFT_OK=0
  fi
else
  record fail xcode_clt "未安装 Xcode Command Line Tools（swift build 必需）"
  SWIFT_OK=0
  if can_install; then
    confirm "是否触发安装 Xcode Command Line Tools？（会弹出系统安装窗口，约 1–3 GB）" && {
      xcode-select --install || true
      info "安装窗口已弹出，装完再重新跑一次本脚本"
    }
  else
    info "手动安装：xcode-select --install"
  fi
fi

# ---------------------------------------------------------------- 硬件

step "③ 硬件与连线"

USB_TREE="$(system_profiler SPUSBDataType 2>/dev/null || true)"

# 找 Android 手机：优先用厂商 VID 判断
ANDROID_HIT=0
if [ -n "$USB_TREE" ]; then
  if printf '%s' "$USB_TREE" | grep -Eiq 'vendor_id: 0x(18d1|04e8|2717|2a70|12d1|22d9|2d95|0bb4|05c6|2e04|0e8d|0fce|1ebf)'; then
    ANDROID_HIT=1
  fi
fi

# accessory 模式下的 PID（AOA 握手成功后手机以 VID 0x18D1 重新枚举）
if printf '%s' "$USB_TREE" | grep -Eiq 'product_id: 0x2d0[0-5]'; then
  record ok android_accessory "已检测到 Android 处于 accessory 模式（0x2D0x），AOA 握手已成功过"
  ANDROID_HIT=2
elif [ "$ANDROID_HIT" = "1" ]; then
  record ok android_device "检测到 Android 手机已插上（厂商 VID 匹配）"
else
  record warn android_device "未检测到 Android 手机"
  info "三步排查：① 换一根【数据线】（大量线只能充电）② 手机解锁并点「允许访问」③ 换一个 USB 口，别用扩展坞的充电口"
fi

if has system_profiler; then
  USB_VER="$(printf '%s' "$USB_TREE" | grep -Eio 'USB (2\.0|3\.[0-9]) Bus' | head -1)"
  [ -n "$USB_VER" ] && info "总线：$USB_VER（USB 2.0 下 1080p60 是上限，更高分辨率请走 USB 3 口）"
fi

# ---------------------------------------------------------------- adb（兜底通道 + 安装 APK）

step "④ adb：装 APK 与 ADB 隧道兜底都用得到"

if has adb; then
  record ok adb "$(adb version 2>/dev/null | head -1)"
  ADB_DEVICES="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' | tr '\n' ' ')"
  if [ -n "$ADB_DEVICES" ]; then
    record ok adb_device "adb 已授权设备：${ADB_DEVICES% }"
  else
    warn "adb 在位，但列表为空"
    info "在手机上打开【开发者选项 → USB 调试】，再执行 adb devices"
  fi
else
  record fail adb "缺少 adb（安装手机 APK、以及 ADB 隧道兜底需要它）"
  if ensure_brew; then
    confirm "用 brew 安装 android-platform-tools（含 adb）？约 10 MB" && {
      brew install --cask android-platform-tools 2>/dev/null || brew install android-platform-tools 2>/dev/null
      if has adb; then record ok adb "adb 安装完成：$(adb version 2>/dev/null | head -1)"
      else warn "adb 安装未成功，请手动装：brew install --cask android-platform-tools"; fi
    }
  fi
fi

# ---------------------------------------------------------------- 协议自检（无需硬件）

step "⑤ 协议自检（不需要手机、不需要编译，秒级）"

PROTO_OK=0
if has node && [ -f "$ROOT_DIR/protocol/tests/test_protocol.js" ]; then
  if (cd "$ROOT_DIR" && node protocol/tests/test_protocol.js >/tmp/usbd-proto.log 2>&1); then
    TAIL="$(grep -E '通过 [0-9]+ 项' /tmp/usbd-proto.log | tail -1)"
    record ok protocol "编解码/分包/错位恢复：${TAIL:-通过}"
    if (cd "$ROOT_DIR" && node protocol/tests/check_consistency.js >/tmp/usbd-cons.log 2>&1); then
      TAIL2="$(grep -E '检查通过' /tmp/usbd-cons.log | tail -1)"
      record ok consistency "三端常量一致：${TAIL2:-一致}"
      PROTO_OK=1
    else
      record fail consistency "三端常量不一致！Swift/Kotlin/C 有一处漏改，详见 /tmp/usbd-cons.log"
    fi
  else
    record fail protocol "协议自检失败，详见 /tmp/usbd-cons.log"
  fi
else
  record warn protocol "跳过（需要 node，或不在仓库根目录运行）"
fi

# ---------------------------------------------------------------- Mac 端构建

step "⑥ Mac 端构建（swift build）"

BUILD_OK=0
if [ "$SWIFT_OK" = "1" ] && [ -d "$ROOT_DIR/macos" ]; then
  info "首次构建会拉依赖并编 Swift 包，通常 1–3 分钟，请稍候..."
  SWIFT_FILTER="tail -3"
  [ "$JSON_OUT" = "1" ] && SWIFT_FILTER="cat >/dev/null"
  if (cd "$ROOT_DIR/macos" && swift build 2>&1 | tee /tmp/usbd-swift-build.log | eval "$SWIFT_FILTER"); then
    if grep -qE '^\s*(error|Compiling|Build complete)' /tmp/usbd-swift-build.log && ! grep -q 'error:' /tmp/usbd-swift-build.log; then
      record ok swift_build "swift build 通过"
      BUILD_OK=1
    else
      record warn swift_build "swift build 有输出异常，详见 /tmp/usbd-swift-build.log"
    fi
  else
    record fail swift_build "swift build 失败，详见 /tmp/usbd-swift-build.log"
    info "常见原因：未装 Command Line Tools / Xcode 未接受许可（sudo xcodebuild -license accept）"
  fi
else
  record warn swift_build "跳过（缺 Swift 工具链，见第 ② 步）"
fi

# ---------------------------------------------------------------- Android 侧

step "⑦ Android 端"

ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ -d "$ANDROID_SDK/platform-tools" ] || [ -d "$ANDROID_SDK/cmdline-tools" ]; then
  record ok android_sdk "Android SDK：${ANDROID_SDK}"
elif has adb; then
  record ok android_sdk "有 adb（$(command -v adb)），通常意味着 platform-tools 已就位"
else
  record warn android_sdk "未检测到 Android SDK"
  info "只有三件事需要它：自己编 APK、跑 adb 安装、跑 Android 单元测试。"
  info "若只是想用：直接下载 CI 编好的 APK 即可，不必装 SDK。"
fi

if [ "$ANDROID_HIT" = "2" ]; then
  record ok phone_app "手机已被 Mac 拉起到 accessory 模式 → 「USB 副屏」App 已装并自动启动"
elif [ "$ANDROID_HIT" = "1" ]; then
  info "提醒：手机上必须先装一次「USB 副屏」APK，否则 Mac 拉起不了任何界面"
  info "装法见 docs/00-quickstart.md 第 3 步（adb install，或 CI 产物直接下载）"
fi

# ---------------------------------------------------------------- 汇总

if [ "$JSON_OUT" = "1" ]; then
  printf '{"ok":%s,"failed":%d,"warned":%d,"items":[%s]}\n' \
    "$([ "$FAILED" -eq 0 ] && echo true || echo false)" "$FAILED" "$WARNED" "$JSON_ITEMS"
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

printf '\n%s────────────────────────────────────────%s\n' "$DIM" "$N"
WARN_SUFFIX=""
[ "$WARNED" -gt 0 ] && WARN_SUFFIX="，另有 ${WARNED} 项提醒"

if [ "$FAILED" -eq 0 ]; then
  printf '%s结论：环境 OK%s%s\n' "$G$B" "$N" "$WARN_SUFFIX"
  printf '\n下一步：\n'
  printf '  1. 手机上装好「USB 副屏」APK（docs/00-quickstart.md 第 3 步）\n'
  printf '  2. 插上数据线，运行一键启动：\n'
  printf '     %sbash macos/scripts/usbdisplay-run.sh%s\n' "$C" "$N"
  printf '  3. 手机被自动拉起后即为副屏；触摸手机可反向操作 Mac\n'
else
  printf '%s结论：还差 %d 项%s%s\n' "$R$B" "$FAILED" "$N" "$WARN_SUFFIX" 
  printf '\n按上面 ✗ 的提示逐条处理，然后重跑本脚本。\n'
  printf '想让它自动装：%sbash macos/scripts/usbdisplay-doctor.sh --yes%s\n' "$C" "$N"
fi
printf '%s提示：CI 会构建可下载的 APK，见 docs/00-quickstart.md 第 3 步；也可用 %sbash macos/scripts/build-android-apk.sh%s 自行构建%s\n' "$DIM" "$C" "$DIM" "$N"

exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
