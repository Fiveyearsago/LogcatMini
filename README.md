# Logcat Mini

轻量的 Android 日志与设备调试工具。少一点噪声，多一点线索。

A lightweight Android log viewer and device toolbox, with a native macOS app and a Windows preview.

[![macOS checks](https://github.com/Fiveyearsago/LogcatMini/actions/workflows/macos.yml/badge.svg)](https://github.com/Fiveyearsago/LogcatMini/actions/workflows/macos.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## 功能

- **实时日志**：按设备、应用和 UID 采集；等级、Tag、关键词、正则过滤；查找、暂停滚动、跟随最新和导出。
- **日志详情**：JSON 与键值日志格式化、节点折叠、完整复制；识别连续分段日志并合并。
- **手机投屏（Mac）**：在日志右侧查看和操作 Android 手机；点击、拖动、滚动、键盘输入、隐藏软键盘、拖入 APK 安装。
- **截图与录屏**：保存或复制截图，录屏，媒体历史缩略图与预览。
- **本地项目运行（Mac）**：关联 Android 源码，选择 Flavor 和构建类型，编译、安装、启动；无需打开 Android Studio。
- **请求调试（Mac）**：从日志导入请求、编辑 URL / Header / Body、查看响应；可选配置自己的 s 串解密服务和 RSA 密钥。

Mac 使用 SwiftUI + AppKit，Windows 预览使用 Avalonia + .NET。两端功能进度不同，Windows 说明见 [windows/README.md](windows/README.md)。

## Mac 从源码运行

运行环境为 macOS 13+；构建需要带 macOS SDK 的 Xcode、Swift 5.9+，以及首次下载录屏组件时的网络连接。ADB 请从 [Google Platform-Tools](https://developer.android.com/tools/releases/platform-tools) 获取，或使用已有 Android SDK。

```sh
git clone https://github.com/Fiveyearsago/LogcatMini.git
cd LogcatMini
bash scripts/prepare-recording-runtime.sh
swift test
bash scripts/build-app.sh
open 'dist/Logcat Mini.app'
```

`prepare-recording-runtime.sh` 下载指定版本的官方 scrcpy，校验 SHA-256，并准备投屏 / 录屏组件。第三方运行时二进制不提交到此仓库。仓库附带自有 Android 元数据辅助程序，其源码位于 `android-helper/`；修改后可使用 Android SDK 35、build-tools 35.0.0 和 JDK 17 运行 `bash scripts/build-android-helper.sh` 重建。

安装到当前用户的应用目录：`bash scripts/build-app.sh --install`。
生成 Apple Silicon / Intel 通用 ZIP：`bash scripts/package-share.sh`。
本地构建使用 ad-hoc 签名，不包含 Developer ID 签名或 Apple 公证。Intel 架构可编译，但尚无 Intel Mac 实机验收。

## 开始使用

1. 手机开启 USB 调试，连接 Mac，并在手机上授权这台电脑。
2. 启动应用；如未发现 ADB，在设置中选择 `adb` 文件。
3. 在侧栏选择设备和应用，实时查看日志。点击手机投屏可边操作边查看。
4. 使用筛选栏的关键词、Tag 和等级缩小范围。多关键词以 `|` 分隔；正则开关开启后按完整表达式匹配。
5. 退出前导出需要保留的日志。截图和录屏首次使用时选择本机保存目录。

常用快捷键：`⌘F` 查找，`⌘L` 切换跟随（暂停时恢复），`⌘P` 暂停 / 恢复滚动，`⌘K` 清空视图，`⌘⇧F` 日志全屏，`⌘⇧S` 导出，`⌥⌘S` 保存截图并复制，`⇧⌘C` 仅复制截图。

## 数据与网络

日志保存在本机内存中；偏好、收藏及请求 / 媒体历史保存在使用者的本机目录。没有账号系统、日志上传后台或遥测。ADB 操作仅针对你已授权的设备。

请求重放会把你编辑的请求发送到指定 URL。远程解密默认没有服务地址，只有在填写地址并点击“服务解密”时才发送所选 s。公钥 / 私钥需自行导入，只在本次运行中使用，不附带业务密钥。s 编解码仅支持文档描述的特定封装，不保证适用于任意应用，见 [s 串扩展说明](docs/s-packet.md)。

不要将真实日志、请求凭证、设备标识或密钥提交到仓库或公开 Issue。详情见 [SECURITY.md](SECURITY.md)。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Sources/LogcatMini` | 原生 Mac 客户端 |
| `Sources/LogcatCore` | 日志解析、合并、过滤、格式化和请求处理 |
| `Tests` | 自动测试与合成日志样本 |
| `android-helper` | 应用名称 / 图标辅助程序源码 |
| `windows` | Windows 预览版与检查程序 |
| `scripts` | 构建、组件准备和打包入口 |

## 贡献与许可

欢迎提交可复现的问题和小范围 Pull Request。开发与验证约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

项目原创代码使用 [MIT License](LICENSE)。第三方代码、组件和许可证不因本项目许可而改变，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
