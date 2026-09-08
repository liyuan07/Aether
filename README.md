# Aether · 以太

原生 macOS 菜单栏效率工具，将倒计时与护眼、剪贴板、快捷操作整合在一个应用中。完整功能在本机运行，不提供账号、云同步或剪贴板上传。

## 使用

运行 `sh LaunchAether.command`。脚本测试、构建 Release、签名并更新 `/Applications/Aether.app`；正式 Bundle ID 为 `com.liyuan.aether`。需要 macOS 14.6+、Xcode/Swift 6.2+，本地签名默认使用 `Ice Local Code Signing`，可通过 `AETHER_SIGNING_IDENTITY` 指定已有身份。

- 左键菜单栏叠片图标：概览、剪贴板、快捷操作；点击外部或 Esc 收起。
- ⇧⌘J：完整剪贴板窗口；自定义同组合动作优先，冲突在设置中说明。
- 右键：控制中心、设置、重新启动、退出。
- 刘海延续原计时显示；不通过刘海打开面板。
- 新身份需要单独授予辅助功能、输入监控权限。未授权时保留本地计时与剪贴板记录/复制；自动粘贴和全局映射依赖权限。

## 工程

在 Xcode 中打开 `Aether.xcodeproj`，选 `Aether` scheme。应用装配在 `App`；独立模块和测试在 `Packages/AetherKit`。详见 [架构说明](Docs/Architecture.md)。

```sh
swift test --package-path Packages/AetherKit
sh LaunchAether.command
```

应用与 Swift Package 使用仓库内锁定的依赖，安装日志在 `.build/logs`。首轮依赖获取需要网络，应用运行不依赖来源项目目录。不要直接运行 `.build` 内的应用，以免注册重复菜单栏入口。

## 迁移与回退

首次启动先检查旧应用是否仍在运行。请完成或停止旧倒计时/护眼，再正常退出旧应用；点击继续迁移。旧应用的内存中活动计时不会被复制。

剪贴板归档与图片/载荷、快捷键及应用配置、偏好复制到 `~/Library/Application Support/Aether/`。迁移使用同卷暂存、校验、原子目录移动与版本标记。原目录不删除，已完成的迁移不覆盖再次使用后产生的数据。

在 Aether 验证可用后，于系统登录项中移除 Clipboard、KeyPilot、package counter 的旧启动记录，并在旧应用设置中关闭登录启动，防止重新打开旧应用后再次注册。首次迁移默认保留任一旧应用开启登录启动的意图；三个均关闭则关闭。

回退时正常退出 Aether，在 Aether 通用设置关闭登录启动，再打开旧应用并恢复需要的旧登录项。旧数据独立保留；回退不会自动将 Aether 后续新增历史合并回旧应用。安装更新失败时安装脚本自动恢复此前的 Aether 正式副本。

## 来源与许可

来源版本见 [Sources.json](Docs/Sources.json)。本项目保留 Atoll/boring.notch、Clipboard 与 KeyPilot 的相关版权；整体以 GPL-3.0-or-later 发布，见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。目前只维护本地 Git，不发布远程仓库或 Release。
