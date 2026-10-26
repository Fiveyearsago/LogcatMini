# Mac 自动测试实验版

本功能统一在 `feature/mac-automation` 分支继续开发，包含自动化执行、控件定位修复及最新 Mac 主线功能。不接入 AI，不改变 Windows 行为。先验证“完整 APK 安装 → 固定用例 → 应用内结果 → Markdown 与证据导出”。

## 构建与打开

在项目根目录执行，构建命令不要并发运行：

~~~sh
bash scripts/prepare-recording-runtime.sh
swift test
bash scripts/build-automation-preview.sh
open "dist/Logcat Mini Automation Preview.app"
~~~

Preview 使用独立 Bundle ID 和偏好目录，可与现有日志客户端并存；脚本不安装到 Applications，也不生成分发 ZIP。主窗口顶部切换“日志 / 自动测试”，日志页同时保留投屏、设备信息、请求模拟和本地项目构建。公开分支的验证范围与待办见 [验证记录](automation-testing-validation.md)。

## 本机依赖

在“自动测试 → 测试设置”确认路径：

| 组件 | 用途 |
| --- | --- |
| Android SDK platform-tools / adb | 连接、安装、启动、控件树、截图、日志 |
| Android SDK Build Tools / aapt2 | 读取 APK 真实包名、版本和 SDK 要求 |
| Maestro CLI | 点击、输入前定位、滑动和按键（文字经 ADB 注入） |
| Java 17 或更高 | 运行 Maestro |

基础启动模板不需要 Maestro。组件缺失时会给出路径配置提示，不会静默安装。

执行适配器曾使用 Maestro 2.11.0 验证。[官方安装说明](https://docs.maestro.dev/maestro-cli/how-to-install-maestro-cli.md)。该次使用的官方发行包 SHA-256：5384593cb4e7a106489e75a821d157dd43f4e438df6bc308b72e82c685e1283a。

客户端运行 Maestro 时设置 MAESTRO_CLI_NO_ANALYTICS，关闭其匿名统计；不使用 Maestro Cloud，不发送测试材料给 AI。第三方执行组件自身的更新检查不等同于模型调用。

## 使用流程

1. 手机开启并授权 USB 调试，保持解锁。
2. 切换“自动测试”，选择 APK 和设备。支持可独立安装的签名 Release APK，不要求 debuggable。
3. 到“用例库”选择基础启动模板、导入 JSON，或创建自己的用例。每个用例必须有断言。
4. 编辑步骤：优先填控件 ID，也可按精确文字或内容描述定位；多个字段共同限制目标。设备控件选择器只读取当前页面。
5. 保存用例集，在任务页勾选要执行的用例，填写环境说明。
6. 开始测试。默认覆盖安装并保留数据；签名冲突或降级失败会停止，不自动卸载。清数据需在任务页明确勾选。
7. 在“运行结果”查看步骤的预期、实际、截图与日志。失败/阻塞可另建复测任务，保留两次记录。
8. 导出 MD 报告，得到 report.md、result.json、manifest.json 和 evidence 文件夹；APK 不随报告导出。

停止测试会终止当前任务拥有的执行器，保留已完成结果，后续步骤标为未执行。已经发生的设备动作不会撤销。任务期间不要用其他工具操作同一手机。

## 用例配置

用例集绑定包名，保存产生修订号。导入和执行前检查 schemaVersion、未知字段、唯一编号、断言、超时、定位目标和变量。

可视化编辑器支持主体步骤、排序、超时和匹配条件。编辑器中的 JSON 模式可编辑前置检查和收尾步骤。前置检查只能使用只读断言/等待。普通字符串变量使用双花括号引用；密钥、密码等敏感变量目前拒绝执行，请先在手机上准备账号。

主要支持：

- 启动、重启、点击、ASCII 输入、滑动、Back / Home / Enter。
- 等待元素、可见/不可见、文字精确/包含/正则匹配、前台应用。
- 日志出现/不出现：必须引用之前步骤的编号作为采集游标起点；不会搜索设备残留日志。
- 主动截图，以及失败自动截图。

不可见和日志不出现断言需要完成配置的观察窗口。动作完成不等于业务通过；后续断言决定结果。界面和 MD 都使用同一份 result.json 数据。

## 独立 Release 演示

演示包不申请网络权限，包名 com.songran.logcatmini.automationfixture，不会修改业务 App。

~~~sh
python3 scripts/build-automation-fixture.py
~~~

需要 Android SDK 35 平台、Build Tools 35.0.0 与 Java 17。签名密钥只为本机演示生成，位于被 Git 忽略的 .build 目录；不要用于生产应用。重新生成密钥后，设备上的旧演示包可能需要操作者自行处理签名冲突。

在客户端选择 dist/automation-fixture/LogcatMini-AutomationFixture-release.apk，然后在用例库点“演示用例”。四条用例中，前三条检查启动、语言设置重启持久化、输入保存；第四条故意写错预期，验证失败分类和截图。预期结果为三条通过、一条失败。

真机验收测试必须显式指定目标，普通 swift test 不会安装或操作手机：

~~~sh
LOGCATMINI_AUTOMATION_DEVICE="<已授权的测试设备序列号>" \
LOGCATMINI_AUTOMATION_ROOT="$PWD" \
swift test --filter AutomationIntegrationTests/testExplicitDeviceReleaseFixtureEndToEnd
~~~

## 公开合成示例

[日志窗口示例](examples/demo-startup-logs.json) 展示正则、日志出现和不出现断言；[关系定位示例](examples/demo-related-button.json) 展示 `belowText` 消除重复按钮歧义。两者均使用虚构 `com.example.demo` 和事件约定，可导入编辑，不代表某个真实 APK 已通过验收。安装仓库自带演示 APK 时，应使用客户端的“演示用例”。

## 本轮实现边界

详细设计是后续完整能力的方向，本轮实验版优先打通闭环，以下能力有明确限制：

- 每次运行固定一台设备、Android 主用户、完整 APK。未做 Split APK、工作资料、多设备矩阵。
- 当前 Android 输入适配器只开放 ASCII，运行前请把设备输入法切换为英文 / Alphabet；中文元素定位和断言可用。拼音输入法可能把按键保留在候选区，命令成功不代表文字已进入输入框。执行器会核对实际文字，不一致时阻塞并提示切换输入法，不自动更改键盘设置。密码框和内容无法确认的输入框暂不支持。自动清除输入框仅支持最多 100 个 UTF-16 单位，较长文本需提前手动处理。
- Maestro 每个动作独立启动，当前有明显启动耗时；连续动作合并为执行段尚未实现。
- UI Automator 必须能读到控件；游戏、自绘 Canvas、部分 WebView 等页面不保证适用。
- 默认 10 秒查找、3 分钟用例、30 分钟任务上限。Maestro 动作额外预留进程启动时间，界面读取也有独立超时，并受用例总时限约束。
- 目前只有日志和关键截图，尚未接入自动录屏、文本脱敏预览、凭据存储、历史删除与存储占用管理。
- 必需日志采集中断会阻塞；崩溃/ANR 只覆盖可通过 AndroidRuntime、libc、ActivityManager 归因的已观测事件，未看到不代表不存在。
- 原始运行目录保留 APK 和用例快照。分享导出不包含 APK、完整配置快照或 Maestro 内部调试目录；日志及截图仍可能含业务信息。
- manifest.json 保存导出附件是否存在及 SHA-256，便于审计；历史读取不会自动把一次旧失败替换为复测通过。
- 用例库、运行记录和执行组件配置跨启动保存。尚未实现多个独立客户端实例之间的设备互斥，请勿同时运行两个测试实例。
- 环境说明由操作者填写，客户端不验证生产/测试服务端，不断言后台记账、埋点接收或真实业务完成。

设计文档：[第一版方案](automation-testing-v1-plan.md)、[用例配置设计](automation-testing-case-guide.md)、[报告模板设计](automation-testing-report-template.md)。以本文件说明的已实现范围为准。
