# 架构与维护

## 依赖方向

```text
Aether.app（唯一生命周期、菜单栏、设置窗口、迁移及登录项）
├─ TimerFeature → SharedSupport + Defaults + MacroVisionKit + SkyLightWindow
├─ ClipboardFeature → SharedSupport
└─ ShortcutsFeature → SharedSupport + ShortcutCore
```

功能模块不互相导入。各模块通过公开 facade 暴露生命周期及 SwiftUI 页面；内部类型保持 internal。`AppRouter` 传递 `AppRoute`，由应用装配层决定窗口行为。SharedSupport 不访问功能实现。

## 存储

`AppEnvironment` 在任何模块启动前确定路径与偏好域；可以在测试中注入。剪贴板使用 Aether/Clipboard 和 com.liyuan.aether.clipboard；快捷操作使用 Aether/Shortcuts 和 com.liyuan.aether.shortcuts；计时的 Defaults 键位于主应用偏好域，以保持原序列化格式。唯一登录设置位于主应用域。

Swift Package 测试进程默认使用临时根目录和随机偏好域；剪贴板内容不得加入日志、测试输出、截图或 Git。迁移前还没有启动历史清理或事件监听器，避免读取暂存数据或造成竞争。

`DataMigration` 先复制并校验，再同卷移动暂存目录。`copied` 阶段表示可以重试偏好导入，`complete` 表示后续启动不再覆盖。无法识别的已有目标目录会停止迁移，绝不静默清空。

## 窗口和快捷键

唯一菜单栏控制器负责紧凑面板。完整剪贴板窗口复用原来的搜索、详情和粘贴协调器。打开本应用界面前保存外部应用；分页操作不重新获取粘贴目标。

快捷操作保留原事件引擎、物理按键识别、应用启动器与提示面板。应用层将启用的用户规则与剪贴板 Carbon 内置组合协调；冲突时不注册内置组合，保证自定义动作优先。旧 Clipboard 应用动作在执行层转为内部路由，不启动独立旧进程。

计时窗口布局与屏幕协调由 TimerRuntime 保留；原菜单栏及独立交互面板已移除。原 Live Activity 引用的控制窗口辅助代码仍留在模块内，入口被既有 `timerControlWindowEnabled = false` 禁用，以保持关闭态行为。不要通过改写刘海布局解决菜单栏面板问题。

## 检查

设置由应用层持有唯一侧栏，页面标题共用 SharedSupport.SettingsContent。剪贴板使用原生 Form 设置行；快捷操作以顶部分段选择器切换按键与面板、应用唤醒和快捷键。规则在同一列表内展开编辑，同时仅展开一条，不嵌入另一套设置侧栏或独立对话框。导入导出位于快捷操作配置区，首次迁移失败通过通用页重试；来源与许可保留在仓库及应用资源中。

测试覆盖原 ShortcutCore、剪贴板搜索/数据/详情/粘贴计划、护眼状态机，及迁移失败、恢复和导航。版本依赖固定在 Package.resolved。实际自动粘贴、系统权限、屏幕布局必须在正式安装副本中验收，不能仅凭单元测试宣称可用。

## 计时准确性

手动倒计时通过 ContinuousClock 和 ManualCountdown 的截止时间计算剩余时长。1 Hz 回调只刷新显示，不逐次累减；暂停保存精确剩余值，恢复重新建立截止时间。唤醒立即重新采样，UI 回调延迟与系统休眠不会丢失时间。零值、负数、非有限时长不会中断现有计时。应用退出后手动计时结束，重开为空闲；系统镜像按当前系统状态重新发现。
