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

#pragma mark - Active view controller (iOS 13+ scene lifecycle, no keyWindow-only)

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

#pragma mark - Panel lifecycle

- (void)panelDidDismiss {
    self.presenting = NO;
    self.currentAlert = nil;
    NSLog(@"[CBV2] control panel dismissed");
}

- (void)showNotice:(NSString *)msg from:(UIViewController *)vc {
    // The dismissing alert is still animating out; delay slightly before presenting a new one.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.presenting || self.currentAlert) return;
        UIViewController *top = vc ?: [self activeViewController];
        if (!top) return;
        UIAlertController *n = [UIAlertController alertControllerWithTitle:@"CameraBridge V2"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [n addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x){
            [self panelDidDismiss];
        }]];
        self.presenting = YES;
        self.currentAlert = n;
        [top presentViewController:n animated:YES completion:nil];
    });
}

#pragma mark - Main panel

- (void)show {
    if (self.presenting || self.currentAlert) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.presenting || self.currentAlert) return;
        UIViewController *vc = [self activeViewController];
        if (!vc) return;

        CBSettings *s = [CBSettings shared];
        NSString *status;
        if (!s.enabled) {
            status = @"○ 已停用";
        } else if (s.streamURL.length == 0) {
            status = @"○ 未配置";
        } else {
            status = @"● 已启用";
        }
        NSString *aspect = s.aspectMode == 0 ? @"Fill" : (s.aspectMode == 1 ? @"Fit" : @"Stretch");
        NSString *message = [NSString stringWithFormat:
                             @"状态：%@\n直播源：%@\n画面：%@\n镜像：%@\n旋转：%ld°",
                             status,
                             s.streamURL.length ? s.streamURL : @"未设置",
                             aspect,
                             s.mirror ? @"开" : @"关",
                             (long)s.rotation];

        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"CameraBridge V2"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){
            f.placeholder = @"https://host/live.m3u8 或 http://host/live.flv";
            f.text = s.streamURL;
            f.keyboardType = UIKeyboardTypeURL;
            f.autocorrectionType = UITextAutocorrectionTypeNo;
            f.autocapitalizationType = UITextAutocapitalizationTypeNone;
            f.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        __weak __typeof__(self) weakSelf = self;

        [a addAction:[UIAlertAction actionWithTitle:@"保存并启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            [weakSelf panelDidDismiss];
            NSString *url = [a.textFields.firstObject.text
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
            CBSettings *ss = [CBSettings shared];
            ss.streamURL = url;
            ss.enabled = YES;
            [ss save];
            [[CBStreamManager shared] stop];
            if (url.length == 0) {
                [weakSelf showNotice:@"请先输入直播源地址" from:vc];
                return;
            }
            [[CBStreamManager shared] startIfNeeded];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"停用" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
            [weakSelf panelDidDismiss];
            [CBSettings shared].enabled = NO;
            [[CBSettings shared] save];
            [[CBStreamManager shared] stop];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"刷新直播源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            [weakSelf panelDidDismiss];
            [[CBStreamManager shared] restart];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"画面设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            [weakSelf panelDidDismiss];
            [weakSelf showVideoSettingsFrom:vc];
        }]];

        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x){
            [weakSelf panelDidDismiss];
        }]];

        self.presenting = YES;
        self.currentAlert = a;
        NSLog(@"[CBV2] control panel show");
        [vc presentViewController:a animated:YES completion:nil];
    });
}

#pragma mark - Video settings sub-panel (Fill/Fit/Stretch + Mirror + Rotation)

- (void)showVideoSettingsFrom:(UIViewController *)vc {
    if (self.presenting || self.currentAlert) return;
    CBSettings *s = [CBSettings shared];
    NSString *aspect = s.aspectMode == 0 ? @"Fill" : (s.aspectMode == 1 ? @"Fit" : @"Stretch");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"画面设置"
                                                               message:[NSString stringWithFormat:@"镜像: %@\n旋转: %ld°\n比例: %@",
                                                                        s.mirror ? @"开" : @"关",
                                                                        (long)s.rotation,
                                                                        aspect]
                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    __weak __typeof__(self) weakSelf = self;
    void (^cycle)(void) = ^{
        [weakSelf panelDidDismiss];
        [weakSelf showVideoSettingsFrom:vc];
    };

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
    [a addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x){
        [weakSelf panelDidDismiss];
    }]];

    if (a.popoverPresentationController) {
        a.popoverPresentationController.sourceView = vc.view;
        a.popoverPresentationController.sourceRect = vc.view.bounds;
        a.popoverPresentationController.permittedArrowDirections = 0;
    }
    self.presenting = YES;
    self.currentAlert = a;
    [vc presentViewController:a animated:YES completion:nil];
}

@end
