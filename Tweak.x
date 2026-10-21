/*
 * QQForegroundPush v4.5 — 精准检测聊天列表更新
 *
 * v4.4 测试横幅能弹，但 badge 不变（QQ 前台不更新 badge）。
 * v4.5 用 UITableView insertRows 检测，但加严格过滤：
 * - dataSource 类名必须包含 Chat/Message/Conv/Session/Recent/Bubble
 * - 8秒限流
 * - 只弹横幅，不振动不通知
 *
 * 振动：2=ctor 1=测试横幅 4=检测到聊天插入
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

#pragma mark - Custom Banner

static NSTimeInterval qqp_lastBannerTime = 0;

static void qqp_showBanner(NSString *title, NSString *body) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - qqp_lastBannerTime < 5.0) return; // 5秒限流
    qqp_lastBannerTime = now;

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
        if (topInset < 20) topInset = 20;

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

        [UIView animateWithDuration:0.35 animations:^{
            banner.frame = CGRectMake(0, 0, width, bannerHeight + topInset);
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.35 animations:^{
                banner.frame = CGRectMake(0, -bannerHeight - topInset, width, bannerHeight + topInset);
            } completion:^(BOOL finished) {
                [banner removeFromSuperview];
            }];
        });
    });
}

#pragma mark - Check if class is chat-related

static BOOL qqp_isChatRelated(NSString *className) {
    NSString *lower = [className lowercaseString];
    NSArray *keywords = @[@"chat", @"message", @"conv", @"session", @"recent", @"bubble", @"msg", @"talk"];
    for (NSString *kw in keywords) {
        if ([lower containsString:kw]) return YES;
    }
    return NO;
}

#pragma mark - Hook UITableView (filtered + throttled)

%hook UITableView

- (void)insertRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if ([indexPaths count] > 0) {
        id ds = [self dataSource];
        if (ds) {
            NSString *cn = NSStringFromClass([ds class]);
            if (qqp_isChatRelated(cn)) {
                qqfpBuzz(4);
                qqfpLog([NSString stringWithFormat:@"insertRows on %@ (%lu rows)", cn, (unsigned long)[indexPaths count]]);
                qqp_showBanner(@"QQ", @"收到新消息");
            }
        }
    }
    %orig;
}

- (void)reloadData {
    // Log chat-related tableView reloads (no banner, just log)
    id ds = [self dataSource];
    if (ds) {
        NSString *cn = NSStringFromClass([ds class]);
        if (qqp_isChatRelated(cn)) {
            static NSTimeInterval lastLog = 0;
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - lastLog > 10.0) {
                lastLog = now;
                qqfpLog([NSString stringWithFormat:@"reloadData on %@", cn]);
            }
        }
    }
    %orig;
}

%end

#pragma mark - Badge (still hooked as fallback)

static NSInteger qqp_lastBadge = 0;

%hook UIApplication
- (void)setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber > qqp_lastBadge && qqp_lastBadge >= 0) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - qqp_lastBannerTime > 5.0) {
            qqp_showBanner(@"QQ", [NSString stringWithFormat:@"%ld 条新消息", (long)(badgeNumber - qqp_lastBadge)]);
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
        if (now - qqp_lastBannerTime > 5.0) {
            qqp_showBanner(@"QQ", [NSString stringWithFormat:@"%ld 条新消息", (long)(count - qqp_lastBadge)]);
        }
    }
    qqp_lastBadge = count;
    %orig;
}
%end

%ctor {
    qqfpBuzz(2);
    qqfpLog(@"=== QQForePush v4.5 ctor ===");
    %init;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        qqfpBuzz(1);
        qqp_showBanner(@"QQ", @"前台推送测试 — 看到这条说明横幅正常");
    });
}
