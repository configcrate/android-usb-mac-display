#ifndef CC_USB_DISPLAY_H
#define CC_USB_DISPLAY_H
#include <stdint.h>
typedef struct CCUSB CCUSB;
CCUSB *cc_usb_create(void);
void cc_usb_destroy(CCUSB *);
int cc_usb_probe(uint16_t *, uint16_t *);
int cc_usb_open(CCUSB *);
int cc_usb_read(CCUSB *, uint8_t *, int, int *);
int cc_usb_write(CCUSB *, const uint8_t *, int, int *);
void cc_usb_close(CCUSB *);
const char *cc_usb_error(int);
int cc_virtual_available(void);
void *cc_virtual_create(const char *, uint32_t, uint32_t, double, uint32_t *, char *, int);
void cc_virtual_destroy(void *);
#endif
