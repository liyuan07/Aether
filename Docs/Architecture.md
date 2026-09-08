# 架构与维护

## 模块职责

```text
Aether.app（生命周期、菜单栏、设置窗口、启动准备及登录项）
├─ TimerFeature → SharedSupport + Defaults + MacroVisionKit + SkyLightWindow
├─ ClipboardFeature → SharedSupport
└─ ShortcutsFeature → SharedSupport + ShortcutCore
```

`App/` 是唯一装配层，负责启动、停止和协调功能模块。各模块通过公开门面暴露生命周期及 SwiftUI 页面，内部实现保持 internal。`AppRouter` 传递 `AppRoute`，由应用层决定窗口行为。功能模块不互相导入，`SharedSupport` 不访问功能实现。

`TimerFeature` 管理计时、护眼、刘海和屏幕协调；`ClipboardFeature` 管理历史、搜索、详情与粘贴；`ShortcutsFeature` 管理事件监听、应用唤醒、按键映射和快捷面板；`ShortcutCore` 提供快捷键配置与规则模型。

## 存储与启动

`AppEnvironment` 在模块启动前确定路径与偏好域，测试可注入隔离配置。

| 数据 | 位置或偏好域 |
| --- | --- |
| 应用数据根目录 | `~/Library/Application Support/Aether/` |
| 剪贴板文件 | `Aether/Clipboard/` |
| 快捷操作配置 | `Aether/Shortcuts/` |
| 剪贴板偏好 | `com.liyuan.aether.clipboard` |
| 快捷操作偏好 | `com.liyuan.aether.shortcuts` |
| 计时及通用偏好 | 主应用域 `com.liyuan.aether` |

`StartupController` 完成本地数据准备后才启动功能模块，避免历史清理或事件监听与数据写入竞争。现有数据兼容处理集中在启动层及 `SharedSupport`，功能模块不承担外部数据识别。修改兼容处理前应检查已有数据与失败恢复路径。

`DataMigration` 使用复制、校验及同卷暂存目录移动；`copied` 阶段支持重试偏好导入，`complete` 阶段不再覆盖数据。无法识别的已有目标目录会停止处理，不得静默清空。后续格式升级同样需要明确版本、幂等行为及恢复策略。

Swift Package 测试进程默认使用临时根目录和随机偏好域。测试数据必须合成或脱敏，真实剪贴板内容不得进入日志、测试输出、截图或 Git。

## 窗口与输入协调

唯一菜单栏控制器负责紧凑面板，完整剪贴板窗口负责搜索、详情和粘贴协调。打开应用界面前保存外部应用作为操作目标，切换分页时不重新捕获目标。

应用层协调用户快捷键规则与剪贴板 Carbon 内置组合；冲突时不注册内置组合，保证自定义动作优先。打开 Aether 功能的动作应交给内部路由，避免启动额外应用进程。

计时布局与屏幕协调由 `TimerRuntime` 管理。模块内的控制窗口辅助代码受 `timerControlWindowEnabled = false` 禁用；更改窗口入口时需要同时检查 Live Activity 行为。菜单栏面板问题应在对应控制器中解决。

## 设置

应用层持有唯一侧栏，页面标题共用 `SharedSupport.SettingsContent`。剪贴板使用原生 Form 设置行；快捷操作通过顶部分段选择器切换按键与面板、应用唤醒和快捷键。规则在同一列表中展开编辑，同时仅展开一条，不嵌入另一套设置侧栏或独立对话框。配置导入导出位于快捷操作配置区，启动数据准备失败通过通用页重试。

## 计时准确性

手动倒计时通过 `ContinuousClock` 和 `ManualCountdown` 的截止时间计算剩余时长。1 Hz 回调只刷新显示，不逐次累减；暂停保存精确剩余值，恢复重新建立截止时间。唤醒立即重新采样，UI 回调延迟与系统休眠不会丢失时间。零值、负数、非有限时长不会中断现有计时。应用退出后手动计时结束，重开为空闲；系统镜像按当前系统状态重新发现。

## 变更与验证

依赖版本在包清单与 `Package.resolved` 中固定，应用构建与模块测试使用仓库内配置。调整依赖、公共接口或数据格式时，同步检查调用方与兼容路径。

测试覆盖快捷键规则、剪贴板搜索与数据处理、粘贴计划、护眼状态机、数据恢复、导航与连续时间倒计时。自动粘贴、权限及屏幕布局必须在正式安装副本中验收，详见[验收清单](Verification.md)。
