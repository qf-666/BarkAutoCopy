// BarkAutoCopy.m
// Bark 推送验证码 → 剪贴板（注入 SpringBoard，覆盖锁屏/横幅/通知中心）
// 编译：theos（见 Makefile）或手动 clang + SDK

#import <substrate.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

// ---------- 开关 ----------
static BOOL gBarkOnly = YES;               // YES=只处理 Bark 通知；NO=对所有带验证码的通知生效
static NSTimeInterval gDedupWindow = 10.0; // 相同验证码 X 秒内只写一次剪贴板

// ---------- Bark 识别 ----------
// Bark 服务端会把 url/copy/autoCopy/group/level/isArchive/badge 等自定义字段塞进 APNs 负载，
// 到端上就是 content.userInfo 的 key。命中任一 key 即认定为 Bark 推送。
static BOOL ACVIsBarkContent(UNNotificationContent *c) {
    NSDictionary *ui = c.userInfo ?: @{};
    static NSSet *barkKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        barkKeys = [NSSet setWithArray:@[
            @"url", @"copy", @"autoCopy", @"isArchive", @"group", @"level", @"badge"
        ]];
    });
    for (NSString *k in ui) {
        if ([barkKeys containsObject:k]) return YES;
    }
    NSString *title = c.title ?: @"";
    return [title isEqualToString:@"Bark"]; // 默认标题兜底
}

// ---------- 验证码提取 ----------
// 优先：关键字+数字（验证码/校验码/code/OTP…）；兜底：正文/标题本身就是 4~8 位纯数字
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

// ---------- 剪贴板写入（带去重） ----------
static NSString *gLastCode = nil;
static NSTimeInterval gLastTs = 0;
static void ACVCopyCode(NSString *code) {
    if (!code.length) return;
    @synchronized ([NSObject class]) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (gLastCode && [gLastCode isEqualToString:code] && (now - gLastTs) < gDedupWindow) return;
        gLastCode = code;
        gLastTs = now;
    }
    // 主线程写剪贴板，避免 UIPasteboard 跨线程问题
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = code;
    });
}

// ---------- 主挂点 ----------
// NCNotificationRequest 是 NotificationCenter 私有框架里"一条通知"的包装对象。
// SpringBoard 展示任何通知（锁屏、横幅、通知中心）前都要经 initWithNotificationRequest:
// 构造一次 —— 这就是单点截获的漏斗。
static id (*orig_initWithNotificationRequest)(id, SEL, id);
static id hook_initWithNotificationRequest(id self, SEL _cmd, id req) {
    id result = orig_initWithNotificationRequest(self, _cmd, req);
    @autoreleasepool {
        if ([req isKindOfClass:NSClassFromString(@"UNNotificationRequest")]) {
            UNNotificationRequest *r = (UNNotificationRequest *)req;
            UNNotificationContent *c = r.content;
            if (!c) return result;
            if (gBarkOnly && !ACVIsBarkContent(c)) return result;
            NSString *code = ACVExtractCode(c.body) ?: ACVExtractCode(c.title);
            ACVCopyCode(code);
        }
    }
    return result;
}

__attribute__((constructor))
static void BarkAutoCopyInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"NCNotificationRequest");
        if (cls) {
            MSHookMessageEx(cls,
                NSSelectorFromString(@"initWithNotificationRequest:"),
                (IMP)hook_initWithNotificationRequest,
                (IMP *)&orig_initWithNotificationRequest);
        }
    }
}
