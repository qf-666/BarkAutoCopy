// BarkAutoCopy.m
// Bark 推送验证码 → 剪贴板（注入 SpringBoard，覆盖锁屏/横幅/通知中心）
// v0.0.4：适配 iOS 16+ 通知模型 —— initWithNotificationRequest: 的参数是
// NCMutableNotificationRequest / NCNotificationRequest 本体（非 UNNotificationRequest）。
// 用运行时反射挖属性找验证码，诊断写 /var/mobile/Documents/barkautocopy_debug.txt

#import <substrate.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#define ACVLOG(fmt, ...) NSLog(@"[BarkAutoCopy] " fmt, ##__VA_ARGS__)

// ---------- 开关 ----------
// 诊断期对全部通知生效；后续要只认 Bark 时，在 ACVProcessRequestObject 里
// 用 categoryIdentifier/userInfo 判定后 gBarkOnly 风格过滤即可。
static NSTimeInterval gDedupWindow = 10.0; // 相同验证码 X 秒内只写一次剪贴板
static int gDetailBudget = 30;             // 详细日志条数上限，防刷屏

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

static void ACVDebugLimited(NSString *fmt, ...) {
    if (gDetailBudget <= 0) return;
    gDetailBudget--;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    ACVDebug(@"%@", msg);
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
        ACVDebugLimited(@"copy: 无码可复制");
        return;
    }
    @synchronized ([NSObject class]) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (gLastCode && [gLastCode isEqualToString:code] && (now - gLastTs) < gDedupWindow) {
            ACVDebugLimited(@"copy: 去重跳过 %@", code);
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
    if (!ident.length) return NO; // 无标识的不去重
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

// 递归收集对象里的字符串（深度 ≤1），标题正文藏哪都能挖出来
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
        for (id k in [obj allKeys]) {
            ACVCollectStrings([obj objectForKey:k], depth + 1, out);
        }
        return;
    }
    if ([obj isKindOfClass:NSClassFromString(@"NSArray")]) {
        for (id v in obj) ACVCollectStrings(v, depth + 1, out);
        return;
    }
    // 一般对象：反射属性
    Class cls = [obj class];
    NSArray *props = ACVPropertyNames(cls);
    for (NSString *key in props) {
        ACVCollectStrings(ACVValueForKey(obj, key), depth + 1, out);
    }
}

// ---------- 统一处理（兼容新旧通知模型） ----------
static void ACVProcessRequestObject(id req, NSString *via) {
    @autoreleasepool {
        NSString *ident = ACVValueForKey(req, @"notificationIdentifier");
        if (![ident isKindOfClass:NSClassFromString(@"NSString")]) ident = nil;
        if (ACVAlreadyProcessed(ident)) return;

        Class cls = [req class];
        NSArray *props = ACVPropertyNames(cls);
        ACVDebugLimited(@"[%@] 类型=%@", via, NSStringFromClass(cls));
        ACVDebugLimited(@"  属性清单: %@", [props componentsJoinedByString:@", "]);

        NSMutableArray *strings = [NSMutableArray array];
        ACVCollectStrings(req, 0, strings);

        NSString *code = nil;
        for (NSString *t in strings) {
            code = ACVExtractCode(t);
            if (code) break;
        }
        ACVDebug(@"via=%@ type=%@ ident=%@ 挖到字符串=%lu 个，提取=%@",
                 via, NSStringFromClass(cls), ident ?: @"(nil)",
                 (unsigned long)strings.count, code ?: @"(none)");
        ACVCopyCode(code);
    }
}

// ---------- 挂点：NCNotificationRequest 初始化（iOS 15-17 通知漏斗，实测每发必触发） ----------
static id (*orig_initReq)(id, SEL, id);
static id hook_initReq(id self, SEL _cmd, id req) {
    id result = orig_initReq(self, _cmd, req);
    if (req) ACVProcessRequestObject(req, @"init");
    return result;
}

__attribute__((constructor))
static void BarkAutoCopyInit(void) {
    @autoreleasepool {
        ACVDebug(@"=== v0.0.4 已加载，进程=%@ ===", [[NSProcessInfo processInfo] processName]);
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
        }
    }
}
