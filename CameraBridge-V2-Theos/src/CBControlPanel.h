#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface CBControlPanel : NSObject
+ (instancetype)shared;

/// Guard: prevents more than one CameraBridge panel from being presented at a time.
@property(nonatomic, assign) BOOL presenting;
/// The alert currently presented (weak, used as an additional guard).
@property(nonatomic, weak) UIAlertController *currentAlert;

- (void)show;
@end
