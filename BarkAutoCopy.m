// BarkAutoCopy.m
// Bark 推送验证码 → 剪贴板（注入 SpringBoard，覆盖锁屏/横幅/通知中心）
// v0.0.6：只认 Bark 通知（categoryIdentifier == myNotificationCategory），
// 反射 NCNotificationRequest 属性字符串提取验证码。

#import <substrate.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 相同验证码在窗口期内只写一次剪贴板，防锁屏/解锁/通知中心重复触发
static NSTimeInterval gDedupWindow = 10.0;

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
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = code;
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
    if (!ident.length) return NO;
    NSMutableSet *s = ACVSeenSet();
    @synchronized (s) {
        if ([s containsObject:ident]) return YES;
        if (s.count > 200) [s removeAllObjects];
        [s addObject:ident];
    }
    return NO;
}

// ---------- 运行时反射工具 ----------
static NSArray *ACVPropertyNames(Class cls) {
    NSMutableArray *names = [NSMutableArray array];
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *n = property_getName(props[i]);
        if (n) [names addObject:[NSString stringWithUTF8String:n]];
    }
    free(props);
    Class sup = class_getSuperclass(cls);
    if (sup && sup != NSClassFromString(@"NSObject")) {
        [names addObjectsFromArray:ACVPropertyNames(sup)];
    }
    return names;
}

static id ACVValueForKey(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static void ACVCollectStrings(id obj, int depth, NSMutableArray *out) {
    if (!obj) return;
    if ([obj isKindOfClass:NSClassFromString(@"NSString")]) {
        if ([obj length]) [out addObject:obj];
        return;
    }
    if ([obj isKindOfClass:NSClassFromString(@"NSNumber")]) return;
    if ([obj isKindOfClass:NSClassFromString(@"NSDate")]) return;
    if (depth > 1) return;
    if ([obj isKindOfClass:NSClassFromString(@"NSDictionary")]) {
        for (id k in [obj allKeys]) ACVCollectStrings([obj objectForKey:k], depth + 1, out);
        return;
    }
    if ([obj isKindOfClass:NSClassFromString(@"NSArray")]) {
        for (id v in obj) ACVCollectStrings(v, depth + 1, out);
        return;
    }
    Class cls = [obj class];
    for (NSString *key in ACVPropertyNames(cls)) {
        ACVCollectStrings(ACVValueForKey(obj, key), depth + 1, out);
    }
}

// ---------- Bark 判定 ----------
// Bark 所有推送（含裸推）aps.category 恒为 myNotificationCategory，
// 落到设备即 content.categoryIdentifier；杂 App 通知没有这个值，据此精确过滤。
static BOOL ACVIsBarkCategory(id req) {
    id cat = ACVValueForKey(req, @"categoryIdentifier");
    if ([cat isKindOfClass:NSClassFromString(@"NSString")]) {
        return [cat isEqualToString:@"myNotificationCategory"];
    }
    return [ACVValueForKey(req, @"category") isEqualToString:@"myNotificationCategory"];
}

// ---------- 统一处理 ----------
static void ACVProcessRequestObject(id req) {
    @autoreleasepool {
        if (!ACVIsBarkCategory(req)) return; // 只认 Bark，其余通知直接放行

        NSString *ident = ACVValueForKey(req, @"notificationIdentifier");
        if (![ident isKindOfClass:NSClassFromString(@"NSString")]) ident = nil;
        if (ACVAlreadyProcessed(ident)) return;

        NSMutableArray *strings = [NSMutableArray array];
        ACVCollectStrings(req, 0, strings);

        NSString *code = nil;
        for (NSString *t in strings) {
            code = ACVExtractCode(t);
            if (code) break;
        }
        ACVCopyCode(code);
    }
}

// ---------- 挂点：NCNotificationRequest 初始化 ----------
static id (*orig_initReq)(id, SEL, id);
static id hook_initReq(id self, SEL _cmd, id req) {
    id result = orig_initReq(self, _cmd, req);
    if (req) ACVProcessRequestObject(req);
    return result;
}

__attribute__((constructor))
static void BarkAutoCopyInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"NCNotificationRequest");
        if (!cls) return;
        SEL s1 = NSSelectorFromString(@"initWithNotificationRequest:");
        if ([cls instancesRespondToSelector:s1]) {
            MSHookMessageEx(cls, s1, (IMP)hook_initReq, (IMP *)&orig_initReq);
        }
    }
}
