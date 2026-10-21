/*
 * QQForegroundPush v3.1 — 全链路诊断版
 * Built with macOS Apple clang → PAC stubs for arm64e
 *
 * 振动含义:
 *   %ctor 执行        = 连震 5 下（插件成功注入并加载）
 *   setDelegate:      = 震 2 下（QQ 设置了系统通知代理）
 *   willPresent       = 震 3 下（有前台推送到达 → 强制横幅）
 *   registerForRemote = 震 4 下（QQ 在注册 APNs 推送）
 * 同时写日志到 QQ 沙盒 Documents/qqfp.log
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
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = [paths count] ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        NSString *path = [docDir stringByAppendingPathComponent:@"qqfp.log"];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

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

%hook UNUserNotificationCenter

- (void)setDelegate:(id)delegate {
    if (delegate) {
        qqfpBuzz(2);
        qqfpLog(@"setDelegate called");
        Class cls = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP imp = method_getImplementation(m);
            if (imp != (IMP)qqp_forceWillPresent) {
                if (!qqp_origWillPresent) qqp_origWillPresent = imp;
                method_setImplementation(m, (IMP)qqp_forceWillPresent);
                qqfpLog(@"swizzled willPresent (existed)");
            }
        } else {
            class_addMethod(cls, sel, (IMP)qqp_forceWillPresent, "v@:@@@");
            qqfpLog(@"added willPresent (new)");
        }
    }
    %orig;
}

@end

%hook UIApplication

- (void)registerForRemoteNotifications {
    qqfpBuzz(4);
    qqfpLog(@"registerForRemoteNotifications called");
    %orig;
}

- (void)registerForRemoteNotificationsWithTypes:(NSUInteger)types {
    qqfpBuzz(4);
    qqfpLog(@"registerForRemoteNotificationsWithTypes called");
    %orig;
}

@end

%ctor {
    qqfpBuzz(5);
    qqfpLog(@"=== QQForePush v3.1 ctor ran ===");
    %init;
}