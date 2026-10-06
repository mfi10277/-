#import <Foundation/Foundation.h>

@interface CBSettings : NSObject
+ (instancetype)shared;
@property(nonatomic, copy) NSString *streamURL;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL mirror;
@property(nonatomic) NSInteger rotation;
@property(nonatomic) NSInteger aspectMode; // 0=fill, 1=fit, 2=stretch
@property(nonatomic) BOOL autoStart;      // CBV2.AutoStart, default YES
- (void)load;
- (void)save;
@end
