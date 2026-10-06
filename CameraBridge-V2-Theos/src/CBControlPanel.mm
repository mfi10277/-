#import "CBControlPanel.h"
#import "CBSettings.h"
#import "CBStreamManager.h"
#import <UIKit/UIKit.h>

@implementation CBControlPanel
+ (instancetype)shared { static CBControlPanel*s; static dispatch_once_t o; dispatch_once(&o,^{s=[CBControlPanel new];}); return s; }
- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc=UIApplication.sharedApplication.keyWindow.rootViewController;
        if (!vc) return;
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"CameraBridge V2" message:@"输入 M3U8 或 HTTP-FLV 地址" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"https://.../live.m3u8 或 http://...flv"; f.text=[CBSettings shared].streamURL; }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"保存并启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){
            [CBSettings shared].streamURL=a.textFields.firstObject.text ?: @"";
            [CBSettings shared].enabled=YES; [[CBSettings shared] save]; [[CBStreamManager shared] stop]; [[CBStreamManager shared] startIfNeeded];
        }]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}
@end
