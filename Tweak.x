/*
 * QQForegroundPush v4.4 — 自定义横幅（不依赖系统通知）
 *
 * v4.3 发现：发本地通知后 willPresent 不被调用 → delegate 无效
 * QQ 可能覆盖了我们的 delegate，或通知授权未生效。
 *
 * v4.4 策略：完全绕过 UNUserNotificationCenter，
 * 检测到新消息时直接用 UIKit 在屏幕顶部画一个横幅，
 * 3秒后自动消失。跟微信横幅一样的效果。
 *
 * 振动精简：只在检测到新消息时震1下
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>

__attribute__((unused)) static id (*qqfp_msgSend)(id, SEL, ...) = (id(*)(id, SEL, ...))objc_msgSend;

static void qqfpBuzz(int n) {
    for (int i = 0; i < n; i++) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        usleep(150000);
    }
}

static void qqfpLog(NSString *msg) {
    NSLog(@"QQFP: %@", msg);
}

#pragma mark - Custom Banner View

static void qqp_showBanner(NSString *title, NSString *body) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
            }
        }
        if (!keyWindow) {
            // fallback
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        if (!keyWindow) return;

        CGFloat width = [UIScreen mainScreen].bounds.size.width;
        CGFloat bannerHeight = 80;
        CGFloat topInset = 0;
        if (@available(iOS 13.0, *)) {
            topInset = keyWindow.safeAreaInsets.top;
        }

        // Container view
        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, -bannerHeight, width, bannerHeight + topInset)];
        banner.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.92];
        banner.layer.cornerRadius = 0;
        banner.clipsToBounds = YES;
        banner.tag = 9527;

        // Remove existing banner
        UIView *old = [keyWindow viewWithTag:9527];
        if (old) [old removeFromSuperview];

        // App icon label
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = title ?: @"QQ";
        titleLabel.font = [UIFont boldSystemFontOfSize:15];
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.textAlignment = NSTextAlignmentLeft;

        UILabel *bodyLabel = [[UILabel alloc] init];
        bodyLabel.text = body ?: @"新消息";
        bodyLabel.font = [UIFont systemFontOfSize:14];
        bodyLabel.textColor = [UIColor colorWithRed:0.8 green:0.8 blue:0.8 alpha:1.0];
        bodyLabel.numberOfLines = 2;
        bodyLabel.textAlignment = NSTextAlignmentLeft;

        UIView *contentView = [[UIView alloc] initWithFrame:CGRectMake(16, topInset, width - 32, bannerHeight)];
        [banner addSubview:contentView];

        // Icon (blue circle with "Q")
        UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(0, 15, 44, 44)];
        iconBg.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        iconBg.layer.cornerRadius = 22;
        iconBg.layer.masksToBounds = YES;
        UILabel *iconLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        iconLabel.text = @"QQ";
        iconLabel.font = [UIFont boldSystemFontOfSize:16];
        iconLabel.textColor = [UIColor whiteColor];
        iconLabel.textAlignment = NSTextAlignmentCenter;
        [iconBg addSubview:iconLabel];
        [contentView addSubview:iconBg];

        titleLabel.frame = CGRectMake(54, 12, width - 86, 20);
        bodyLabel.frame = CGRectMake(54, 34, width - 86, 36);
        [contentView addSubview:titleLabel];
        [contentView addSubview:bodyLabel];

        [keyWindow addSubview:banner];

        // Slide down animation
        [UIView animateWithDuration:0.35 delay:0
            options:UIViewAnimationOptionCurveEaseOut
            animations:^{
            banner.frame = CGRectMake(0, 0, width, bannerHeight + topInset);
        } completion:nil];

        // Auto dismiss after 3 seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.35 delay:0
                options:UIViewAnimationOptionCurveEaseIn
                animations:^{
                banner.frame = CGRectMake(0, -bannerHeight - topInset, width, bannerHeight + topInset);
            } completion:^(BOOL finished) {
                [banner removeFromSuperview];
            }];
        });
    });
}

#pragma mark - Badge detection with throttle

static NSInteger qqp_lastBadge = 0;
static NSTimeInterval qqp_lastNotifyTime = 0;

%hook UIApplication
- (void)setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber > qqp_lastBadge && qqp_lastBadge >= 0) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - qqp_lastNotifyTime > 2.0) {
            qqp_lastNotifyTime = now;
            NSInteger diff = badgeNumber - qqp_lastBadge;
            qqfpBuzz(1);
            qqfpLog([NSString stringWithFormat:@"badge: %ld -> %ld", (long)qqp_lastBadge, (long)badgeNumber]);
            qqp_showBanner(@"QQ", [NSString stringWithFormat:@"%ld 条新消息", (long)diff]);
        }
    }
    qqp_lastBadge = badgeNumber;
    %orig;
}
%end

%hook UNUserNotificationCenter
- (void)setBadgeCount:(NSInteger)count withCompletionHandler:(void(^)(NSError *))handler {
    if (count > qqp_lastBadge && qqp_lastBadge >= 0) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - qqp_lastNotifyTime > 2.0) {
            qqp_lastNotifyTime = now;
            NSInteger diff = count - qqp_lastBadge;
            qqfpBuzz(1);
            qqfpLog([NSString stringWithFormat:@"setBadgeCount: %ld -> %ld", (long)qqp_lastBadge, (long)count]);
            qqp_showBanner(@"QQ", [NSString stringWithFormat:@"%ld 条新消息", (long)diff]);
        }
    }
    qqp_lastBadge = count;
    %orig;
}
%end

%ctor {
    qqfpBuzz(2);
    qqfpLog(@"=== QQForePush v4.4 ctor ===");

    // 启动5秒后自动弹一条测试横幅
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        qqfpBuzz(1);
        qqp_showBanner(@"QQ", @"前台推送测试 — 看到这条说明横幅正常");
    });

    %init;
}
