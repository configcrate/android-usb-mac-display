# USB Display — 便捷入口
.PHONY: help check test test-protocol test-consistency test-android lint-macos lint-android clean

help:
	@echo "USB Display 开发命令"
	@echo ""
	@echo "  make check             运行全部不依赖硬件的检查（CI 用这个）"
	@echo "  make test-protocol     协议编解码测试"
	@echo "  make test-consistency  三端常量一致性检查"
	@echo "  make test-android      Android 单元测试（需 JDK + Gradle）"
	@echo "  make lint-macos        Swift 语法检查（需 macOS + Xcode）"
	@echo "  make lint-android      Android Lint"
	@echo "  make clean             清理构建产物"

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
