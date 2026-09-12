#!/usr/bin/env bash
#
# build-android-apk.sh — 构建手机端「USB 副屏」APK
#
# 在 Mac 上跑：
#   bash macos/scripts/build-android-apk.sh                  # 构建 debug APK（未签名，可直接装）
#   bash macos/scripts/build-android-apk.sh --release        # 构建 release APK
#   bash macos/scripts/build-android-apk.sh --install        # 构建完直接 adb install 到手机
#
# 构建需要 JDK 17 与 Android SDK（compileSdk 34）。
# 如果没有 SDK，脚本会尝试用 Homebrew 装命令行工具并接受许可。
#
# 不想在 Mac 上装 SDK？CI 会自动构建 APK，直接在流水线产物里下载即可。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ANDROID_DIR="${ROOT_DIR}/android"

VARIANT="assembleDebug"
DO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --release) VARIANT="assembleRelease" ;;
    --debug)   VARIANT="assembleDebug" ;;
    --install) DO_INSTALL=1 ;;
    -h|--help) sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=''; DIM=''; G=''; Y=''; R=''; N=''; fi
die() { printf '%s✗%s %s\n' "$R" "$N" "$1" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# ---- JDK ----
step "① JDK"
if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
  JAVA="${JAVA_HOME}/bin/java"
elif command -v java >/dev/null 2>&1; then
  JAVA="$(command -v java)"
else
  die "找不到 java。请装 JDK 17：brew install --cask temurin@17
   或从 https://adoptium.net 下载"
fi
"$JAVA" -version 2>&1 | head -1
printf '  %s✓%s %s\n' "$G" "$N" "$JAVA"

# ---- Android SDK ----
step "② Android SDK"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ ! -d "$SDK" ]; then
  printf '  %s!%s 未找到 Android SDK（期望路径 %s）\n' "$Y" "$N" "$SDK"
  if command -v brew >/dev/null 2>&1; then
    printf '  %s·%s 尝试用 Homebrew 安装命令行工具...\n' "$DIM" "$N"
    brew install --cask android-commandlinetools || die "安装失败，手动装：brew install --cask android-commandlinetools"
    SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    mkdir -p "$SDK"
    yes | "${SDK}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
  else
    die "请先装 Android SDK：https://developer.android.com/studio，或跑 CI 下载现成 APK"
  fi
fi
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
# 补齐 SDK 依赖
if [ -x "${SDK}/cmdline-tools/latest/bin/sdkmanager" ]; then
  printf '  %s·%s 校验 platform-tools / platform-34 / build-tools-34...\n' "$DIM" "$N"
  yes | "${SDK}/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" \
    "platform-tools" "platforms;android-34" "build-tools;34.0.0" >/dev/null 2>&1 || true
fi
printf '  %s✓%s ANDROID_HOME=%s\n' "$G" "$N" "$SDK"

# ---- 构建 ----
step "③ 构建 ${VARIANT}"
cd "$ANDROID_DIR" || die "找不到 android/ 目录"
if [ ! -f ./gradlew ]; then
  die "android/gradlew 不存在。本仓库的 gradle wrapper 是入库的，请确认没有把 android/gradle/ 或 gradlew 删掉"
fi
chmod +x ./gradlew
# --no-daemon：CI / 一次性构建不要留后台守护进程；
# 首跑 wrapper 会按 gradle/wrapper/gradle-wrapper.properties 下载 Gradle 8.7（约 130 MB）
./gradlew "$VARIANT" --no-daemon || die "构建失败。首跑需要联网下载 Gradle 与依赖，请检查网络"

# ---- 产物 ----
step "④ 产物"
APK="$(find "${ANDROID_DIR}/app/build/outputs/apk" -name '*.apk' -type f 2>/dev/null | head -1)"
[ -n "$APK" ] || die "没找到 APK，请检查上面的构建日志"
SIZE="$(du -h "$APK" | cut -f1)"
printf '  %s✓%s %s（%s）\n' "$G" "$N" "$APK" "$SIZE"

if [ "$DO_INSTALL" = "1" ]; then
  step "⑤ 安装到手机"
  command -v adb >/dev/null 2>&1 || die "找不到 adb。装一下：brew install --cask android-platform-tools"
  DEV="$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
  [ -n "$DEV" ] || die "adb 没看到已授权设备。打开手机【开发者选项 → USB 调试】，插线后手机点「允许」"
  adb -s "$DEV" install -r "$APK" && printf '  %s✓%s 已安装到 %s\n' "$G" "$N" "$DEV"
  printf '\n  现在插着线运行 Mac 端即可：bash macos/scripts/usbdisplay-run.sh\n'
else
  printf '\n  安装到手机：\n'
  printf '    adb install -r "%s"\n' "$APK"
  printf '  或在手机上打开文件管理器点开这个 APK（需允许安装未知来源）\n'
fi
