#!/usr/bin/env bash
#
# usbdisplay-run.sh — Mac 端一键投屏
#
# 它做四件事，然后一直把画面推到手机上：
#   1. 检查环境（缺工具会告诉你怎么办，不自作主张装）
#   2. 编译 Mac 端（首次约 1–3 分钟，之后秒级）
#   3. 检查手机是否插好
#   4. 启动投屏，Ctrl-C 退出
#
#   bash macos/scripts/usbdisplay-run.sh                      # 默认 1920x1080@60
#   bash macos/scripts/usbdisplay-run.sh --fps 30             # 手机发烫 / 掉帧时降帧率
#   bash macos/scripts/usbdisplay-run.sh --width 2560 --height 1440
#   bash macos/scripts/usbdisplay-run.sh --backend virtual    # 真副屏（私有 API，可选）
#
# 任何多余参数会原样透传给 usbdisplayctl，见 --help。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MACOS_DIR="${ROOT_DIR}/macos"

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=''; DIM=''; G=''; Y=''; R=''; C=''; N=''
fi

die() { printf '%s✗%s %s\n' "$R" "$N" "$1" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

[ "$(uname -s)" = "Darwin" ] || die "本脚本只能在 macOS 上运行（Mac 是 USB Host 侧）"
command -v pkg-config >/dev/null 2>&1 || die "先安装依赖：brew install libusb pkg-config"
pkg-config --exists libusb-1.0 || die "缺少 libusb：brew install libusb pkg-config"
command -v swift >/dev/null 2>&1 || die "找不到 swift。先装 Xcode Command Line Tools：
    xcode-select --install
   然后重跑本脚本"

# ---- 1. 环境快检（不打断流程，只提示） ----
step "① 环境快检"
if command -v adb >/dev/null 2>&1; then
  PHONES="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' | tr '\n' ' ')"
  [ -n "$PHONES" ] && printf '  %s✓%s 手机（adb 已授权）：%s\n' "$G" "$N" "${PHONES% }"
elif system_profiler SPUSBDataType 2>/dev/null | grep -Eiq 'vendor_id: 0x(18d1|04e8|2717|2a70|12d1|22d9|2d95|0bb4|05c6|2e04|0e8d|0fce|1ebf)'; then
  printf '  %s✓%s 检测到 Android 手机已插上\n' "$G" "$N"
else
  printf '  %s!%s 没看到手机。请先插入数据线；启动失败后需处理原因并重跑。\n' "$Y" "$N"
  printf '  %s  排查：换数据线（很多线只能充电）→ 手机解锁确认授权 → 换 USB 口（别用扩展坞充电口）%s\n' "$DIM" "$N"
fi
printf '  %s如需完整体检（并自动补装缺失工具）：bash macos/scripts/usbdisplay-doctor.sh%s\n' "$DIM" "$N"

# ---- 2. 编译 ----
step "② 编译 Mac 端"
printf '  %s首次编译约 1–3 分钟，之后增量编译是秒级%s\n' "$DIM" "$N"
if ! (cd "$MACOS_DIR" && swift build 2>&1 | tail -5); then
  die "swift build 失败。先跑 bash macos/scripts/usbdisplay-doctor.sh 定位问题"
fi
printf '  %s✓%s 编译完成\n' "$G" "$N"

# ---- 3. 启动 ----
step "③ 启动投屏"
printf '  %s手机没装 APK 的话，Mac 会握手成功但手机不弹界面 —— 见 docs/00-quickstart.md 第 3 步%s\n' "$DIM" "$N"
printf '  %s按 Ctrl-C 退出（会自动释放虚拟显示器）%s\n\n' "$DIM" "$N"

exec bash -c "cd '$MACOS_DIR' && exec swift run usbdisplayctl run \"\$@\"" _ "$@"
