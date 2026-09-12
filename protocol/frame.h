/*
 * USB Display Wire Protocol v1 — 共享定义
 * 与 android/.../transport/FrameProtocol.kt 必须保持完全一致。
 * 全部小端序，1 字节对齐。
 */
#ifndef USBDISPLAY_FRAME_H
#define USBDISPLAY_FRAME_H

#include <stdint.h>

#define USBD_MAGIC0 0x55u /* 'U' */
#define USBD_MAGIC1 0x53u /* 'S' */
#define USBD_MAGIC2 0x42u /* 'B' */
#define USBD_MAGIC3 0x44u /* 'D' */
#define USBD_VERSION 1u

#define USBD_HEADER_SIZE 16u
#define USBD_MAX_TRANSFER (2u * 1024u * 1024u)

/* 帧类型 */
enum usbd_frame_type {
    USBD_TYPE_VIDEO           = 0x01,
    USBD_TYPE_CONFIG          = 0x02,
    USBD_TYPE_TOUCH           = 0x10,
    USBD_TYPE_KEY             = 0x11,
    USBD_TYPE_PING            = 0x20,
    USBD_TYPE_PONG            = 0x21,
    USBD_TYPE_REQUEST_KEYFRAME= 0x30,
    USBD_TYPE_STATS           = 0x40,
};

/* flags */
#define USBD_FLAG_KEYFRAME          0x0001u
#define USBD_FLAG_CONFIG_EPOCH_CHANGED 0x0002u

/* 触摸动作 */
enum usbd_touch_action {
    USBD_TOUCH_DOWN   = 0,
    USBD_TOUCH_MOVE   = 1,
    USBD_TOUCH_UP     = 2,
    USBD_TOUCH_CANCEL = 3,
};

/* STATS TLV tag */
enum usbd_stats_tag {
    USBD_STATS_RTT_US         = 1,
    USBD_STATS_ENCODE_US      = 2,
    USBD_STATS_DECODE_US      = 3,
    USBD_STATS_QUEUE_FRAMES   = 4,
    USBD_STATS_DROPPED_FRAMES = 5,
    USBD_STATS_TARGET_BITRATE = 6,
};

#if defined(_MSC_VER)
#pragma pack(push, 1)
#define USBD_PACKED
#else
#define USBD_PACKED __attribute__((packed))
#endif

typedef struct USBD_PACKED {
    uint8_t  magic[4];      /* "USBD" */
    uint8_t  version;       /* USBD_VERSION */
    uint8_t  type;          /* usbd_frame_type */
    uint16_t flags;         /* USBD_FLAG_* */
    uint32_t seq;           /* 单调递增 */
    uint32_t payload_len;   /* 不含头，不含 padding */
} usbd_frame_header_t;      /* 16 bytes */

typedef struct USBD_PACKED {
    uint32_t seq;
    uint16_t x;             /* 归一化 0..65535 */
    uint16_t y;             /* 归一化 0..65535 */
    uint16_t pressure;      /* 0..65535 */
    uint8_t  action;        /* usbd_touch_action */
    uint8_t  pointer_count;
    uint16_t pointer_id;
    uint16_t reserved;
} usbd_touch_event_t;       /* 16 bytes */

typedef struct USBD_PACKED {
    uint32_t epoch;
    uint16_t width;
    uint16_t height;
    uint16_t fps;
    uint8_t  codec;         /* 0=H264 1=AV1 */
    uint8_t  reserved;
    uint32_t bitrate_bps;
} usbd_config_t;            /* 16 bytes */

#if defined(_MSC_VER)
#pragma pack(pop)
#endif

/* 编译期尺寸断言：两端布局必须一致 */
typedef char usbd_assert_header_size[(sizeof(usbd_frame_header_t) == 16) ? 1 : -1];
typedef char usbd_assert_touch_size[(sizeof(usbd_touch_event_t) == 16) ? 1 : -1];
typedef char usbd_assert_config_size[(sizeof(usbd_config_t) == 16) ? 1 : -1];

#endif /* USBDISPLAY_FRAME_H */
