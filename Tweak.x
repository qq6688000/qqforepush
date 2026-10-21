/*
 * QQForegroundPush v4.0 — 主动发本地通知 + 前台横幅强制
 * 
 * 之前的版本只 hook setDelegate:，但 QQ 从不调用它（QQ 走自己的长连接，
 * 不通过系统 UNUserNotificationCenter）。
 * 
 * v4.0 策略：
 * 1. 定时器轮询 UNUserNotificationCenter 的 delegate，主动 swizzle（不等 setDelegate:）
 * 2. Hook UIApplication setApplicationIconBadgeNumber: — QQ 收到新消息时会更新 badge
 * 3. Badge 增加时，主动发一条本地通知 UNNotificationRequest
 * 4. Hook UNUserNotificationCenter addNotificationRequest: — 确保前台显示横幅
 * 5. Hook delegate 的 willPresentNotification: — 强制返回 Banner|Sound
 * 
 * 振动诊断:
 *   5下 = ctor（插件加载）
 *   2下 = setDelegate 被调用
 *   3下 = willPresent 被触发
 *   4下 = registerForRemoteNotifications
 *   6下 = badge 增加（检测到新消息）
 *   7下 = 正在发送本地通知
 */

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>

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
    qqfpLog(@"willPresent called — forcing banner");

    UNNotificationPresentationOptions forceOpts =
        UNNotificationPresentationOptionBanner |
        UNNotificationPresentationOptionList |
        UNNotificationPresentationOptionSound;

    if (completion) {
        completion(forceOpts);
    }
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

#pragma mark - Proactive delegate swizzle via timer

static void qqp_checkAndSwizzleDelegate(void) {
    Class uncc = objc_getClass("UNUserNotificationCenter");
    if (!uncc) return;
    
    SEL currentSel = @selector(currentNotificationCenter);
    Method cm = class_getClassMethod(uncc, currentSel);
    if (!cm) return;
    
    IMP curIMP = method_getImplementation(cm);
    id center = ((id(*)(id,SEL))curIMP)((id)uncc, currentSel);
    if (!center) return;
    
    // Get delegate via ivar (no objc_msgSend)
    Class cls = object_getClass(center);
    unsigned int cnt;
    Ivar *ivs = class_copyIvarList(cls, &cnt);
    for (unsigned int i = 0; i < cnt; i++) {
        const char *nm = ivar_getName(ivs[i]);
        if (nm && (strstr(nm, "delegate") || strstr(nm, "Delegate"))) {
            id dg = object_getIvar(center, ivs[i]);
            if (dg) {
                qqfpLog(@"found delegate via ivar, swizzling");
                qqp_swizzleDelegate(dg);
                free(ivs);
                return;
            }
        }
    }
    free(ivs);
    
    // Try getting delegate via objc property (uses objc_msgSend but macOS clang has PAC stubs)
    SEL delSel = @selector(delegate);
    if (class_getInstanceMethod(cls, delSel)) {
        id dg = ((id(*)(id,SEL))objc_msgSend)(center, delSel);
        if (dg) {
            qqfpLog(@"found delegate via property, swizzling");
            qqp_swizzleDelegate(dg);
        }
    }
}

static dispatch_source_t qqp_timer = NULL;

static void qqp_startTimer(void) {
    if (qqp_timer) return;
    
    qqp_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(qqp_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 0);
    
    __block int tick = 0;
    dispatch_source_set_event_handler(qqp_timer, ^{
        tick++;
        qqp_checkAndSwizzleDelegate();
        if (tick >= 15) { // 30 seconds
            dispatch_cancel(qqp_timer);
            qqp_timer = NULL;
        }
    });
    
    dispatch_resume(qqp_timer);
    qqfpLog(@"timer started to poll delegate");
}

#pragma mark - Badge detection → post local notification

static NSInteger qqp_lastBadge = 0;

%hook UIApplication

- (void)setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqfpBuzz(6);
        qqfpLog([NSString stringWithFormat:@"badge increased: %ld -> %ld", (long)qqp_lastBadge, (long)badgeNumber]);
        
        // Post a local notification
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = @"QQ";
        content.body = [NSString stringWithFormat:@"%ld 条新消息", (long)(badgeNumber - qqp_lastBadge)];
        content.sound = [UNNotificationSound defaultSound];
        
        UNNotificationRequest *req = [UNNotificationRequest
            requestWithIdentifier:[NSString stringWithFormat:@"qqfp_%f", [[NSDate date] timeIntervalSince1970]]
            content:content
            trigger:nil];
        
        qqfpBuzz(7);
        
        Class uncc = objc_getClass("UNUserNotificationCenter");
        if (uncc) {
            id center = ((id(*)(id,SEL))objc_msgSend)((id)uncc, @selector(currentNotificationCenter));
            if (center) {
                ((void(*)(id,SEL,id,void(^)(NSError*)))objc_msgSend)(center,
                    @selector(addNotificationRequest:withCompletionHandler:),
                    req,
                    ^(NSError *error) {
                        if (error) {
                            qqfpLog([NSString stringWithFormat:@"addNotification error: %@", error]);
                        } else {
                            qqfpLog(@"local notification posted");
                        }
                    });
            }
        }
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

#pragma mark - UNUserNotificationCenter hooks

%hook UNUserNotificationCenter

- (void)setDelegate:(id)delegate {
    qqfpBuzz(2);
    qqfpLog(@"setDelegate called");
    qqp_swizzleDelegate(delegate);
    %orig;
}

- (id)delegate {
    id dg = %orig;
    if (dg) {
        qqp_swizzleDelegate(dg);
    }
    return dg;
}

- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void(^)(NSError *))handler {
    qqfpBuzz(7);
    qqfpLog([NSString stringWithFormat:@"addNotificationRequest: %@", request.identifier]);
    
    // Ensure delegate is swizzled before notification is added
    qqp_checkAndSwizzleDelegate();
    
    %orig;
}

%end

%ctor {
    qqfpBuzz(5);
    qqfpLog(@"=== QQForePush v4.0 ctor ===");
    %init;
    
    // Proactively check and swizzle delegate
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        qqp_checkAndSwizzleDelegate();
        qqp_startTimer();
    });
}
