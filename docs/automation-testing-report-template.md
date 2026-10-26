# Logcat Mini 自动化测试 Markdown 报告模板

状态：第一版设计草案。日期：2026-10-13。

本文定义未来自动生成的 Markdown 内容、字段与附件规则。双花括号是字段占位说明，不表示已经实现的模板引擎；所有列表和重复区块由同一份结构化测试结果生成。本文没有真实测试结论或真实截图。

相关文档：[第一版方案](automation-testing-v1-plan.md)、[用例配置说明](automation-testing-case-guide.md)。

## 1 生成与格式要求

- 文件名为 report.md，使用 UTF-8，时间携带明确时区，耗时使用单调时钟计算。
- 报告与应用内详情共用 result.json；报告不重新猜测结果或自行调用 AI。
- 默认导出 report.md 与附件目录，附件使用相对路径，不写作者电脑的绝对路径。
- 截图用 Markdown 图片，视频用文件链接，日志提供片段及完整文件链接。
- 只有确认导出成功的附件才能生成链接；缺失、损坏、被排除的附件用文字说明。
- 占位符不得出现在最终报告，未获得的值写“未获取”并给出原因，不写为零或假值。
- 应用名、步骤文本和日志内容进行 Markdown 转义；日志代码围栏长度避开正文中的反引号，不能让日志伪装成报告结论。
- 诊断根因、测试事实和人工复核分开；AI 未接入时明确写“未启用”。
- 前置准备、收尾失败和报告导出错误各自保留，不能覆盖主要失败。
- 缺陷严重度由 QA 复核；用例 P0、P1、P2 优先级不能自动转换为缺陷严重度。

## 2 标准报告正文

以下从“应用名称自动化测试报告”开始的内容为报告结构。带“重复”说明的区块按实际用例数量展开，正式导出时不保留这些说明。

### 应用名称自动化测试报告

结论：**{{summary.verdictLabel}}**。本次选择 {{summary.selected}} 条用例，通过 {{summary.passed}}，失败 {{summary.failed}}，阻塞 {{summary.blocked}}，已取消 {{summary.cancelled}}，未执行 {{summary.notRun}}。

验收完成状态：{{summary.completionLabel}}。本地证据状态：{{evidence.localCompleteness}}。导出附件状态：{{export.attachmentStatus}}。

本结论仅适用于下列 APK、设备、环境与所选用例，不代表整个应用没有缺陷。

#### 运行信息

| 项目 | 值 |
| --- | --- |
| 运行编号 | {{run.id}} |
| 来源运行 | {{run.parentRunIdOrNone}} |
| 任务名称 | {{run.name}} |
| 应用名称 | {{apk.appName}} |
| 包名 | {{apk.packageName}} |
| APK 文件名 | {{apk.fileName}} |
| APK versionName 与 versionCode | {{apk.versionName}} / {{apk.versionCode}} |
| APK SHA-256 | {{apk.sha256}} |
| 安装后实际版本 | {{installed.versionName}} / {{installed.versionCode}} |
| 安装校验 | {{installed.verification}} |
| 设备型号 | {{device.model}} |
| 设备序列号 | {{device.exportSerial}} |
| Android 版本与 API 等级 | {{device.androidVersion}} / {{device.apiLevel}} |
| 屏幕尺寸与方向 | {{device.display}} |
| 系统语言 | {{device.locale}} |
| 测试环境 | {{environment.name}} |
| 环境确认方式 | {{environment.verification}} |
| 账号标识 | {{environment.redactedAccountAlias}} |
| 安装与数据策略 | {{run.installPolicy}} / {{run.dataPolicy}} |
| 用例集与修订 | {{suite.name}} / {{suite.revision}} |
| 用例快照校验值 | {{suite.snapshotSha256}} |
| Logcat Mini 版本 | {{runner.clientVersion}} |
| 主机系统与架构 | {{runner.hostPlatform}} |
| 执行引擎与版本 | {{runner.engineName}} / {{runner.engineVersion}} |
| ADB 与 Java 版本 | {{runner.adbVersion}} / {{runner.javaVersion}} |
| 开始时间 | {{run.startedAtWithTimezone}} |
| 结束时间 | {{run.endedAtWithTimezone}} |
| 总耗时 | {{run.duration}} |
| 停止原因 | {{run.terminationReason}} |

设备序列号可以在分享导出时脱敏，本地记录保留准确目标。账号标识只能输出别名或脱敏值，不能输出密码、访问令牌或验证码。

#### 范围与前置条件

本次覆盖：{{coverage.selectedRequirementsAndCases}}。

本次未覆盖：{{coverage.exclusions}}。

| 前置条件 | 声明值 | 验证方式 | 实际状态 |
| --- | --- | --- | --- |
| {{precondition.name}} | {{precondition.declaredValue}} | {{precondition.method}} | {{precondition.actualResult}} |

如果环境仅由操作者指定，记录“人工指定，未自动验证”，不得改写为“已验证测试服”。若后台业务状态不可观测，在未覆盖中明确说明。

#### 汇总

| 指标 | 数值 | 计算规则 |
| --- | --- | --- |
| 选中用例 | {{summary.selected}} | 仅统计本次选择的用例 |
| 通过 | {{summary.passed}} | 必需断言满足且必需证据完整 |
| 失败 | {{summary.failed}} | 明确断言失败或已归因的目标应用故障 |
| 阻塞 | {{summary.blocked}} | 条件或证据不足，无法有效判断 |
| 已取消 | {{summary.cancelled}} | 人工停止时尚未形成失败的当前用例 |
| 未执行 | {{summary.notRun}} | 已选择但没有开始 |
| 断言完成率 | {{summary.assertionCompletionRate}} | 通过加失败，再除以选中数 |
| 通过比例 | {{summary.passFraction}} | 通过数 / 选中数，同时展示百分比 |
| 异常线索 | {{summary.observationCount}} | 不等于缺陷数，也不直接影响通过比例 |

#### 用例结果

| 编号 | 用例名称 | 优先级 | 结果 | 耗时 | 失败步骤或阻塞原因 |
| --- | --- | --- | --- | --- | --- |
| {{case.id}} | {{case.name}} | {{case.priority}} | {{case.statusLabel}} | {{case.duration}} | {{case.summary}} |

#### 用例详情

以下区块按每条所选用例重复，包括通过、阻塞和未执行用例。

##### {{case.id}} {{case.name}}

结果：{{case.statusLabel}}。关联需求：{{case.requirement}}。

起始状态：{{case.startState}}。前置条件结果：{{case.preconditionResult}}。

| 步骤 ID | 操作与目标 | 预期 | 实际观测 | 结果 | 耗时 |
| --- | --- | --- | --- | --- | --- |
| {{step.id}} | {{step.actionAndTarget}} | {{step.expected}} | {{step.actual}} | {{step.statusLabel}} | {{step.duration}} |

失败或阻塞说明：{{case.failureOrBlockDescription}}。

错误分类：{{case.failureKind}}。根因状态：{{case.rootCauseStatus}}。

复现步骤：

1. {{case.reproductionPreparation}}
2. {{case.reproductionAction}}
3. {{case.reproductionObservation}}

证据：

- 截图：{{evidence.screenshotMarkdownOrReason}}
- 日志片段：{{evidence.logExcerptFencedOrReason}}
- 完整步骤日志：{{evidence.logLinkOrReason}}
- 录屏与覆盖时间：{{evidence.recordingLinkAndRangeOrReason}}
- 控件信息：{{evidence.elementSnapshotOrReason}}

收尾结果：{{case.cleanupStatus}}。

运行后仍需处理的状态：{{case.remainingStateOrNone}}。

#### 崩溃和异常线索

| 时间 | 来源 | 目标归因 | 观测事实 | 关联用例 | 证据 |
| --- | --- | --- | --- | --- | --- |
| {{observation.time}} | {{observation.source}} | {{observation.attribution}} | {{observation.fact}} | {{observation.caseIdOrNone}} | {{observation.evidenceOrReason}} |

没有匹配事件时写“在已记录的采集范围内未发现匹配事件”，同时保留下面的证据质量说明。普通 Error 日志和疑似页面卡住不得直接写成已确认崩溃或 ANR。

#### 证据质量与限制

| 项目 | 状态 | 对结论的影响 |
| --- | --- | --- |
| 应用日志采集窗口 | {{quality.appLogWindow}} | {{quality.appLogImpact}} |
| 系统事件采集窗口 | {{quality.systemEventWindow}} | {{quality.systemEventImpact}} |
| 丢失或中断记录 | {{quality.gaps}} | {{quality.gapImpact}} |
| 时间关联 | {{quality.clockAlignment}} | {{quality.clockImpact}} |
| 截图完整性 | {{quality.screenshots}} | {{quality.screenshotImpact}} |
| 录屏范围 | {{quality.recordingCoverage}} | {{quality.recordingImpact}} |
| 导出排除项 | {{export.exclusions}} | 本地证据状态与导出可见范围分别说明 |

#### 人工复核与后续分析

人工复核：{{review.statusOrNotReviewed}}。

AI 分析：首版未启用。

后续分析或复测使用新的附加记录，不修改本次实际观测或原始失败。复测入口仅作为本地客户端操作，不在共享 MD 中放入含本机绝对路径或凭据的执行命令。

#### 附件清单

| 文件 | 用途 | 导出状态 | SHA-256 |
| --- | --- | --- | --- |
| {{attachment.relativePath}} | {{attachment.purpose}} | {{attachment.status}} | {{attachment.sha256OrUnavailable}} |

APK 默认不随报告导出；report.md 不计算自身写入内容的哈希，导出 manifest 可以在报告落盘后单独记录文件校验值。

## 3 具体结果示例

以下全部为格式演示，未执行 APK 测试，也没有对应附件。

结论：**发现失败，且本次验收未完成**。选择 5 条用例，通过 3、失败 1、阻塞 1、已取消 0、未执行 0。断言完成率为 4 / 5，即 80%；通过比例为 3 / 5，即 60%。

| 编号 | 用例 | 结果 | 说明 |
| --- | --- | --- | --- |
| START-001 | 启动进入首页 | 通过 | 首页标识可见 |
| NAV-001 | 进入设置并返回 | 通过 | 返回后首页标识可见 |
| SETTINGS-001 | 语言设置重启后保留 | 失败 | 重启后预期 English，实际简体中文 |
| FORM-001 | 错误输入显示提示 | 通过 | 提示文本满足预期 |
| BUSINESS-001 | 专用测试账号领取奖励 | 阻塞 | 所需账号未准备，未开始领取步骤 |

SETTINGS-001 失败详情：

- 失败步骤：check-persisted。
- 操作：选择 English，确认当前值，重启应用，再次进入设置。
- 预期：language_value 显示 English。
- 实际：10 秒观察结束时仍显示简体中文。
- 结论：持久化验收断言不满足。
- 根因：待确认，不能仅由这个结果断定某个存储函数存在问题。
- 收尾：演示假设恢复中文成功。
- 证据：此处为示例，不提供虚构截图或日志链接；真实报告从导出 manifest 生成链接。

BUSINESS-001 阻塞详情：

- 前置条件：专用账号已登录且当天可领取。
- 实际：没有可用的专用测试账号。
- 结论：未执行领取操作，无法判断奖励逻辑。
- 后续处理：准备账号后创建新的运行记录。

## 4 导出一致性检查

发布首版时，应针对真实运行验证以下关系：

1. 所选数等于五种终态计数之和，界面和 MD 一致。
2. 每条失败都能定位到实际步骤或明确的进程异常。
3. 所有链接指向已导出的文件，移动整个文件夹后仍可打开。
4. 明文凭据不进入报告、结构化快照或诊断附件。
5. 被排除的附件不会被标成采集失败；采集失败也不会被伪装成用户排除。
6. 人工停止、设备断线、异常退出均能生成部分报告，未执行项不会被默认为通过。
7. 重新运行只新增记录，不覆盖本次报告和失败证据。
