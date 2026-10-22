# Logcat Mini for Windows

Windows 10/11 Intel/AMD x64 预览版，Avalonia 12.1.4 + .NET 10。自包含 ZIP，无需安装 .NET；ADB 由用户自行从 Google 获取。现有 SwiftUI Mac 客户端保持独立。

## 结构

- LogcatMini.Core：ADB、UID 采集、日志解析/过滤/查找、分段合并、JSON、收藏元数据与设置。
- LogcatMini.Desktop：虚拟绘制列表、整表横向滚动、可选中格式化文档与 JSON 折叠、查找、主题与布局。
- LogcatMini.Checks：合成分段样本、边界条件、持久化、100001 条保留、可选真机验证。
- LogcatMini.UiChecks：实际控件事件检查，包括整表滚轮/表头同步、快捷键、格式化剪贴板、设备隔离、全屏和设置重启。

Windows 为预览版，包含日志查看、过滤、格式化、截图录屏与媒体历史。Mac 的投屏、本地项目运行及请求调试未在 Windows 完整实现。Windows 启动、USB 驱动、Win32 渲染及高 DPI 仍需实机验收。

## 开发

安装 global.json 指定的 .NET SDK。首次准备录屏组件时，在项目根目录运行 `python3 scripts/prepare-windows-recording.py`（Windows 可使用 `python`，需要 Python 3）；脚本校验官方组件哈希且不复制 ADB。然后在 windows 目录执行：

    dotnet run --project LogcatMini.Checks
    dotnet run --project LogcatMini.UiChecks
    dotnet run --project LogcatMini.Desktop
    dotnet run --project LogcatMini.Desktop -- --demo

--demo 只加载内置合成数据；UI 检查用临时 LOGCAT_MINI_DATA_DIR 隔离设置。真机检查仅应在你有权使用的测试手机上执行。先设置 `LOGCAT_MINI_DEVICE`（设备序列号）和 `LOGCAT_MINI_PACKAGE`（测试应用包名）环境变量，再从仓库根目录执行：

    dotnet run --project windows/LogcatMini.Checks -- --device

## 打包

从仓库根目录运行 scripts/package-windows.sh，或在 Windows PowerShell 运行 ../scripts/package-windows.ps1。
脚本先校验并准备录屏组件、执行检查，再自包含发布 win-x64，附说明、许可证并生成 ZIP + SHA256。
不包括设备日志、测试样本、本机设置和本机 ADB。不发布到外部服务。
升级 runtime 或依赖后需同步核对 licenses 目录对应版本。

所有主机参数通过 ProcessStartInfo.ArgumentList 传递，远端命令 UID 只接受 ASCII 数字。
收藏元数据复用项目 Android helper，临时上传并清理，不拉取 APK。
停止仅终止本客户端创建的 adb 进程，不停止 adb server。
日志保存在内存中，不保存历史。元数据缓存、设置和媒体历史索引保存在用户 LocalApplicationData 下；截图和录屏保存在用户选择的文件夹。录屏绑定启动时的设备，保存失败保留临时文件供重试。Windows 内嵌视频预览使用系统 Media Foundation。

## Windows 实机验收

1. 无 .NET/Android Studio 的电脑解压启动，检查 100%/150%/200% DPI。
2. ADB 路径带空格，手机 USB 授权、包名/UID、采集、断线与恢复。
3. 收藏的名称/图标，重启后主题/收藏/字号/列/侧栏保留，日志从空白开始。
4. 鼠标横滑、Shift+滚轮、左右键和底部滚动条移动整张日志表及表头；隐藏列后消息填满剩余区域。
5. 两种全屏、查找二次隐藏、JSON 搜索自动展开、复制和导出。
6. 多设备会话与包名恢复、同 UID 应用、大流量长期采集及内存占用。
7. 截图目录重用、录屏切设备/停止/退出保存、保存失败重试、媒体历史搜索及内嵌播放。

## 资料

- [Avalonia 平台支持](https://docs.avaloniaui.net/docs/supported-platforms)
- [.NET Windows 依赖](https://learn.microsoft.com/en-us/dotnet/core/install/windows)
- [Google Platform-Tools](https://developer.android.com/tools/releases/platform-tools)
- [Android USB 驱动](https://developer.android.com/studio/run/oem-usb)
- [用户说明](使用说明.txt)

## 快捷键与图片剪贴板

`Ctrl+J` 在格式化与原始日志间切换，`Ctrl+Shift+C` 截取设备图片并复制，`Ctrl+Alt+C` 复制完整详情或媒体历史中的选中截图。按钮旁显示按键提示。
