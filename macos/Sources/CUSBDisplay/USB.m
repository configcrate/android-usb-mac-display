#include "CUSBDisplay.h"
#include <libusb.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct CCUSB {
    libusb_context *context;
    libusb_device_handle *handle;
    int interface_number;
    uint8_t in_endpoint, out_endpoint;
    pthread_rwlock_t lifetime;
};
static int accessory(uint16_t vid, uint16_t pid) {
    return vid == 0x18d1 && (pid == 0x2d00 || pid == 0x2d01);
}
static int vendor_candidate(uint16_t vid, uint16_t pid) {
    static const uint16_t vendors[] = {0x18d1,0x04e8,0x2717,0x2a70,0x12d1,0x22d9,
        0x2d95,0x0bb4,0x05c6,0x2e04,0x0e8d,0x0fce,0x1ebf};
    if (accessory(vid,pid)) return 1;
    for (size_t i=0; i<sizeof(vendors)/sizeof(*vendors); ++i)
        if (vid==vendors[i]) return 1;
    return 0;
}
// A vendor ID alone is not proof of a phone (e.g. Samsung SSDs).
// Inspect descriptors before issuing any vendor request. Unknown devices
// remain untouched; selecting File Transfer on the phone exposes MTP.
static int candidate(libusb_device *device, const struct libusb_device_descriptor *d) {
    if (accessory(d->idVendor,d->idProduct)) return 1;
    if (!vendor_candidate(d->idVendor,d->idProduct)) return 0;
    struct libusb_config_descriptor *config=NULL;
    if (libusb_get_config_descriptor(device,0,&config)<0) return 0;
    int match=config->bNumInterfaces==0 && d->bDeviceClass==0;
    int unsafe=0;
    for (int i=0;i<config->bNumInterfaces;++i) {
        const struct libusb_interface *interface=&config->interface[i];
        for (int j=0;j<interface->num_altsetting;++j) {
            const struct libusb_interface_descriptor *a=&interface->altsetting[j];
            // Reject mass-storage / HID / audio devices, including composite ones.
            if (a->bInterfaceClass==8 || a->bInterfaceClass==3 || a->bInterfaceClass==1) unsafe=1;
            if (a->bInterfaceClass==6 ||
                (a->bInterfaceClass==0xff && a->bInterfaceSubClass==0x42 && a->bInterfaceProtocol==1) ||
                (a->bInterfaceClass==0xff && a->bInterfaceSubClass==0xff && a->bInterfaceProtocol==0))
                match=1;
        }
    }
    libusb_free_config_descriptor(config);
    return match && !unsafe;
}
CCUSB *cc_usb_create(void) {
    CCUSB *u=calloc(1,sizeof(*u));
    if (!u) return NULL;
    if (libusb_init(&u->context)<0) { free(u); return NULL; }
    pthread_rwlock_init(&u->lifetime,NULL);
    u->interface_number=-1;
    return u;
}
void cc_usb_close(CCUSB *u) {
    if (!u) return;
    pthread_rwlock_wrlock(&u->lifetime);
    if (u->handle) {
        if (u->interface_number>=0) libusb_release_interface(u->handle,u->interface_number);
        libusb_close(u->handle); u->handle=NULL;
    }
    u->interface_number=-1;
    pthread_rwlock_unlock(&u->lifetime);
}
void cc_usb_destroy(CCUSB *u) {
    if (!u) return;
    cc_usb_close(u); libusb_exit(u->context);
    pthread_rwlock_destroy(&u->lifetime); free(u);
}
int cc_usb_probe(uint16_t *vendor,uint16_t *product) {
    CCUSB *u=cc_usb_create();
    if (!u) return LIBUSB_ERROR_OTHER;
    libusb_device **list=NULL;
    ssize_t n=libusb_get_device_list(u->context,&list);
    int found=0;
    for (ssize_t i=0;i<n;++i) {
        struct libusb_device_descriptor d;
        if (!libusb_get_device_descriptor(list[i],&d) && candidate(list[i],&d)) {
            *vendor=d.idVendor; *product=d.idProduct; ++found;
        }
    }
    if (list) libusb_free_device_list(list,1);
    cc_usb_destroy(u);
    return n<0 ? (int)n : found;
}
static int open_endpoints(CCUSB *u) {
    struct libusb_config_descriptor *c=NULL;
    int rc=libusb_get_active_config_descriptor(libusb_get_device(u->handle),&c);
    if (rc<0) return rc;
    rc=LIBUSB_ERROR_NOT_FOUND;
    for (int i=0;i<c->bNumInterfaces;++i) {
        const struct libusb_interface *in=&c->interface[i];
        for (int j=0;j<in->num_altsetting;++j) {
            const struct libusb_interface_descriptor *a=&in->altsetting[j];
            // AOA only; never claim the optional ADB interface ff/42/01.
            if (a->bInterfaceClass!=0xff || a->bInterfaceSubClass!=0xff || a->bInterfaceProtocol!=0) continue;
            uint8_t ep_in=0,ep_out=0;
            for (int e=0;e<a->bNumEndpoints;++e) {
                const struct libusb_endpoint_descriptor *ep=&a->endpoint[e];
                if ((ep->bmAttributes&LIBUSB_TRANSFER_TYPE_MASK)!=LIBUSB_TRANSFER_TYPE_BULK) continue;
                if (ep->bEndpointAddress&LIBUSB_ENDPOINT_IN) ep_in=ep->bEndpointAddress;
                else ep_out=ep->bEndpointAddress;
            }
            if (!ep_in || !ep_out) continue;
            rc=libusb_claim_interface(u->handle,a->bInterfaceNumber);
            if (rc<0) goto done;
            u->interface_number=a->bInterfaceNumber;
            if (a->bAlternateSetting) {
                rc=libusb_set_interface_alt_setting(u->handle,a->bInterfaceNumber,a->bAlternateSetting);
                if (rc<0) goto done;
            }
            u->in_endpoint=ep_in; u->out_endpoint=ep_out; rc=0; goto done;
        }
    }
done:
    libusb_free_config_descriptor(c); return rc;
}
int cc_usb_open(CCUSB *u) {
    if (!u) return LIBUSB_ERROR_INVALID_PARAM;
    cc_usb_close(u);
    libusb_device **list=NULL,*selected=NULL;
    ssize_t count=libusb_get_device_list(u->context,&list);
    if (count<0) return (int)count;
    int candidates=0,rc=LIBUSB_ERROR_NO_DEVICE;
    struct libusb_device_descriptor desc={0};
    for (ssize_t i=0;i<count;++i) {
        struct libusb_device_descriptor d;
        if (!libusb_get_device_descriptor(list[i],&d) && candidate(list[i],&d)) {
            selected=list[i]; desc=d; ++candidates;
        }
    }
    if (candidates!=1) { rc=candidates>1 ? -1000 : LIBUSB_ERROR_NO_DEVICE; goto done; }
    rc=libusb_open(selected,&u->handle);
    if (rc<0) goto done;
    uint8_t bus=libusb_get_bus_number(selected),ports[8]={0};
    int port_count=libusb_get_port_numbers(selected,ports,sizeof(ports));
    if (accessory(desc.idVendor,desc.idProduct)) {
        libusb_free_device_list(list,1);
        rc=open_endpoints(u);
        if (rc<0) cc_usb_close(u);
        return rc;
    }
    uint8_t version[2]={0};
    rc=libusb_control_transfer(u->handle,0xc0,51,0,0,version,2,1000);
    if (rc!=2 || (version[0]|version[1]<<8)<1) {
        rc=rc<0 ? rc : LIBUSB_ERROR_NOT_SUPPORTED; goto done;
    }
    const char *strings[]={"ConfigCrate","USB Display","USB Display Link","1.0",
        "https://configcrate.com","usbdisplay-0001"};
    for (int i=0;i<6;++i) {
        int len=(int)strlen(strings[i])+1;
        rc=libusb_control_transfer(u->handle,0x40,52,0,(uint16_t)i,
            (unsigned char *)strings[i],(uint16_t)len,1000);
        if (rc!=len) { rc=rc<0 ? rc : LIBUSB_ERROR_IO; goto done; }
    }
    rc=libusb_control_transfer(u->handle,0x40,53,0,0,NULL,0,1000);
    if (rc<0 && rc!=LIBUSB_ERROR_NO_DEVICE) goto done;
    cc_usb_close(u); libusb_free_device_list(list,1); list=NULL;
    for (int retry=0;retry<100;++retry) {
        struct timespec delay={0,100000000}; nanosleep(&delay,NULL);
        count=libusb_get_device_list(u->context,&list);
        if (count<0) return (int)count;
        for (ssize_t i=0;i<count;++i) {
            struct libusb_device_descriptor d;
            uint8_t current[8]={0};
            int n=libusb_get_port_numbers(list[i],current,sizeof(current));
            if (libusb_get_device_descriptor(list[i],&d) || !accessory(d.idVendor,d.idProduct)) continue;
            if (libusb_get_bus_number(list[i])!=bus || port_count<=0 ||
                n!=port_count || memcmp(current,ports,(size_t)n)) continue;
            rc=libusb_open(list[i],&u->handle);
            libusb_free_device_list(list,1); list=NULL;
            if (rc<0) return rc;
            rc=open_endpoints(u);
            if (rc<0) cc_usb_close(u);
            return rc;
        }
        libusb_free_device_list(list,1); list=NULL;
    }
    return LIBUSB_ERROR_TIMEOUT;
done:
    if (list) libusb_free_device_list(list,1);
    cc_usb_close(u); return rc;
}
static int transfer(CCUSB *u,int read,uint8_t *data,int size,int *actual) {
    *actual=0;
    pthread_rwlock_rdlock(&u->lifetime);
    int rc=u->handle ? libusb_bulk_transfer(u->handle,read ? u->in_endpoint:u->out_endpoint,
        data,size,actual,read ? 200:1000) : LIBUSB_ERROR_NO_DEVICE;
    pthread_rwlock_unlock(&u->lifetime); return rc;
}
int cc_usb_read(CCUSB *u,uint8_t *d,int n,int *a) { return transfer(u,1,d,n,a); }
int cc_usb_write(CCUSB *u,const uint8_t *d,int n,int *a) { return transfer(u,0,(uint8_t *)d,n,a); }
const char *cc_usb_error(int c) {
    return c==-1000 ? "Multiple Android candidates: connect only one phone":libusb_error_name(c);
}
