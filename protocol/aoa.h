/*
 * Android Open Accessory (AOA) v1/v2 常量。
 * Mac 侧（Host）用于把 Android 手机切换成 accessory 模式。
 */
#ifndef USBDISPLAY_AOA_H
#define USBDISPLAY_AOA_H

/* 标准 control request 类型 */
#define AOA_USB_DIR_OUT         0x00u
#define AOA_USB_TYPE_VENDOR     0x40u
#define AOA_CTRL_REQ_OUT        (AOA_USB_TYPE_VENDOR | AOA_USB_DIR_OUT) /* 0x40 */

/* AOA control requests */
#define AOA_GET_PROTOCOL        51u /* IN,  wValue=0, 返回 uint16 版本 */
#define AOA_SEND_STRING         52u /* OUT, wIndex=0:manufacturer 1:model
                                        2:description 3:version 4:URI
                                        5:serial  6..:reserved */
#define AOA_ACCESSORY_REGISTER  53u /* OUT, wValue=0 启动 accessory 模式 */
#define AOA_ACCESSORY_UNREGISTER 54u

/* AOA v2 (音频) */
#define AOA_SET_AUDIO_MODE      58u

/* 字符串索引 */
#define AOA_STRING_MANUFACTURER 0u
#define AOA_STRING_MODEL        1u
#define AOA_STRING_DESCRIPTION  2u
#define AOA_STRING_VERSION      3u
#define AOA_STRING_URI          4u
#define AOA_STRING_SERIAL       5u

/* Accessory 模式下 Android 呈现的接口描述 */
#define AOA_ACCESSORY_VID       0x18D1u
#define AOA_ACCESSORY_PID_V1    0x2D00u
#define AOA_ACCESSORY_PID_V2    0x2D01u
#define AOA_ACCESSORY_PID_ADB_V1 0x2D02u
#define AOA_ACCESSORY_PID_ADB_V2 0x2D03u
#define AOA_ACCESSORY_PID_AUDIO_V1 0x2D04u
#define AOA_ACCESSORY_PID_AUDIO_V2 0x2D05u

/* 接口：acc 模式下 Android 暴露的 interface class 0xFF 0xFF 0x00 */
#define AOA_IFACE_CLASS    0xFFu
#define AOA_IFACE_SUBCLASS 0xFFu
#define AOA_IFACE_PROTOCOL 0x00u

#define AOA_PROTOCOL_V1 1u
#define AOA_PROTOCOL_V2 2u

#endif /* USBDISPLAY_AOA_H */
