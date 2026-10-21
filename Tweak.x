/*
 * QQForegroundPush v4.2 — 纯 dylib 版
 *
 * v4.1 有震8/9（授权+设delegate成功）但没横幅。
 * v4.2 新增：
 * A. Hook NSNotificationCenter postNotificationName: — 检测 QQ 内部消息通知
 * B. Hook UITableView insertRowsAtIndexPaths: — 检测消息列表更新
 * C. Hook setBadgeCount: (iOS16+)
 * D. 授权后直接发本地通知测试
 *
 * 振动：
 *   5=ctor 6=badge 7=发通知 3=willPresent 8=授权 9=设delegate
 *  10=NC内部通知 11=TableView插入 12=setBadgeCount
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

#pragma mark - willPresent

static IMP qqp_origWillPresent = NULL;

static void qqp_forceWillPresent(id self, SEL _cmd,
    UNUserNotificationCenter *center,
    UNNotification *notification,
    void(^completion)(NSUInteger)) {
    qqfpBuzz(3);
    qqfpLog(@"willPresent — forcing banner");
    if (completion) {
        completion(UNNotificationPresentationOptionBanner |
                   UNNotificationPresentationOptionList |
                   UNNotificationPresentationOptionSound);
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
        }
    } else {
        class_addMethod(cls, sel, (IMP)qqp_forceWillPresent, "v@:@@@");
    }
}

#pragma mark - Post local notification

static void qqp_postLocalNotification(NSString *body) {
    qqfpBuzz(7);
    qqfpLog([NSString stringWithFormat:@"posting: %@", body]);

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"QQ";
    content.body = body ?: @"新消息";
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
            if (error) qqfpLog([NSString stringWithFormat:@"error: %@", error]);
            else qqfpLog(@"local notification posted OK");
        });
}

#pragma mark - Force setup

static void qqp_forceSetup(void) {
    Class uncc = objc_getClass("UNUserNotificationCenter");
    if (!uncc) return;
    id center = qqfp_msgSend((id)uncc, @selector(currentNotificationCenter));
    if (!center) return;

    qqfpBuzz(8);
    void(*reqAuth)(id,SEL,NSUInteger,void(^)(BOOL,NSError*)) =
        (void(*)(id,SEL,NSUInteger,void(^)(BOOL,NSError*)))objc_msgSend;
    reqAuth(center,
        @selector(requestAuthorizationWithOptions:completionHandler:),
        UNAuthorizationOptionBadge | UNAuthorizationOptionSound | UNAuthorizationOptionAlert,
        ^(BOOL granted, NSError *error) {
            qqfpLog([NSString stringWithFormat:@"auth granted=%d", granted]);
        });

    qqfpBuzz(9);
    id existing = qqfp_msgSend(center, @selector(delegate));
    if (existing) {
        qqp_swizzleDelegate(existing);
    } else {
        Class dc = objc_allocateClassPair([NSObject class], "QQFPDelegate", 0);
        if (dc) {
            class_addMethod(dc,
                @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:),
                (IMP)qqp_forceWillPresent, "v@:@@@");
            objc_registerClassPair(dc);
            id dg = [[dc alloc] init];
            qqfp_msgSend(center, @selector(setDelegate:), dg);
        }
    }
}

#pragma mark - Badge

static NSInteger qqp_lastBadge = 0;

%hook UIApplication
- (void)setApplicationIconBadgeNumber:(NSInteger)badgeNumber {
    if (badgeNumber > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqfpBuzz(6);
        qqp_postLocalNotification([NSString stringWithFormat:@"%ld 条新消息", (long)(badgeNumber - qqp_lastBadge)]);
    }
    qqp_lastBadge = badgeNumber;
    %orig;
}
%end

%hook UNUserNotificationCenter
- (void)setDelegate:(id)delegate {
    qqp_swizzleDelegate(delegate);
    %orig;
}
- (void)setBadgeCount:(NSInteger)count withCompletionHandler:(void(^)(NSError *))handler {
    if (count > qqp_lastBadge && qqp_lastBadge >= 0) {
        qqfpBuzz(12);
        qqp_postLocalNotification([NSString stringWithFormat:@"%ld 条新消息", (long)(count - qqp_lastBadge)]);
    }
    qqp_lastBadge = count;
    %orig;
}
- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void(^)(NSError *))handler {
    id dg = qqfp_msgSend(self, @selector(delegate));
    if (dg) qqp_swizzleDelegate(dg);
    %orig;
}
%end

#pragma mark - Hook NSNotificationCenter

%hook NSNotificationCenter
- (void)postNotificationName:(NSString *)name object:(id)object userInfo:(NSDictionary *)userInfo {
    NSString *nl = [name lowercaseString];
    if ([nl containsString:@"message"] || [nl containsString:@"unread"] ||
        [nl containsString:@"newmsg"] || [nl containsString:@"msg"] ||
        [nl containsString:@"chat"] || [nl containsString:@"conv"]) {
        qqfpBuzz(10);
        qqfpLog([NSString stringWithFormat:@"NC: %@ userInfo: %@", name, userInfo]);
        qqp_postLocalNotification([NSString stringWithFormat:@"QQ: %@", name]);
    }
    %orig;
}
%end

#pragma mark - Hook UITableView

%hook UITableView
- (void)insertRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if ([indexPaths count] > 0) {
        qqfpBuzz(11);
        id ds = qqfp_msgSend(self, @selector(dataSource));
        if (ds) {
            NSString *dsc = NSStringFromClass([ds class]);
            if ([dsc containsString:@"Message"] || [dsc containsString:@"Chat"] ||
                [dsc containsString:@"Conv"] || [dsc containsString:@"Recent"]) {
                qqp_postLocalNotification(@"收到新消息");
            }
        }
    }
    %orig;
}
%end

%ctor {
    qqfpBuzz(5);
    qqfpLog(@"=== QQForePush v4.2 ctor ===");
    %init;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        qqp_forceSetup();
    });
}
