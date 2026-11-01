# Bark Auto Copy

Bark 推送验证码自动复制到剪贴板的越狱插件（注入 SpringBoard）。

锁屏、横幅、通知中心三处全覆盖：通知一上屏，验证码已经在剪贴板里，直接粘贴即可。

## 原理

钩住 NotificationCenter 私有框架的 `NCNotificationRequest` 类
`initWithNotificationRequest:` 方法 —— SpringBoard 展示任何一条通知前
必然构造该对象，这是锁屏/横幅/通知中心的唯一漏斗。

- 适配 iOS 16+：该方法的入参是 `NCMutableNotificationRequest` / `NCNotificationRequest`
  本体（非 `UNNotificationRequest`），故用运行时反射挖取全部字符串属性
- 提码：关键字正则（验证码/校验码/动态码/code/OTP… + 4~8 位数字），兜底认纯数字正文
- 写板：`UIPasteboard.generalPasteboard`，10 秒去重窗口

## 支持

- iOS 15 ~ 17
- arm64 / arm64e
- 无根越狱（Dopamine / palera1n），安装路径 `/var/jb`
  - 有根越狱（checkra1n 等）：删除 Makefile 中 `THEOS_PACKAGE_SCHEME := rootless` 一行后重新构建

## 编译

### GitHub Actions（本仓库自带）

- push 到 `main`：自动构建，Actions 页签下载 `BarkAutoCopy-deb` 产物
- 推送 `v*` 标签（如 `v0.0.1`）：自动发布 Release 并附带 deb

### 本地 theos（macOS）

```bash
brew install dpkg fakeroot ldid xz
git clone --recursive https://github.com/theos/theos.git ~/theos
mkdir -p ~/theos/sdks
# 从 https://github.com/theos/sdks 取一个 iPhoneOS SDK 放进 ~/theos/sdks/
make package
```

## 安装

```bash
# 把 packages/*.deb 传到手机后
dpkg -i /var/jb/tmp/com.example.barkautocopy_0.0.1_iphoneos-arm64.deb
sbreload        # 或 killall -9 SpringBoard
```

## Bark 推送格式示例（官方文档：https://bark.day.app/#/params）

```bash
# GET：正文直接放路径里（裸推也能识别，插件靠 category=myNotificationCategory 认 Bark）
curl "https://api.day.app/你的KEY/验证码123456"

# POST 表单：标题+正文分开
curl -X POST "https://api.day.app/你的KEY" -d 'title=验证码' -d 'body=123456'

# JSON：走 /push 端点
curl -X POST "https://api.day.app/push" -H "Content-Type: application/json" \
  -d '{"device_key":"你的KEY","title":"验证码","body":"123456","level":"timeSensitive"}'
```

## 配置

改 `BarkAutoCopy.m` 顶部开关后重新构建：

- `gBarkOnly = YES`：只处理 Bark 通知（识别：category=myNotificationCategory / userInfo Bark 字段 / 标题 Bark）；改 `NO` 对所有带验证码的通知生效
- `gDedupWindow = 10.0`：相同验证码的写入去重窗口（秒）

## 目录结构

```
.
├── .github/workflows/build.yml   # CI 构建
├── BarkAutoCopy.m                # 主代码
├── BarkAutoCopy.plist            # 注入过滤器（springboard）
├── Makefile                      # theos 构建脚本
├── control                       # deb 包描述
└── README.md
```
