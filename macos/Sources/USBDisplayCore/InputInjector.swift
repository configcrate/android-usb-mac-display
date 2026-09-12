import CoreGraphics
import Foundation

/// 把 Android 回传的触摸事件注入成 macOS 的鼠标事件。
///
/// 关键设计：
///  - 坐标是**归一化**的，注入前换算到虚拟显示器（或主屏）的像素坐标。
///  - 单指 → 鼠标移动 + 左键；双指 → 滚轮（可选，见 scrollFromTwoFinger）。
///  - 事件直接投到 HID 事件层（CGEvent.post(tap: .cghidEventTap)），
///    绕过应用层，保证被任意前台 App 接收。
public final class InputInjector {

    /// 注入目标屏幕的像素尺寸。屏幕分辨率变化时更新它。
    public var targetSize: CGSize

    /// 目标屏幕在全局坐标系中的原点（多显示器时非 0）。
    public var targetOrigin: CGPoint

    /// 是否把单指拖动映射成鼠标拖拽（否则只移动不按键）。
    /// 投屏场景一般希望"手指点按 = 鼠标点击"，故默认 true。
    public var emulateClick: Bool

    private var isPointerDown = false
    private var lastPoint: CGPoint = .zero

    public init(targetSize: CGSize = CGSize(width: 1920, height: 1080),
                targetOrigin: CGPoint = .zero,
                emulateClick: Bool = true) {
        self.targetSize = targetSize
        self.targetOrigin = targetOrigin
        self.emulateClick = emulateClick
    }

    /// 更新目标屏幕几何（分辨率变更 / 显示器拓扑变更时调用）。
    public func updateTarget(size: CGSize, origin: CGPoint) {
        self.targetSize = size
        self.targetOrigin = origin
    }

    public func handle(_ event: TouchEvent) {
        // 归一化 → 全局坐标
        let local = event.point(in: targetSize)
        let global = CGPoint(x: local.x + targetOrigin.x, y: local.y + targetOrigin.y)

        switch event.action {
        case .down:
            lastPoint = global
            isPointerDown = true
            postMove(to: global)
            if emulateClick { postButton(.leftMouseDown, at: global) }

        case .move:
            // 抖动过滤：1px 内的移动不产生事件，可显著降低 USB 回传与事件队列压力。
            // 但拖拽时需要保留全精度，故只在未按下时过滤。
            if !isPointerDown {
                let dx = abs(global.x - lastPoint.x)
                let dy = abs(global.y - lastPoint.y)
                guard dx >= 1 || dy >= 1 else { return }
            }
            lastPoint = global
            postMove(to: global)

        case .up:
            postMove(to: global)
            if emulateClick && isPointerDown { postButton(.leftMouseUp, at: global) }
            isPointerDown = false
            lastPoint = global

        case .cancel:
            if isPointerDown { postButton(.leftMouseUp, at: lastPoint) }
            isPointerDown = false
        }
    }

    /// 双指手势 → 滚轮。Android 侧上报 pointer_count=2 时走这里。
    public func scrollFromTwoFinger(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint) {
        let global = CGPoint(x: point.x + targetOrigin.x, y: point.y + targetOrigin.y)
        guard let scroll = CGEvent(scrollWheelEvent2Source: nil,
                                   units: .pixel,
                                   wheelCount: 2,
                                   wheel1: Int32(deltaY),
                                   wheel2: Int32(deltaX),
                                   wheel3: 0) else { return }
        scroll.location = global
        scroll.post(tap: .cghidEventTap)
    }

    // MARK: - 底层投递

    private func postMove(to point: CGPoint) {
        guard let move = CGEvent(mouseEventSource: nil,
                                 mouseType: isPointerDown && emulateClick ? .leftMouseDragged : .mouseMoved,
                                 mouseCursorPosition: point,
                                 mouseButton: .left) else { return }
        move.post(tap: .cghidEventTap)
    }

    private func postButton(_ type: CGEventType, at point: CGPoint) {
        guard let click = CGEvent(mouseEventSource: nil,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        // clickState 用于生成双击/三击；单次点击固定为 1
        click.setIntegerValueField(.mouseEventClickState, value: 1)
        click.post(tap: .cghidEventTap)
    }

    /// 注入键盘事件（Android 软键盘输入回传到 Mac）。
    public func handleKey(code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }
    public func releasePointer() {
        if isPointerDown && emulateClick { postButton(.leftMouseUp, at: lastPoint) }
        isPointerDown = false
    }
}
