package dev.configcrate.usbdisplay.input

import android.view.MotionEvent
import dev.configcrate.usbdisplay.render.VideoSurfaceView
import dev.configcrate.usbdisplay.transport.TouchAction
import dev.configcrate.usbdisplay.transport.TouchEvent

/** First version supports one-finger mouse click/drag only, not multitouch. */
class TouchForwarder(private val view: VideoSurfaceView) {
    var send: ((TouchEvent) -> Unit)? = null
    private var active = -1
    private var seq = 0L
    fun onTouchEvent(e: MotionEvent): Boolean {
        val action = when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { active = e.getPointerId(0); TouchAction.DOWN }
            MotionEvent.ACTION_MOVE -> TouchAction.MOVE
            MotionEvent.ACTION_UP -> TouchAction.UP
            MotionEvent.ACTION_CANCEL -> TouchAction.CANCEL
            MotionEvent.ACTION_POINTER_UP -> {
                if (e.getPointerId(e.actionIndex) != active) return true
                TouchAction.UP
            }
            else -> return true
        }
        if (active < 0) return true
        val index = e.findPointerIndex(active).takeIf { it >= 0 } ?: 0
        val (x, y) = view.normalizeTouch(e.getX(index), e.getY(index))
        seq = (seq + 1) and 0xffffffffL
        send?.invoke(TouchEvent(seq, x, y, (e.getPressure(index).coerceIn(0f, 1f) * 65535).toInt(),
            action, 1, active))
        if (action == TouchAction.UP || action == TouchAction.CANCEL) active = -1
        return true
    }
}
