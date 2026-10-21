/*
 * QQForegroundPush v4.6 — UITableView + UICollectionView + 2秒限流
 *
 * v4.5 有横幅但延迟4-5秒甚至没有。
 * 原因：5秒限流太长 + QQ可能用UICollectionView
 *
 * v4.6: 同时hook两个View，限流减到2秒
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

#pragma mark - Banner

static NSTimeInterval qqp_lastBanner = 0;

static void qqp_showBanner(NSString *title, NSString *body) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - qqp_lastBanner < 2.0) return; // 2秒限流
    qqp_lastBanner = now;

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
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
        if (!keyWindow) return;

        CGFloat width = [UIScreen mainScreen].bounds.size.width;
        CGFloat bannerHeight = 80;
        CGFloat topInset = keyWindow.safeAreaInsets.top;
        if (topInset < 20) topInset = 44;

        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, -bannerHeight - topInset, width, bannerHeight + topInset)];
        banner.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.92];
        banner.tag = 9528;

        UIView *old = [keyWindow viewWithTag:9528];
        if (old) [old removeFromSuperview];

        UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(16, topInset + 15, 44, 44)];
        iconBg.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        iconBg.layer.cornerRadius = 22;
        iconBg.layer.masksToBounds = YES;
        UILabel *iconLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        iconLabel.text = @"QQ";
        iconLabel.font = [UIFont boldSystemFontOfSize:16];
        iconLabel.textColor = [UIColor whiteColor];
        iconLabel.textAlignment = NSTextAlignmentCenter;
        [iconBg addSubview:iconLabel];
        [banner addSubview:iconBg];

        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(70, topInset + 12, width - 86, 20)];
        titleLabel.text = title ?: @"QQ";
        titleLabel.font = [UIFont boldSystemFontOfSize:15];
        titleLabel.textColor = [UIColor whiteColor];
        [banner addSubview:titleLabel];

        UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(70, topInset + 34, width - 86, 36)];
        bodyLabel.text = body ?: @"新消息";
        bodyLabel.font = [UIFont systemFontOfSize:14];
        bodyLabel.textColor = [UIColor colorWithRed:0.8 green:0.8 blue:0.8 alpha:1.0];
        bodyLabel.numberOfLines = 2;
        [banner addSubview:bodyLabel];

        [keyWindow addSubview:banner];

        [UIView animateWithDuration:0.3 animations:^{
            banner.frame = CGRectMake(0, 0, width, bannerHeight + topInset);
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                banner.frame = CGRectMake(0, -bannerHeight - topInset, width, bannerHeight + topInset);
            } completion:^(BOOL finished) {
                [banner removeFromSuperview];
            }];
        });
    });
}

#pragma mark - Chat-related check

static BOOL qqp_isChatRelated(NSString *cn) {
    if (!cn || cn.length == 0) return NO;
    NSString *lower = [cn lowercaseString];
    static NSArray *keywords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keywords = @[@"chat", @"message", @"conv", @"session", @"recent",
                      @"bubble", @"msg", @"talk", @"c2c", @"group",
                      @"feed", @"timeline", @"notify", @"unread"];
    });
    for (NSString *kw in keywords) {
        if ([lower containsString:kw]) return YES;
    }
    return NO;
}

#pragma mark - UITableView

%hook UITableView

- (void)insertRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if ([indexPaths count] > 0) {
        id ds = [self dataSource];
        if (ds) {
            NSString *cn = NSStringFromClass([ds class]);
            if (qqp_isChatRelated(cn)) {
                qqfpBuzz(4);
                qqp_showBanner(@"QQ", @"收到新消息");
            }
        }
    }
    %orig;
}

- (void)reloadRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if ([indexPaths count] > 0) {
        id ds = [self dataSource];
        if (ds) {
            NSString *cn = NSStringFromClass([ds class]);
            if (qqp_isChatRelated(cn)) {
                qqfpBuzz(4);
                qqp_showBanner(@"QQ", @"收到新消息");
            }
        }
    }
    %orig;
}

%end

#pragma mark - UICollectionView

%hook UICollectionView

- (void)insertItemsAtIndexPaths:(NSArray *)indexPaths {
    if ([indexPaths count] > 0) {
        id ds = [self dataSource];
        if (ds) {
            NSString *cn = NSStringFromClass([ds class]);
            if (qqp_isChatRelated(cn)) {
                qqfpBuzz(4);
                qqp_showBanner(@"QQ", @"收到新消息");
            }
        }
    }
    %orig;
}

- (void)reloadItemsAtIndexPaths:(NSArray *)indexPaths {
    if ([indexPaths count] > 0) {
        id ds = [self dataSource];
        if (ds) {
            NSString *cn = NSStringFromClass([ds class]);
            if (qqp_isChatRelated(cn)) {
                qqfpBuzz(4);
                qqp_showBanner(@"QQ", @"收到新消息");
            }
        }
    }
    %orig;
}

%end

#pragma mark - Badge fallback

static NSInteger qqp_lastBadge = 0;

%hook UIApplication
- (void)setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqp_showBanner(@"QQ", [NSString stringWithFormat:@"%ld 条新消息", (long)(badgeNumber - qqp_lastBadge)]);
    }
    qqp_lastBadge = badgeNumber;
    %orig;
}
%end

%hook UNUserNotificationCenter
- (void)setBadgeCount:(NSInteger)count withCompletionHandler:(void(^)(NSError *))handler {
    if (count > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqp_showBanner(@"QQ", [NSString stringWithFormat:@"%ld 条新消息", (long)(count - qqp_lastBadge)]);
    }
    qqp_lastBadge = count;
    %orig;
}
%end

%ctor {
    qqfpBuzz(2);
    qqfpLog(@"=== QQForePush v4.6 ===");
    %init;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        qqfpBuzz(1);
        qqp_showBanner(@"QQ", @"前台推送测试 — 看到这条说明横幅正常");
    });
}
