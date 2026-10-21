/*
 * QQForegroundPush v4.7 — 实时推送，无限流
 *
 * v4.6 有延迟甚至丢失，因为限流丢弃了消息。
 * v4.7 去掉时间限流，改为：
 * - 横幅正在显示 → 更新内容+重置3秒倒计时
 * - 横幅不在显示 → 新建横幅
 * 这样既实时又不会堆叠多个横幅
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
        usleep(100000);
    }
}

static void qqfpLog(NSString *msg) {
    NSLog(@"QQFP: %@", msg);
}

#pragma mark - Banner (real-time, no throttle)

static UIView *qqp_currentBanner = nil;
static UILabel *qqp_bodyLabel = nil;
static int qqp_unreadCount = 0;
static dispatch_block_t qqp_dismissBlock = nil;

static void qqp_dismissBanner() {
    if (!qqp_currentBanner) return;
    UIView *banner = qqp_currentBanner;
    qqp_currentBanner = nil;
    qqp_bodyLabel = nil;
    qqp_dismissBlock = nil;

    CGFloat width = [UIScreen mainScreen].bounds.size.width;
    CGFloat h = banner.frame.size.height;
    [UIView animateWithDuration:0.25 animations:^{
        banner.frame = CGRectMake(0, -h, width, h);
    } completion:^(BOOL finished) {
        [banner removeFromSuperview];
    }];
}

static void qqp_showBanner(NSString *body) {
    dispatch_async(dispatch_get_main_queue(), ^{

        // If banner visible → update content + reset timer
        if (qqp_currentBanner && qqp_bodyLabel) {
            qqp_unreadCount++;
            qqp_bodyLabel.text = [NSString stringWithFormat:@"%d 条新消息", qqp_unreadCount];
            // Reset dismiss timer
            if (qqp_dismissBlock) {
                dispatch_block_cancel(qqp_dismissBlock);
            }
            qqp_dismissBlock = dispatch_block_create(0, ^{
                qqp_dismissBanner();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), qqp_dismissBlock);
            return;
        }

        // Create new banner
        qqp_unreadCount = 1;

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
        titleLabel.text = @"QQ";
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
        qqp_currentBanner = banner;
        qqp_bodyLabel = bodyLabel;

        [UIView animateWithDuration:0.25 animations:^{
            banner.frame = CGRectMake(0, 0, width, bannerHeight + topInset);
        }];

        qqp_dismissBlock = dispatch_block_create(0, ^{
            qqp_dismissBanner();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), qqp_dismissBlock);
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
                      @"feed", @"timeline", @"notify", @"unread",
                      @"cell", @"data", @"list", @"panel", @"node",
                      @"reader", @"content", @"main", @"base"];
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
        if (ds && qqp_isChatRelated(NSStringFromClass([ds class]))) {
            qqp_showBanner(@"收到新消息");
        }
    }
    %orig;
}

- (void)reloadRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if ([indexPaths count] > 0) {
        id ds = [self dataSource];
        if (ds && qqp_isChatRelated(NSStringFromClass([ds class]))) {
            qqp_showBanner(@"收到新消息");
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
        if (ds && qqp_isChatRelated(NSStringFromClass([ds class]))) {
            qqp_showBanner(@"收到新消息");
        }
    }
    %orig;
}

- (void)reloadItemsAtIndexPaths:(NSArray *)indexPaths {
    if ([indexPaths count] > 0) {
        id ds = [self dataSource];
        if (ds && qqp_isChatRelated(NSStringFromClass([ds class]))) {
            qqp_showBanner(@"收到新消息");
        }
    }
    %orig;
}

%end

#pragma mark - Badge

static NSInteger qqp_lastBadge = 0;

%hook UIApplication
- (void)setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqp_showBanner([NSString stringWithFormat:@"%ld 条新消息", (long)(badgeNumber - qqp_lastBadge)]);
    }
    qqp_lastBadge = badgeNumber;
    %orig;
}
%end

%hook UNUserNotificationCenter
- (void)setBadgeCount:(NSInteger)count withCompletionHandler:(void(^)(NSError *))handler {
    if (count > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqp_showBanner([NSString stringWithFormat:@"%ld 条新消息", (long)(count - qqp_lastBadge)]);
    }
    qqp_lastBadge = count;
    %orig;
}
%end

%ctor {
    qqfpBuzz(2);
    qqfpLog(@"=== QQForePush v4.7 ===");
    %init;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        qqp_showBanner(@"前台推送测试 — 看到这条说明横幅正常");
    });
}
