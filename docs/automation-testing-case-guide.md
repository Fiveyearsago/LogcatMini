# Logcat Mini 自动化测试用例配置说明

状态：第一版设计草案。日期：2026-10-13。

本文定义 QA 如何配置可执行用例，以及未来导入导出文件应表达的信息。示例使用虚构应用 com.example.qaapp，不是已经存在的测试程序，也不能直接交给 Maestro 执行。首版入口和执行规则见[总体方案](automation-testing-v1-plan.md)。

## 1 配置对象

| 对象 | 内容 | 保存方式 |
| --- | --- | --- |
| 应用配置 | 应用名称、包名、环境说明、常用用例集 | 本机配置，可导出不含敏感信息的部分 |
| 环境配置 | 环境标签、账号引用、语言、前置说明、可选环境检查 | 本机保存；标签本身不改变 App 后端地址 |
| 用例集 | 名称、修订号、适用包名、变量、用例与顺序 | 可导入导出的 JSON |
| 单条用例 | 编号、目的、前置条件、步骤、断言、收尾与超时 | 随用例集保存修订 |
| 测试任务 | APK、具体设备、所选用例、数据策略、证据选项 | 每次执行前冻结快照 |
| 运行结果 | 每步实际状态、证据、错误分类、最终统计 | 不因后续编辑用例而改变 |

日常操作以表单为主。导出文件用于团队交换与版本管理；不要求 QA 编写 JSON。第一版只导入本格式，暂不导入任意 Maestro YAML、Excel、自然语言用例或外部脚本。

## 2 QA 创建用例的步骤

1. 在用例库选择应用，点击“新建用例”，填写要验证的需求和用例名称。
2. 填写前置条件，例如已经登录、账号没有领取当天奖励、环境为测试服。
3. 连接设备，手动进入目标页面，点击“读取当前页面控件”，选择按钮或输入框填入步骤目标。
4. 为步骤选择动作。填写点击目标、输入文本、等待时间或预期结果。
5. 至少添加一条结果检查。仅记录点击过程的流程不能作为正式验收用例。
6. 为关键检查点添加截图，必要时配置日志断言。
7. 配置收尾步骤，使下次运行能够从明确状态开始。
8. 点击“检查配置”，修正缺失字段后试跑，确认截图、预期与实际值正确对应。
9. 保存到用例集。换 APK 回归时复用该用例，页面发生变化时修改并产生新修订。

“读取控件”和“检查配置”不会自动点击目标 App。“试跑”会真实操作设备，使用与正式任务相同的设备锁定、数据策略和证据保存规则。

## 3 用例字段

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| 用例编号 id | 是 | 用例集内唯一，如 SETTINGS-001；只允许字母、数字、短横线与下划线 |
| 名称 name | 是 | 描述可验证结果，例如“修改语言后重启仍保留” |
| 关联需求 requirement | 是 | 需求编号或简述；用于报告说明范围，不自动产生断言 |
| 优先级 priority | 是 | P0 核心流程、P1 常规回归、P2 次要或边界；不自动等同缺陷严重度 |
| 标签 tags | 否 | 登录、设置、回归等，用于筛选 |
| 适用说明 applicability | 否 | 适用版本、语言、账号和已知限制；关键条件仍须写入可执行前置检查 |
| 起始策略 startPolicy | 是 | restart 为重启保留数据；clearAndRestart 为显式清数据后重启 |
| 用例超时 timeoutMs | 是 | 默认 180000，首版最大 600000 |
| 前置说明 preconditionNotes | 是 | 需要人工提前完成的账号、服务端状态和环境准备 |
| 前置检查 preconditions | 否 | 只读可观测检查；失败记阻塞 |
| 测试步骤 steps | 是 | 有固定步骤 ID 的有序列表，至少包含一个结果断言 |
| 收尾步骤 cleanup | 否 | 正常完成或可控断言失败后恢复明确状态；不支持任意脚本 |

前置条件分为“说明”和“可执行检查”。“账号余额为 100”如果只有说明，报告必须表明是人工准备状态；只有 UI 或其他受支持信号确实检查过，才能写成自动验证通过。

需要多个用例共享登录等流程时，首版可复制步骤。子流程、跨用例依赖与条件分支暂不进入导入格式，避免首版出现隐藏依赖。

## 4 首版动作与断言

| 类型 | 动作名 | 表单字段 | 成功含义 |
| --- | --- | --- | --- |
| 启动 | launchApp | 默认目标包、超时 | 发出启动且目标应用进入前台；首页内容另行断言 |
| 重启 | restartApp | 默认目标包、超时 | 强制停止后启动，保留数据；不隐式清缓存或数据 |
| 点击 | tap | 目标、超时 | 在唯一目标上执行一次点击，不代表业务完成 |
| 输入 | inputText | 目标、文本或变量、是否清空 | 在已定位输入框中输入；重要内容须再检查 |
| 滑动 | swipe | 上下左右方向、次数、持续时间 | 完成指定次数滑动；首版最多 5 次，不做无限查找 |
| 按键 | pressKey | Back、Home、Enter | 执行允许的系统按键 |
| 等待 | waitVisible | 目标、超时 | 目标在期限内可见；作为同步步骤，不替代业务断言 |
| 可见检查 | assertVisible | 目标、超时 | 预期元素在期限内可见 |
| 不可见检查 | assertNotVisible | 目标、观察时长 | 在完整观察窗口内不可见；不是瞬时检查 |
| 文本检查 | assertText | 元素目标、预期文本、匹配模式、超时 | 唯一元素的文字满足规则 |
| 前台检查 | assertForeground | 默认目标包、超时 | 目标 App 是当前前台应用 |
| 日志出现 | assertLog | Tag、内容规则、起始步骤、超时 | 可靠采集窗口内至少一条匹配 |
| 日志不出现 | assertNoLog | Tag、内容规则、起始步骤、观察时长 | 完整可靠窗口内没有匹配 |
| 截图 | screenshot | 文件标签 | 在当前设备成功保存截图及时间 |

每步保存 id、name、action 和适用参数；不属于该动作的字段应报配置错误。超时单位在界面显示为秒，文件统一毫秒。

异常的“Error 日志”不默认对应 assertNoLog。只有需求明确要求某种业务失败事件不能出现时，才配置有明确 Tag 与内容的排除规则。

首版不提供固定坐标点击、任意 shell、运行 JavaScript、无限循环、外部网络请求或 AI 判断通过的动作。无法通过当前动作覆盖的场景列为未覆盖，不用没有结果验证的点击串代替。

## 5 目标定位规则

优先使用稳定的 resource ID，其次使用可访问性描述或明确文字。同一目标可以组合 ID、文字、描述，组合关系为“并且”。

| 目标字段 | 示例 | 规则 |
| --- | --- | --- |
| id | com.example.qaapp:id/settings_button | 完整 ID，按字面量精确匹配 |
| text | 领取奖励 | 默认精确匹配；可显式选择包含或正则 |
| contentDescription | 打开设置 | 默认精确匹配 |
| match | exact、contains、regex | 适用于文本规则；不得把普通标点当作正则 |

不自动在多个候选之间猜选。读取控件时显示候选数；执行时如果点击目标仍不唯一，停止该用例并说明“目标不唯一”。建议补充 ID 或文字组合。首版不支持用候选顺序编号来掩盖不稳定定位。

执行适配器需要验证是否能可靠获得候选数；若候选检查不可用，相关动作不应被声明为已满足此规则。自绘 Canvas、部分游戏、不可访问的 WebView 与安全窗口可能无法定位或截图，应在试点阶段确认。

测试默认记录运行前的屏幕尺寸、方向和语言。用例定位依赖某种语言时，明确声明并检查；不能在找不到中文按钮时擅自切换语言或猜英文按钮。

## 6 变量与凭据

变量名使用英文字母、数字和下划线，配置文件里的引用统一写成 {{variable_name}}。解析只做有类型的值替换，不运行表达式。

| 类型 | 例子 | 处理方式 |
| --- | --- | --- |
| 普通字符串 | expected_language = English | 可进入快照和报告 |
| 数值预期 | expected_balance = 200 | 首版按页面预期文字检查，不自动计算余额差 |
| 敏感输入 | login_password | 本机凭据存储中的引用，界面遮罩 |
| 环境说明 | environment_name = 测试服 | 用于显示；不自动改写应用接口地址 |

运行时允许覆盖变量，但必须在开始前展示最终非敏感值。缺失变量阻止开始。普通文本替换进入引擎时做正确转义，不把 {{name}} 的内容当代码、正则或命令。

凭据不写入用例导出、命令行可见参数、报告和运行诊断。适配器在实现时验证凭据注入和引擎日志行为；无法避免明文落盘的动作不能默认支持敏感输入。截图仍可能记录输入框内容，因此敏感步骤的截图策略要单独选择。

## 7 完整用例配置示例

以下 JSON 表达计划中的第一版格式。它描述虚构应用的自动保存语言设置：初始为中文，选择 English 后自动保存，重启后仍是 English，结束时恢复中文。实际开发需补充正式 JSON Schema 与执行适配器。

~~~json
{
  "schemaVersion": 1,
  "suiteId": "qaapp-core",
  "name": "示例应用核心回归",
  "revision": 1,
  "app": {
    "packageName": "com.example.qaapp"
  },
  "variables": {
    "expected_language": {
      "type": "string",
      "default": "English",
      "sensitive": false
    }
  },
  "cases": [
    {
      "id": "SETTINGS-001",
      "name": "修改语言后重启仍保留",
      "requirement": "REQ-SETTINGS-01 语言设置应在重新启动后保留",
      "priority": "P1",
      "tags": ["设置", "回归"],
      "startPolicy": "restart",
      "timeoutMs": 180000,
      "preconditionNotes": "测试账号已登录，应用可进入首页，初始语言为简体中文",
      "preconditions": [
        {
          "id": "pre-home",
          "name": "确认首页可见",
          "action": "assertVisible",
          "target": {"id": "com.example.qaapp:id/home_root"},
          "timeoutMs": 10000
        },
        {
          "id": "pre-language",
          "name": "确认首页初始语言",
          "action": "assertVisible",
          "target": {"id": "com.example.qaapp:id/home_title", "text": "首页"},
          "timeoutMs": 10000
        }
      ],
      "steps": [
        {
          "id": "open-settings",
          "name": "进入设置",
          "action": "tap",
          "target": {"id": "com.example.qaapp:id/settings_button"},
          "timeoutMs": 10000
        },
        {
          "id": "open-language",
          "name": "打开语言选择",
          "action": "tap",
          "target": {"id": "com.example.qaapp:id/language_row"},
          "timeoutMs": 10000
        },
        {
          "id": "set-english",
          "name": "选择 English",
          "action": "tap",
          "target": {"text": "{{expected_language}}"},
          "timeoutMs": 10000
        },
        {
          "id": "check-saved",
          "name": "确认当前语言",
          "action": "assertText",
          "target": {"id": "com.example.qaapp:id/language_value"},
          "expected": "{{expected_language}}",
          "match": "exact",
          "timeoutMs": 10000
        },
        {
          "id": "restart",
          "name": "重启应用",
          "action": "restartApp",
          "timeoutMs": 30000
        },
        {
          "id": "open-settings-again",
          "name": "重新进入设置",
          "action": "tap",
          "target": {"id": "com.example.qaapp:id/settings_button"},
          "timeoutMs": 10000
        },
        {
          "id": "check-persisted",
          "name": "确认重启后语言保留",
          "action": "assertText",
          "target": {"id": "com.example.qaapp:id/language_value"},
          "expected": "{{expected_language}}",
          "match": "exact",
          "timeoutMs": 10000
        },
        {
          "id": "capture-result",
          "name": "保存结果截图",
          "action": "screenshot",
          "label": "language-after-restart"
        }
      ],
      "cleanup": [
        {
          "id": "cleanup-restart",
          "name": "从首页恢复",
          "action": "restartApp",
          "timeoutMs": 30000
        },
        {
          "id": "cleanup-settings",
          "name": "进入设置",
          "action": "tap",
          "target": {"id": "com.example.qaapp:id/settings_button"},
          "timeoutMs": 10000
        },
        {
          "id": "cleanup-language",
          "name": "打开语言选择",
          "action": "tap",
          "target": {"id": "com.example.qaapp:id/language_row"},
          "timeoutMs": 10000
        },
        {
          "id": "cleanup-chinese",
          "name": "恢复中文",
          "action": "tap",
          "target": {"text": "简体中文"},
          "timeoutMs": 10000
        },
        {
          "id": "cleanup-check",
          "name": "确认已恢复",
          "action": "assertText",
          "target": {"id": "com.example.qaapp:id/language_value"},
          "expected": "简体中文",
          "match": "exact",
          "timeoutMs": 10000
        }
      ]
    }
  ]
}
~~~

本例中的收尾只恢复已知的初始语言，不承诺还原整个 App 数据。已配置收尾是用例完成的必需条件：主体已失败时仍记失败；主体满足而收尾失败时记阻塞。手动停止、断线或未知执行状态下不会继续收尾，而是在报告显示未恢复。

## 8 日志断言示例

若目标 App 确实输出约定日志，可在“选择 English”之后加入以下步骤。这个例子的 Tag 和事件内容同样是虚构约定：

~~~json
{
  "id": "check-save-event",
  "name": "确认设置保存事件",
  "action": "assertLog",
  "tag": "QA.Settings",
  "content": "event=settings_saved language=en",
  "match": "contains",
  "sinceStep": "set-english",
  "timeoutMs": 10000
}
~~~

sinceStep 指向当前用例中已经执行的步骤，从该步动作开始前建立的采集游标计起。匹配范围限定为当前设备、目标应用及这一时间窗。首版日志规则支持纯文本包含或显式正则，不提供任意 JSONPath、数学计算或服务端查询。

适配器在触发 set-english 前必须建立窗口，而不是等 UI 流程结束才开始采集。命中后保存原始日志引用、匹配文字与接收时间；采集完整但到期未命中为失败，采集中断或来源不可靠为阻塞。

“设置保存事件”只能证明相应客户端日志出现。实际持久化仍需通过重启后的 UI 检查。服务端记账、实际埋点到达后台等需要额外证据，首版不据此推断。

## 9 建议内置的用例模板

| 模板 | 默认步骤 | 必须由使用者补充 |
| --- | --- | --- |
| 基础启动检查 | 启动、检查目标 App 前台、保存截图、观察异常事件 | 可选首页标识；未配置时只能证明进入前台 |
| 页面导航 | 进入首页、点击入口、检查页面标识、返回 | 入口与页面目标 |
| 设置持久化 | 改设置、检查值、重启、再检查、恢复 | 设置控件、初始与目标值 |
| 表单校验 | 输入错误内容、提交、检查提示 | 输入框、输入内容、提交按钮、错误提示 |
| 核心业务路径 | 前置检查、操作、UI 结果检查、可选日志检查 | 账号状态、具体步骤、期望结果与可观测范围 |

模板创建后保存为草稿。未补齐字段时不能直接开始正式测试。只有基础启动模板可以仅凭已解析 APK 建立最小检查；报告必须保留其覆盖范围。

## 10 导入和修订规则

schemaVersion 不支持时拒绝导入并显示支持版本。校验包名、必填字段、ID 唯一性、变量引用、动作白名单、超时范围和日志窗口引用。文件不能引用本机任意路径或外部脚本。

同一 suiteId 导入时先展示修订和差异，由使用者选择新增修订或作为副本；不静默覆盖本机版本。首版只支持一个 JSON 文件中的自包含用例集，减少依赖丢失。

运行只使用已保存、校验通过的快照。试跑与正式运行使用相同校验规则。旧运行结果始终引用原始快照及其校验值，后续修改步骤名称也不能改写旧报告。
