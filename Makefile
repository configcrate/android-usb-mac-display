# USB Display — 便捷入口
#
# 两条最常用的一键命令（在 Mac 上跑）：
#   make doctor   体检：缺什么一目了然，自动补装
#   make run      一键投屏
.PHONY: help doctor run apk apk-install check test test-protocol test-consistency \
        test-android lint-macos lint-android clean

help:
	@echo "USB Display — 最常用命令（Mac 上执行）"
	@echo ""
	@echo "  make doctor            一键体检：缺什么一目了然，可自动补装（--yes 免确认）"
	@echo "  make run               一键投屏（编译 + 检查手机 + 启动）"
	@echo "  make apk               构建手机端 APK（首次需 JDK 17 + Android SDK）"
	@echo "  make apk-install       构建 APK 并 adb 装到手机"
	@echo ""
	@echo "  make check             运行全部不依赖硬件的检查（CI 用这个）"
	@echo "  make test-protocol     协议编解码测试（任意平台）"
	@echo "  make test-consistency  三端常量一致性检查（任意平台）"
	@echo "  make test-android      Android 单元测试（需 JDK + Android SDK）"
	@echo "  make lint-macos        Swift 构建检查（需 macOS + Xcode）"
	@echo "  make lint-android      Android Lint"
	@echo "  make clean             清理构建产物"
	@echo ""
	@echo "新手教程：docs/00-quickstart.md"

# ---- 一键入口（macOS） ----

doctor:
	@bash macos/scripts/usbdisplay-doctor.sh

run:
	@bash macos/scripts/usbdisplay-run.sh

apk:
	@bash macos/scripts/build-android-apk.sh

apk-install:
	@bash macos/scripts/build-android-apk.sh --install

# ---- 可在任意平台运行 ----

check: test-protocol test-consistency

test: test-protocol test-consistency

test-protocol:
	@echo "== 协议编解码测试 =="
	@node protocol/tests/test_protocol.js

test-consistency:
	@echo "== 三端常量一致性检查 =="
	@node protocol/tests/check_consistency.js

# ---- 需要 macOS ----

lint-macos:
	@if [ "$$(uname)" != "Darwin" ]; then \
		echo "跳过：Swift 构建需要 macOS"; exit 0; \
	fi
	cd macos && swift build

# ---- 需要 Android SDK ----

test-android:
	cd android && ./gradlew :app:testDebugUnitTest

lint-android:
	cd android && ./gradlew :app:lintDebug

clean:
	rm -rf macos/.build android/build android/app/build android/.gradle
