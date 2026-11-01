// BarkAutoCopy.m
// Bark 推送验证码 → 剪贴板（注入 SpringBoard，覆盖锁屏/横幅/通知中心）
// v0.0.3 诊断版：全链路写文件 /var/mobile/Documents/barkautocopy_debug.txt

#import <substrate.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#define ACVLOG(fmt, ...) NSLog(@"[BarkAutoCopy] " fmt, ##__VA_ARGS__)

// ---------- 开关 ----------
static BOOL gBarkOnly = NO;                // 0.0.3 诊断版：对全部通知生效，先排除识别因素
static NSTimeInterval gDedupWindow = 10.0; // 相同验证码 X 秒内只写一次剪贴板

// ---------- 诊断文件（Filza 打开 /var/mobile/Documents/barkautocopy_debug.txt） ----------
static NSString *ACVDebugPath(void) {
    static NSString *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = @"/var/mobile/Documents/barkautocopy_debug.txt"; });
    return p;
}

static void ACVDebug(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [[NSDate date] description], msg];
    @synchronized ([NSObject class]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:ACVDebugPath()];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:ACVDebugPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    NSLog(@"[BarkAutoCopy] %@", msg);
}

// ---------- Bark 识别 ----------
static BOOL ACVIsBarkContent(UNNotificationContent *c) {
    if ([c.categoryIdentifier isEqualToString:@"myNotificationCategory"]) return YES;
    NSDictionary *ui = c.userInfo ?: @{};
    static NSSet *barkKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        barkKeys = [NSSet setWithArray:@[
            @"url", @"copy", @"autoCopy", @"isArchive", @"group", @"level",
            @"badge", @"id", @"device_key"
        ]];
    });
    for (NSString *k in ui) {
        if ([barkKeys containsObject:k]) return YES;
    }
    NSString *title = c.title ?: @"";
    return [title isEqualToString:@"Bark"];
}

// ---------- 验证码提取 ----------
static NSString *ACVExtractCode(NSString *text) {
    if (!text.length) return nil;
    NSError *err = nil;

    NSRegularExpression *kw = [NSRegularExpression regularExpressionWithPattern:
        @"(?:验证码|校验码|验证数字|动态码|动态密码|安全码|激活码|口令|code|otp|token)"
        @"[\\s\\S]{0,12}?(\\d{4,8})"
        options:NSRegularExpressionCaseInsensitive error:&err];
    NSTextCheckingResult *m = [kw firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (m && m.numberOfRanges > 1) {
        return [text substringWithRange:[m rangeAtIndex:1]];
    }

    NSString *trim = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *digits = [trim stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (digits.length >= 4 && digits.length <= 8) {
        NSRegularExpression *d = [NSRegularExpression regularExpressionWithPattern:@"^\\d+$" options:0 error:nil];
        if ([d firstMatchInString:digits options:0 range:NSMakeRange(0, digits.length)]) {
            return digits;
        }
    }
    return nil;
}

// ---------- 剪贴板写入（带去重 + 回读验证） ----------
static NSString *gLastCode = nil;
static NSTimeInterval gLastTs = 0;
static void ACVCopyCode(NSString *code) {
    if (!code.length) {
        ACVDebug(@"copy: 无码可复制");
        return;
    }
    @synchronized ([NSObject class]) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (gLastCode && [gLastCode isEqualToString:code] && (now - gLastTs) < gDedupWindow) {
            ACVDebug(@"copy: 去重跳过 %@", code);
            return;
        }
        gLastCode = code;
        gLastTs = now;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        ACVDebug(@"copy: 写入剪贴板 %@", code);
        [UIPasteboard generalPasteboard].string = code;
        ACVDebug(@"copy: 回读剪贴板 = %@", [UIPasteboard generalPasteboard].string);
    });
}

// ---------- 每条通知只处理一次 ----------
static NSMutableSet *ACVSeenSet(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static BOOL ACVAlreadyProcessed(NSString *ident) {
    if (!ident) ident = @"";
    NSMutableSet *s = ACVSeenSet();
    @synchronized (s) {
        if ([s containsObject:ident]) return YES;
        if (s.count > 100) [s removeAllObjects];
        [s addObject:ident];
    }
    return NO;
}

// ---------- 统一处理 ----------
static void ACVProcessNotificationRequest(id req, NSString *via) {
    @autoreleasepool {
        if (![req isKindOfClass:NSClassFromString(@"UNNotificationRequest")]) {
            ACVDebug(@"[%@] req 类型=%@（非 UNNotificationRequest）", via, NSStringFromClass([req class]));
            return;
        }
        UNNotificationRequest *r = (UNNotificationRequest *)req;
        UNNotificationContent *c = r.content;
        if (!c) {
            ACVDebug(@"[%@] content 为空", via);
            return;
        }
        if (ACVAlreadyProcessed(r.identifier)) return;
        ACVDebug(@"[%@] ident=%@ category=%@ title=%@ body=%@ userInfoKeys=%@",
                 via,
                 r.identifier ?: @"(nil)",
                 c.categoryIdentifier ?: @"(nil)",
                 c.title ?: @"(nil)",
                 c.body ?: @"(nil)",
                 [c.userInfo allKeys] ?: @[]);
        BOOL isBark = ACVIsBarkContent(c);
        if (gBarkOnly && !isBark) {
            ACVDebug(@"非 Bark（gBarkOnly=YES），跳过");
            return;
        }
        NSString *code = ACVExtractCode(c.body) ?: ACVExtractCode(c.title) ?: ACVExtractCode(c.subtitle);
        ACVDebug(@"isBark=%d 提取=%@", isBark, code ?: @"(none)");
        ACVCopyCode(code);
    }
}

// ---------- 挂点 1：NCNotificationRequest 初始化（经典漏斗） ----------
static id (*orig_initReq)(id, SEL, id);
static id hook_initReq(id self, SEL _cmd, id req) {
    id result = orig_initReq(self, _cmd, req);
    ACVDebug(@"hook: initWithNotificationRequest: 触发");
    ACVProcessNotificationRequest(req, @"init");
    return result;
}

// ---------- 挂点 2：notificationRequest getter（兜底，覆盖所有构造路径） ----------
static id (*orig_getNotificationRequest)(id, SEL);
static id hook_getNotificationRequest(id self, SEL _cmd) {
    id r = orig_getNotificationRequest(self, _cmd);
    ACVProcessNotificationRequest(r, @"getter");
    return r;
}

__attribute__((constructor))
static void BarkAutoCopyInit(void) {
    @autoreleasepool {
        ACVDebug(@"=== v0.0.3 已加载，进程=%@ ===", [[NSProcessInfo processInfo] processName]);
        Class cls = NSClassFromString(@"NCNotificationRequest");
        ACVDebug(@"NCNotificationRequest 类：%@", cls ? @"存在" : @"不存在");
        if (cls) {
            SEL s1 = NSSelectorFromString(@"initWithNotificationRequest:");
            if ([cls instancesRespondToSelector:s1]) {
                MSHookMessageEx(cls, s1, (IMP)hook_initReq, (IMP *)&orig_initReq);
                ACVDebug(@"已挂 initWithNotificationRequest:");
            } else {
                ACVDebug(@"该类没有 initWithNotificationRequest: 方法");
            }
            SEL s2 = NSSelectorFromString(@"notificationRequest");
            if ([cls instancesRespondToSelector:s2]) {
                MSHookMessageEx(cls, s2, (IMP)hook_getNotificationRequest, (IMP *)&orig_getNotificationRequest);
                ACVDebug(@"已挂 notificationRequest getter");
            } else {
                ACVDebug(@"该类没有 notificationRequest getter");
            }
        }
    }
}
