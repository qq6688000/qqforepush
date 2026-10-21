/*
 * QQForegroundPush v4.1 — 主动授权 + 主动设 delegate + setBadgeCount hook
 *
 * v4.0 发现 QQ 不调用 setApplicationIconBadgeNumber:，
 * 可能用 iOS16+ 的 UNUserNotificationCenter setBadgeCount:withCompletionHandler:
 * 也可能 QQ 从未请求通知授权、从未设 delegate。
 *
 * v4.1 新增：
 * A. %ctor 里主动请求通知授权（不等 QQ 调 requestAuthorization）
 * B. %ctor 里主动设 UNUserNotificationCenter delegate（不等 QQ 调 setDelegate）
 * C. Hook setBadgeCount:withCompletionHandler: (iOS16+)
 * D. Hook requestAuthorizationWithOptions: — 诊断 QQ 是否自己请求过
 *
 * 振动诊断:
 *   5下 = ctor
 *   2下 = setDelegate 被调用
 *   3下 = willPresent 被触发
 *   4下 = registerForRemoteNotifications
 *   6下 = badge/setBadgeCount 增加
 *   7下 = 正在发送本地通知
 *   8下 = 主动请求授权
 *   9下 = 主动设置 delegate
 */

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>

static id (*qqfp_msgSend)(id, SEL, ...) = (id(*)(id, SEL, ...))objc_msgSend;

static void qqfpBuzz(int n) {
    for (int i = 0; i < n; i++) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        usleep(200000);
    }
}

static void qqfpLog(NSString *msg) {
    NSLog(@"QQFP: %@", msg);
}

#pragma mark - willPresent swizzle

static IMP qqp_origWillPresent = NULL;

static void qqp_forceWillPresent(id self, SEL _cmd,
    UNUserNotificationCenter *center,
    UNNotification *notification,
    void(^completion)(NSUInteger)) {
    qqfpBuzz(3);
    qqfpLog(@"willPresent — forcing banner");
    UNNotificationPresentationOptions forceOpts =
        UNNotificationPresentationOptionBanner |
        UNNotificationPresentationOptionList |
        UNNotificationPresentationOptionSound;
    if (completion) completion(forceOpts);
}

static void qqp_swizzleDelegate(id delegate) {
    if (!delegate) return;
    Class cls = [delegate class];
    SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        IMP imp = method_getImplementation(m);
        if (imp != (IMP)qqp_forceWillPresent) {
            if (!qqp_origWillPresent) qqp_origWillPresent = imp;
            method_setImplementation(m, (IMP)qqp_forceWillPresent);
            qqfpLog(@"swizzled willPresent on delegate class");
        }
    } else {
        class_addMethod(cls, sel, (IMP)qqp_forceWillPresent, "v@:@@@");
        qqfpLog(@"added willPresent on delegate class");
    }
}

#pragma mark - Post local notification

static NSInteger qqp_lastBadge = 0;

static void qqp_postLocalNotification(NSInteger newCount) {
    qqfpBuzz(7);
    qqfpLog(@"posting local notification");

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"QQ";
    content.body = [NSString stringWithFormat:@"%ld 条新消息", (long)newCount];
    content.sound = [UNNotificationSound defaultSound];

    UNNotificationRequest *req = [UNNotificationRequest
        requestWithIdentifier:[NSString stringWithFormat:@"qqfp_%f", [[NSDate date] timeIntervalSince1970]]
        content:content trigger:nil];

    Class uncc = objc_getClass("UNUserNotificationCenter");
    if (!uncc) return;
    id center = qqfp_msgSend((id)uncc, @selector(currentNotificationCenter));
    if (!center) return;

    void(*addReq)(id,SEL,id,void(^)(NSError*)) = (void(*)(id,SEL,id,void(^)(NSError*)))objc_msgSend;
    addReq(center,
        @selector(addNotificationRequest:withCompletionHandler:),
        req,
        ^(NSError *error) {
            if (error) qqfpLog([NSString stringWithFormat:@"addNotification error: %@", error]);
            else qqfpLog(@"local notification posted successfully");
        });
}

#pragma mark - Force setup on launch

static void qqp_forceSetupNotifications(void) {
    Class uncc = objc_getClass("UNUserNotificationCenter");
    if (!uncc) return;

    id center = qqfp_msgSend((id)uncc, @selector(currentNotificationCenter));
    if (!center) return;

    // A. Force request authorization
    qqfpBuzz(8);
    qqfpLog(@"force requesting notification authorization");

    UNAuthorizationOptions opts =
        UNAuthorizationOptionBadge |
        UNAuthorizationOptionSound |
        UNAuthorizationOptionAlert;

    void(*reqAuth)(id,SEL,NSUInteger,void(^)(BOOL,NSError*)) =
        (void(*)(id,SEL,NSUInteger,void(^)(BOOL,NSError*)))objc_msgSend;
    reqAuth(center,
        @selector(requestAuthorizationWithOptions:completionHandler:),
        opts,
        ^(BOOL granted, NSError *error) {
            qqfpLog([NSString stringWithFormat:@"authorization granted=%d error=%@", granted, error]);
        });

    // B. Force set delegate — create a minimal delegate class
    qqfpBuzz(9);
    qqfpLog(@"force setting delegate");

    // Check if QQ already set a delegate
    id existing = qqfp_msgSend(center, @selector(delegate));
    if (existing) {
        qqfpLog(@"QQ already has a delegate, swizzling it");
        qqp_swizzleDelegate(existing);
    } else {
        // Create our own delegate
        Class delegateClass = objc_allocateClassPair([NSObject class], "QQFPDelegate", 0);
        if (delegateClass) {
            // Add willPresentNotification method
            class_addMethod(delegateClass,
                @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:),
                (IMP)qqp_forceWillPresent, "v@:@@@");
            objc_registerClassPair(delegateClass);
        } else {
            delegateClass = objc_getClass("QQFPDelegate");
        }

        if (delegateClass) {
            id dg = [[delegateClass alloc] init];
            qqfp_msgSend(center, @selector(setDelegate:), dg);
            qqfpLog(@"set our own delegate");
        }
    }
}

#pragma mark - Hooks

%hook UIApplication

- (void)setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqfpBuzz(6);
        qqfpLog([NSString stringWithFormat:@"badge increased: %ld -> %ld", (long)qqp_lastBadge, (long)badgeNumber]);
        qqp_postLocalNotification(badgeNumber - qqp_lastBadge);
    }
    qqp_lastBadge = badgeNumber;
    %orig;
}

- (void)registerForRemoteNotifications {
    qqfpBuzz(4);
    qqfpLog(@"registerForRemoteNotifications called");
    %orig;
}

%end

%hook UNUserNotificationCenter

- (void)setDelegate:(id)delegate {
    qqfpBuzz(2);
    qqfpLog(@"setDelegate called");
    qqp_swizzleDelegate(delegate);
    %orig;
}

- (id)delegate {
    id dg = %orig;
    if (dg) qqp_swizzleDelegate(dg);
    return dg;
}

- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void(^)(NSError *))handler {
    qqfpBuzz(7);
    qqfpLog([NSString stringWithFormat:@"addNotificationRequest: %@", request.identifier]);
    qqp_swizzleDelegate(qqfp_msgSend(self, @selector(delegate)));
    %orig;
}

- (void)setBadgeCount:(NSInteger)count withCompletionHandler:(void(^)(NSError *))handler {
    if (count > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqfpBuzz(6);
        qqfpLog([NSString stringWithFormat:@"setBadgeCount increased: %ld -> %ld", (long)qqp_lastBadge, (long)count]);
        qqp_postLocalNotification(count - qqp_lastBadge);
    }
    qqp_lastBadge = count;
    %orig;
}

- (void)requestAuthorizationWithOptions:(NSUInteger)options completionHandler:(void(^)(BOOL,NSError *))handler {
    qqfpBuzz(8);
    qqfpLog(@"QQ requesting notification authorization");
    %orig;
}

%end

%ctor {
    qqfpBuzz(5);
    qqfpLog(@"=== QQForePush v4.1 ctor ===");
    %init;

    // Force setup after 2 seconds (let QQ finish launching)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        qqp_forceSetupNotifications();
    });
}
