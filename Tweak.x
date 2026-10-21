#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

/*
 * QQForegroundPush — Force QQ to show push notifications in foreground like WeChat.
 * Built with macOS Apple clang → generates PAC stubs for arm64e.
 */

static IMP qqp_origIMP = NULL;

static void qqp_hookIMP(id self, SEL _cmd,
    UNUserNotificationCenter *center,
    UNNotification *notification,
    void(^completion)(NSUInteger)) {

    UNNotificationPresentationOptions forceOpts =
        UNNotificationPresentationOptionBanner |
        UNNotificationPresentationOptionList |
        UNNotificationPresentationOptionSound;

    __block BOOL called = NO;
    void(^wrapped)(NSUInteger) = ^(NSUInteger opts) {
        if (!called) { called = YES; if (completion) completion(forceOpts); }
    };

    if (qqp_origIMP) {
        ((void(*)(id,SEL,id,id,void(^)(NSUInteger)))qqp_origIMP)(
            self, _cmd, center, notification, wrapped);
        if (!called && completion) { called = YES; completion(forceOpts); }
    } else {
        if (completion) completion(forceOpts);
    }
}

%hook UNUserNotificationCenter

- (void)setDelegate:(id)delegate {
    if (delegate) {
        Class cls = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            if (!qqp_origIMP) {
                qqp_origIMP = method_getImplementation(m);
            }
            method_setImplementation(m, (IMP)qqp_hookIMP);
        } else {
            class_addMethod(cls, sel, (IMP)qqp_hookIMP, "v@:@@@");
        }
    }
    %orig;
}

%end

%ctor {
    %init;
}
