#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "CUSBDisplay.h"
#include <stdio.h>
// Typed declarations; runtime class lookup avoids linking private class symbols.
@interface CCDescriptor : NSObject
@property NSString *name;
@property unsigned int maxPixelsWide,maxPixelsHigh,vendorID,productID,serialNum;
@property CGSize sizeInMillimeters;
@property dispatch_queue_t queue;
@property(copy) void (^terminationHandler)(id,id);
@end
@interface CCMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CCSettings : NSObject
@property unsigned int hiDPI;
@property NSArray *modes;
@end
@interface CCDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(readonly) unsigned int displayID;
@end
int cc_virtual_available(void) {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor") &&
        NSClassFromString(@"CGVirtualDisplayMode") && NSClassFromString(@"CGVirtualDisplaySettings");
}
void *cc_virtual_create(const char *name,uint32_t w,uint32_t h,double hz,uint32_t *did,char *error,int cap) {
    __block void *result=NULL;
    void (^create)(void)=^{
        @try {
            if (!cc_virtual_available()) @throw [NSException exceptionWithName:@"Unavailable" reason:@"Virtual display API unavailable" userInfo:nil];
            CCDescriptor *d=[(id)NSClassFromString(@"CGVirtualDisplayDescriptor") new];
            d.name=[NSString stringWithUTF8String:name]; d.maxPixelsWide=w; d.maxPixelsHigh=h;
            d.sizeInMillimeters=CGSizeMake(345,195);
            d.vendorID=0x4343; d.productID=1; d.serialNum=1;
            d.queue=dispatch_get_main_queue(); d.terminationHandler=^(id a,id b){};
            CCDisplay *display=[(CCDisplay *)[(id)NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
            CCSettings *s=[(id)NSClassFromString(@"CGVirtualDisplaySettings") new];
            CCMode *mode=[(CCMode *)[(id)NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:w height:h refreshRate:hz];
            if (!display || !mode) @throw [NSException exceptionWithName:@"Creation" reason:@"Virtual display allocation failed" userInfo:nil];
            s.hiDPI=0; s.modes=@[mode];
            if (![display applySettings:s] || !display.displayID)
                @throw [NSException exceptionWithName:@"Settings" reason:@"Virtual display settings rejected" userInfo:nil];
            *did=display.displayID; result=(__bridge_retained void *)display;
        } @catch (NSException *e) { snprintf(error,(size_t)cap,"%s",e.reason.UTF8String ?: "Creation failed"); }
    };
    if ([NSThread isMainThread]) create(); else dispatch_sync(dispatch_get_main_queue(),create);
    return result;
}
void cc_virtual_destroy(void *h) {
    if (!h) return;
    void (^destroy)(void)=^{ id display=CFBridgingRelease(h); (void)display; };
    if ([NSThread isMainThread]) destroy(); else dispatch_sync(dispatch_get_main_queue(),destroy);
}
