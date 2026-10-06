#import "CBControlPanel.h"
#import "CBSettings.h"
#import "CBStreamManager.h"
#import <UIKit/UIKit.h>

@implementation CBControlPanel

+ (instancetype)shared {
    static CBControlPanel *s;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [CBControlPanel new]; });
    return s;
}

#pragma mark - Active view controller (iOS 13+ scene lifecycle, no keyWindow)

- (UIViewController *)topViewController:(UIViewController *)vc {
    if (vc.presentedViewController) {
        return [self topViewController:vc.presentedViewController];
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return [self topViewController:((UINavigationController *)vc).visibleViewController];
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return [self topViewController:((UITabBarController *)vc).selectedViewController];
    }
    return vc;
}

- (UIViewController *)activeViewController {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && w.rootViewController) return [self topViewController:w.rootViewController];
        }
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.rootViewController) return [self topViewController:w.rootViewController];
        }
    }
    return nil;
}

#pragma mark - UI

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = [self activeViewController];
        if (!vc) return;

        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"CameraBridge V2"
                                                                   message:@"输入 HLS (.m3u8) 或 HTTP-FLV (.flv) 视频地址"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){
            f.placeholder = @"https://host/live.m3u8 或 http://host/live.flv";
            f.text = [CBSettings shared].streamURL;
            f.keyboardType = UIKeyboardTypeURL;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
            f.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        [a addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            NSString *url = [a.textFields.firstObject.text
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
            CBSettings *s = [CBSettings shared];
            s.streamURL = url;
            s.enabled = YES;
            [s save];
            [[CBStreamManager shared] stop];
            [[CBStreamManager shared] startIfNeeded];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"停用（恢复原摄像头）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
            [CBSettings shared].enabled = NO;
            [[CBSettings shared] save];
            [[CBStreamManager shared] stop];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"画面设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            [self showVideoSettingsFrom:vc];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

- (void)showVideoSettingsFrom:(UIViewController *)vc {
    CBSettings *s = [CBSettings shared];
    NSString *aspect = s.aspectMode == 0 ? @"Fill" : (s.aspectMode == 1 ? @"Fit" : @"Stretch");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"画面设置"
                                                               message:[NSString stringWithFormat:@"镜像: %@\n旋转: %ld°\n比例: %@",
                                                                        s.mirror ? @"开" : @"关",
                                                                        (long)s.rotation,
                                                                        aspect]
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    void (^cycle)(void) = ^{ [self showVideoSettingsFrom:vc]; };

    [a addAction:[UIAlertAction actionWithTitle:@"镜像：切换" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.mirror = !s.mirror; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"旋转：0°" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.rotation = 0; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"旋转：90°" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.rotation = 90; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"旋转：180°" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.rotation = 180; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"旋转：270°" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.rotation = 270; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"比例：Fill（铺满裁剪）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.aspectMode = 0; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"比例：Fit（保持比例，黑边）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.aspectMode = 1; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"比例：Stretch（拉伸）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        s.aspectMode = 2; [s save]; cycle();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];

    if (a.popoverPresentationController) {
        a.popoverPresentationController.sourceView = vc.view;
        a.popoverPresentationController.sourceRect = vc.view.bounds;
        a.popoverPresentationController.permittedArrowDirections = 0;
    }
    [vc presentViewController:a animated:YES completion:nil];
}

@end
