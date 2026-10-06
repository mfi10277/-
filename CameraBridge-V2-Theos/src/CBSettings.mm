#import "CBSettings.h"

static NSString * const kCBURL = @"CBV2.StreamURL";
static NSString * const kCBEnabled = @"CBV2.Enabled";
static NSString * const kCBMirror = @"CBV2.Mirror";
static NSString * const kCBRotation = @"CBV2.Rotation";
static NSString * const kCBAspect = @"CBV2.AspectMode";
static NSString * const kCBAutoStart = @"CBV2.AutoStart";

@implementation CBSettings
+ (instancetype)shared {
    static CBSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [CBSettings new]; [s load]; });
    return s;
}
- (void)load {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    _streamURL = [d stringForKey:kCBURL] ?: @"";
    _enabled = [d objectForKey:kCBEnabled] ? [d boolForKey:kCBEnabled] : YES;
    _mirror = [d boolForKey:kCBMirror];
    _rotation = [d integerForKey:kCBRotation];
    _aspectMode = [d integerForKey:kCBAspect];
    _autoStart = [d objectForKey:kCBAutoStart] ? [d boolForKey:kCBAutoStart] : YES;
    NSLog(@"[CBV2] settings loaded");
}
- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:self.streamURL ?: @"" forKey:kCBURL];
    [d setBool:self.enabled forKey:kCBEnabled];
    [d setBool:self.mirror forKey:kCBMirror];
    [d setInteger:self.rotation forKey:kCBRotation];
    [d setInteger:self.aspectMode forKey:kCBAspect];
    [d setBool:self.autoStart forKey:kCBAutoStart];
    [d synchronize];
    NSLog(@"[CBV2] settings saved");
    NSLog(@"[CBV2] enabled = %@", self.enabled ? @"YES" : @"NO");
}
@end
