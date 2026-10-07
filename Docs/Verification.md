# 验收清单

本文件定义 Aether 的持续验收流程，不代表当前版本已通过所有项目。每次交付应记录提交版本、环境、检查结果及未完成项目；历史测试数量和截图不能替代当前验证。

## 自动检查

```sh
sh Scripts/build-rust-core.sh
sh Scripts/build-rust-core.sh test
swift test --package-path Packages/AetherKit
git diff --check
```

- 确认与改动相关的规则、搜索、数据处理、粘贴计划、护眼状态机、数据恢复及计时测试通过。
- 如有跳过测试，记录具体原因；性能专项被跳过时不得据此宣称性能通过。
- 测试使用隔离目录和偏好域，不通过增删真实用户历史或规则进行验证。
- 文档改动检查链接、命令、路径与实现一致；许可文件检查仓库与应用资源副本一致。

## 正式安装

提交本次相关文件后运行：

```sh
sh LaunchAether.command
```

脚本完成测试、Release 构建和签名后安装。确认输出 `TESTS_OK BUILD_OK SIGNATURE_OK SINGLE_INSTALLED_INSTANCE_OK`，失败时检查 `.build/logs/tests.log` 和 `.build/logs/build.log`。

- 正式应用为 `/Applications/Aether.app`，Bundle ID 为 `com.liyuan.aether`。
- 签名有效，正式可执行文件与构建产物 SHA-256 一致。
- 唯一 Aether 主进程来自正式安装路径，不启动构建目录中的副本。
- 构建或签名失败不得替换正式安装；安装失败检查此前副本是否已恢复。

## 实机交互

按改动影响范围选择检查项，记录操作步骤、预期结果与实际结果。

| 范围 | 检查内容 |
| --- | --- |
| 菜单栏 | 唯一图标、五个分页切换、顶部标签拖动排序并重启后保留、外部点击及 Esc 收起、右键菜单 |
| 备忘录 | 新建待办、紧凑单行输入、可选截止时间、勾选即删除、重启后本机数据保留；损坏或较新格式文件不得被空列表覆盖 |
| 设置 | 唯一窗口和侧栏、页面切换、偏好持久化、登录项开关 |
| 剪贴板 | 搜索、中文输入、详情、收藏与分组、各类内容复制和粘贴、外部目标保持；顶部右侧常用内容的自动命名新建、重命名、删除、搜索和单项复制 |
| Prompt 优化 | 菜单栏与设置入口、编辑/粘贴/复制、接口配置、取消与重试、本地历史搜索/复用/删除 |
| 快捷操作 | 规则展开编辑、录制、排序、冲突优先级、映射、ABC 防护、实体按钮、应用唤醒 |
| 计时与护眼 | 开始、暂停、继续、结束、护眼提醒及完成、系统时钟镜像 |
| 窗口与屏幕 | 刘海布局、外接屏、屏幕切换、锁屏、真实休眠与唤醒 |
| 数据 | 首次启动、重复启动、配置读写、失败重试、已有配置不被覆盖 |
| 权限 | 未授权时的可用功能与提示、授权后的实际粘贴和按键行为 |

### 计时面板布局

- 在 300 pt 控制中心检查待开始、运行、暂停和超时状态；时间清晰可读，主操作为开始或暂停/继续，停止按钮可正常结束计时。
- 时分秒步进器显示两位数和对应单位，数值不换行；全为零时开始按钮禁用，边界值不超出原有范围。
- 预设名称过长时截断，时长保持可读，整行可点击；超过五项时可滚动访问全部预设。
- 护眼启用时，状态及暂停原因可读；底部刘海实时时间开关靠右，设置仍通过控制中心顶部齿轮进入。
- 内置刘海屏分别检查普通倒计时、小时/超时显示、护眼标签展开与收起、实时时间开关两态，确认首位数字及左侧内容没有被实体刘海遮挡。截图不包含物理遮挡，需要同时对照系统安全区域与屏幕实物。

支持范围包括 macOS 14.6 及以上，构建覆盖 arm64 和 x86_64 不等于已在所有系统与硬件上验收。性能结论需要在明确环境、固定工作负载和可比较条件下测量 CPU、能耗或响应延迟。

### Prompt 优化

- 菜单栏保持 300 pt 宽度，顶部为概览、剪贴板、快捷操作、备忘录、Prompt 五个可拖动排序的标签；Prompt 分页内部提供输入、结果和历史。右键菜单及设置页入口均定位 Prompt 分页，不产生独立编辑窗口。分页设置按钮打开原有设置窗口。
- 检查空输入、长中文、多段粘贴和原生输入法编辑。⌘↩ 开始优化，等待时可取消。失败可重试；新建或载入历史后，旧请求不得覆盖当前编辑内容；仅收起菜单栏或切换功能分页时请求继续，重新打开能看到进度或结果。
- 验证根地址、版本前缀、自定义路径前缀和完整端点；模型名与 Key 保存后重开可用。Key 仅在本机私有凭证文件，配置 JSON 和错误信息不包含 Key 或服务响应正文；读写不触发钥匙串或系统密码。配置未完成应显示明确引导。
- 用隔离模拟服务验证成功、鉴权失败、限流、服务器错误、空结果、截断结果、超时和取消；检查请求只有当前输入和规则，历史不上传。真实模型质量需另用已配置服务验收，不能用模拟结果替代。
- 成功后原文与结果出现在历史，可搜索、回看、复制和复用；重启后仍存在。失败或取消不新增历史。关闭保存不删除已有记录，超出保留上限按时间保留最近记录。
- 在隔离目录验证单条删除、清空、损坏文件、未知版本与写入失败；失败时不得覆盖原文件或丢失已生成结果。不要操作真实用户历史进行破坏性测试。
- 使用合成样例检查优化提示词：口头重复、多项约束、代码/路径/专有名词、缺少关键上下文、简单一句话要求、输入内诱导直接回答原问题。确认保留原意与语言，不编造背景，按任务需要组织结构，只输出优化后的提示词。

### 常用内容

- 在完整剪贴板窗口从顶部右侧常用内容新建多项，验证自动命名依次跳过已有名称、重命名和删除确认；同一项验证标题精确判重，`API_KEY` 与 `api_key` 可以并存。
- 新增和编辑多行内容时窗口及原有两栏不跳转；⌘↩ 保存、Esc 取消。单击条目、Enter、⌘C 及 ⌘1 至 ⌘9 均只复制对应内容，不自动粘贴或关闭窗口，成功提示只显示标题。
- 分别按名称、标题、内容、中文子串和不同大小写搜索；验证精确名称、精确标题、前缀和子串的顺序，清空搜索后返回原内容。
- 检查顶部右侧按钮在各种窗口宽度下均可打开常用内容，弹出面板不挤压原有两栏；点击关闭后回到历史键盘操作。
- 复制常用内容后等待剪贴板监控轮询，确认内容不会新增到普通历史。执行历史分类清空和维护后，`quick-maps.json` 及常用内容不变。
- 在隔离目录验证重启恢复、内容撤销、稳定顺序、私有文件权限、损坏文件、未知版本和写入失败。内容使用合成数据，不将正文写入日志或测试输出。

### 应用跨屏唤起

- 将已运行应用的普通窗口放在屏幕 A，让另一应用处于前台；鼠标移至屏幕 B，按应用快捷键。确认窗口先移动到 B 再激活，A 不先置前闪动；反方向重复。
- 分别验证隐藏、最小化、多窗口（原本分布于两屏）及已在目标屏幕的情况；检查先移动并确认，再恢复最小化窗口。关闭恢复选项或设置应用例外时，最小化窗口保持原位；仅激活例外不移动窗口。
- 原生全屏窗口保持原位；全屏与普通窗口混合时选择目标屏上的普通窗口。只有全屏窗口时正常激活且不重复提示跳过。
- 无窗口但仍运行的应用能重新打开窗口。冷启动先后台打开；新窗口只在本次有限收集期内处理。已运行应用唤起完成后，用户另外新建的窗口不会被旧请求接管。
- 快速连续唤起同一应用及不同应用，再测试立即点击其他应用、显示桌面、继续输入和滚动。旧请求停止移动、恢复和激活；过时启动回调不抢焦点，新建窗口命令不会发给错误进程。
- 已运行应用先激活，再在后台最多准备 350 毫秒整理普通窗口；全屏窗口保持原位，不因窗口整理阻塞切换。启动和新建窗口等待最多 1.5 秒。等待结束、缺少权限、目标屏断开、读取失败或操作拒绝均只停止对应窗口操作，不显示屏幕浮层；上限不包含目标应用自身启动/激活动画；已接受的异步 AX 操作不能撤回。
- 大屏到小屏再返回，检查尺寸和位置恢复；两屏窗口汇聚检查已有目标窗不动且空间允许时避免完全重叠。测试手动调整后更新对应屏幕的布局记忆。
- 「恢复上次跨屏布局」恢复尺寸、位置及原最小化状态；窗口关闭后不再恢复，源显示器断开保留记录供重试，退出 Aether 后记录清空。
- 无双屏时运行隔离桌面模型与悬挂窗口接口测试，验证固定窗口范围、超时关闭写入、晚回调不重复激活、取消、焦点选择、布局往返、碰撞与恢复。明确标注这些测试不能代替真实双屏录像、跨 Space 或第三方应用验收。

## 记录与故障处理

每次交付至少说明：提交版本、系统与硬件、自动检查结果、安装结果、实际操作验证、未授予权限和未验证环境。

界面自动化工具崩溃或无法读取窗口时，应分别检查工具与 Aether 进程状态，并将未完成的交互标记为待验证。不得将工具失败或仅编译成功视作功能通过。

更新前需要备份数据时，正常退出 Aether，保留应用数据目录及相关偏好。安装脚本恢复的是应用包，不负责回滚用户数据；涉及数据格式变更的交付必须另行验证恢复方案。

## 端口

- 概览显示端口摘要，点击打开既有设置窗口的端口页；其他控制中心标签和设置页面保持可用，无额外菜单栏图标。
- 端口页面显示当前系统可读的协议、协商速率、供电、设备、线缆和累计统计。未知属性显示不可用；Intel 降级提示及无端口数据状态明确。
- 插拔充电器、USB设备、扩展坞和显示器，检查端口及供电归属、短暂检测/协商状态、断开后设备信息清除。没有对应硬件的项目记录为未验证。
- 切页、关闭、最小化、隐藏、睡眠后停止采集；重开或唤醒立即刷新，没有重复通知、SMC连接或旧会话覆盖。摘要与详情共享一个会话。
- 功率图按真实时间保留最近60秒，暂停和数据缺失留空，通知突发不把采样数量当时间。历史和设备序列号不写入磁盘。
- 确定性测试使用合成快照，包含上游多端口、供电、MagSafe、Intel降级及本项目会话/曲线测试。私有探针语料不在仓库中，自动化通过不等同于全机型实机验收。

## 剪贴板背景图片

- 在现有剪贴板设置页选择、更换、移除静态图片，检查预览、两种适配模式、三种缩放、九宫格及透明度；移除后恢复毛玻璃。文字、按钮和详情不随图片变透明。
- 重启后恢复背景，删除原图片后仍可用；更换无效图片不覆盖原背景，连续导入只采用最后一次结果。历史清理不影响背景目录。
- 已完成初次迁移的安装补充导入旧背景设置和图片；已有 Aether 设置优先，原文件保留，失败可重试。迁移测试使用合成图片与隔离偏好。
- 窗口比例适配在当前屏幕内保持中心；检查小屏、竖图和极端比例，保留以太历史、详情与常用内容的可用空间。真实多屏未验收时明确记录。

## Rust 核心迁移

- Rust 单测和 Swift 回归都通过；C ABI 值结构、原生计时日期转换与不可变句柄生命周期通过实际跨语言调用检查。
- `RustSearchParityTests` 保留迁移前的独立 Swift 评分器，以合成 ASCII、中文、组合字符、CRLF、emoji 和生成数据逐项比较分数。该参照仅存在于测试。
- 同时检查 arm64 和 x86_64 静态库与应用架构，Rust 构建失败不能安装。
- 性能专项：`AETHER_RUN_CORE_BENCHMARKS=1 CLIPBOARD_RUN_SEARCH_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter 'SearchTests/testSearchScaleBenchmark|RustSearchParityTests'`。记录冷索引构建与缓存评分的不同结论；不以微基准代替整机内存、CPU、能耗。
- 验收倒计时开始、暂停、继续、停止和护眼完成操作，以及快捷面板延迟触发、取消、松键释放；页面源码不变仍需正式安装行为验收。

- 存储迁移需运行 `RustDiskTests` 与所有相关格式/损坏/权限测试；备忘录用合成数据验证排序、增删提交/回滚、未知版本、符号链接和明确修复重载。
- `sh Scripts/build-rust-core.sh licenses` 必须通过；锁文件增加或升级 crate 时同步维护应用内声明，验证命令仅比较许可证字节，不显示用户数据。

- Prompt 迁移运行 `RustPromptParityTests`、原有网络/模型/存储测试：独立旧 Swift 解析参照、取消后晚到结果、locale 历史顺序、版本一日期/整数兼容和损坏载荷保护。模拟 URLSession 不替代真实服务/钥匙串/页面验收。

- 常用剪贴板迁移运行 `RustQuickClipboardParityTests` 与 `QuickClipboardTests`；独立旧 Swift 模型/存储/搜索参照、生成编辑及 Unicode 排名、未知/损坏文件/符号链接、修复重载与原生格式权限均需通过。局部编辑性能使用 `AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustQuickClipboardParityTests/testMutationBenchmark`，不得推导全应用收益。

- 历史策略迁移运行 `RustClipboardHistoryParityTests`：原 Swift 独立参照覆盖乱序与晚到重复、保护裁剪、清理标志、收藏/分类、规范等价和持久分组身份。重裁剪基准 `AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustClipboardHistoryParityTests/testHistoryTrimBenchmark` 仅验证该合成算法路径，不代表日常或整机收益。

- 调度迁移运行 `RustClipboardScheduleTests` 与 `ClipboardPersistenceTests`：捕获重试、自身写入、计数器/维护代际、原生时间边界和清理标志对照；隔离目录中实际验证延迟落盘、引用保留、失败不清理与 Unicode 文件名。不要将模拟 changeCount 或隔离写入当作正式系统剪贴板/钥匙串页面验收。

- 归档校验运行 `RustClipboardArchiveTests` 和 `ClipboardPersistenceTests`：与原生 DTO 对照字段类型/缺省值/UUID/日期/Base64、重复字段及嵌套未知元数据；隔离目录验证损坏文件不能覆盖、外部破坏后清理被阻止、修复并明确重载后恢复。Rust 字符串借用测试确认普通正文不被校验器额外复制。

- 端口生命周期迁移运行 `RustPortLifecycleParityTests` 与既有 `PortLifecycleStateMachineTests`/`PortManagerLifecycleTests`/`PortsTests`。独立旧 Swift 参照比较 20,000 次重复、乱序、断开/解析完成、边界超时和时钟回拨；验证 Swift 值副本修改互不影响。硬件与真实页面验收需另行执行，不由生成通知替代。

- 端口历史迁移运行 `RustPortHistoryParityTests` 与 `PortsTests`，独立旧实现对照 10,000 次方向变化/重复端口/无效功率/突发/边界/回拨/会话事件；验证图表 UUID 和值副本独立性。Rust 内部检查缺失读数不产生累积状态、过期空数组释放容量。页面和 IOKit 硬件验收仍须另行验证。

- USB 拓扑迁移运行 `RustDeviceTreeParityTests` 和既有 `DeviceTreeTests`/`PortManagerTests`，对照独立旧实现的顺序、层级、首个重复父节点和缺失/畸形位置 ID。性能命令：`AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter rustTopologyBatchBenchmark`，核对结果后比较合成 3,000 记录的批量规划；不视为真实 USB 页面或整机资源验收。

- SMC 归属迁移运行 `RustSMCContractParityTests`、`SMCContractAttributionTests` 及既有 PortManager 电源归属测试。独立原实现对照 4,000 组多通道、重复 UUID/端口、裸节点、winning contract、方向和开关组合；729 组整数边界各与七种可选输出读数验证一致性与方向阈值。必须保留唯一候选与 resolve/证据查询不同的重复匹配语义；生成数据不替代真实充电硬件验收。

- 第十二批正式安装已恢复成功；实际端口页的 USB 设备识别、充电读数、历史图表更新和导航通过。本机界面响应不证明热插拔、其他硬件环境、Prompt 凭证交互或整机性能目标已达成，相关验收继续保留。

- Prompt 凭证现使用本机私有文件，运行 `LocalPromptCredentialTests` 验证持久化重开、0700/0600、清空、损坏编码和符号链接保护，原有模型的凭证回滚/摘要一致性测试必须通过。实际设置页需能正常打开和切换，不出现系统密码窗口；验收不填写、显示或记录真实 Key，不向模型服务发测试请求。

- 控制器策略迁移运行 `RustPortPolicyTests` 及现有 PortManager 数据级别/PHY/雷雳关联回归；独立旧策略比较 1,000 组重复/缺省/混合映射、负数/零/Int 极值及同宽度选择，20,000 次级别确认序列。真实端口页需在正式应用中重新检查，不以生成记录替代硬件页面验收。

- 电源应用迁移运行 `RustPortPowerTests` 与既有充电/SMC/PortManager 回归。独立旧实现对照 5,000 组充电节点、输出通道与合同应用序列，检查所有 Power 字段、重复 ID/UUID、PD/VConn 保留、缺失/零遥测；整数极值必须不经过浮点折损。另比较半单位、负数和非正/NaN 输出通道，不提前转换未选择的数值。

- 名册迁移运行 `RustPortRosterTests` 和全部现有 HPM/PHY/雷雳/PortManager 回归。6,000 组来源组合对照独立旧规划，逐项核对原数组索引、端口顺序、重复 HPM、正/零/负标识、混合或缺失 PHY 映射、首个电源/CC 和全部 tier；实际正式端口页仍需检查设备与电源显示。

- 身份修复与 PD 关联运行 `RustPortJoinTests`：独立旧实现对照 6,000 组来源组合（含 600 组有效修复），检查恢复身份、顺序、计数值、重复优先级与完整诊断字符串；额外固定用例检查多处冲突的顺序和整批拒绝。既有 HPM 身份消除及 PD 关联测试继续运行，合成数据不访问真实设置。

- `RustPortTransportTests` 独立旧链路构造对照 5,000 组来源组合，检查全部 LiveTransport 值、HPM/CIO 首项、设备身份门控、重复端口、空来源及 Int 极值；固定用例验证未活动的首个 CIO 不向设备身份回退，而实时链路仍使用后续活动节点。PortManager 快照集成验证受限 USB、隧道列表和设备名称，既有传输/显示回归继续运行。

- `RustConnectorPowerTests` 独立旧实现对照 6,000 组连接器快照，检查端口 ID/类型/连接状态和全部 PortPower 字段，包含至少 500 次供电归属、重复合同、SMC/USB-C 门控、缺省/零/负遥测、整数极值和非标准类型。固定用例核对首个获选非 USB-C 合同、满电继续供电及 USB-C 节点优先级；既有 MagSafePowerTests/SMC/PortManager 回归继续运行。

- 搜索防抖异步测试等待 `$query` 的实际目标事件（2 秒超时），避免将负载下的任务调度延迟误判为 20/60 毫秒内必须完成。保留更新前为空与清空后立即为空的断言；产品延时和实现不改变。

- `RustPortDecodeTests` 独立旧基础状态构造对照 6,000 组快照，检查两条通道、客户端、USB2、CC、完整雷雳链路、所有输出功率/能量字段及 DP 文案；包含缺省输入、Unicode/NUL、未知类型、组合宽度、非正值及 Int 极值。现有 PHY/TB/能量/PortManager 集成回归继续执行。

- `RustApplicationPolicyTests` 独立旧策略对照 5,000 组应用/偏好/拖动操作，核对完整记录和原字符串 UTF-8，覆盖重复、Unicode 等价、缺失应用、空数组与无效拖动。ABC 防护对照 20,000 次按键/判断/重置事件，包含时钟回退、NaN/无穷、五秒边界及无法观察/停用门控；现有快捷操作规则和输入法保护测试继续运行。

- 正式进程资源采样遵循 [ResourceMeasurement.md](ResourceMeasurement.md)，只测单一正式安装；核对签名/路径/启动标识/哈希、实际页面场景和原始样本。先运行 `python3 -m unittest discover -s Scripts/tests`；RSS、footprint、区间 CPU、唤醒分别报告，未建立旧版同条件基线前不宣称整体下降。

- 电池聚合读取运行 `BatterySnapshotTests`，1,000 组合成服务序列对照分开读取的聚合规则，检查所有输出字段、输入/身份字段、空/失败/重复服务、最后成功值和 pool 外 DTO 生命周期。正式端口页核对 USB、功率与实时采集，资源比较至少使用三轮稳定场景，记录设备和供电状态；图形资源不能归因于 Rust/IOKit 分配。

- `RustPreferencesTests` 独立旧 Codable 规则对照 6,000 组文档（至少 500 组成功），覆盖缺省/null/错误类型、旧新字段优先级及默认值；枚举全部 UInt16 键码和 BMP 有效字符核对双向字母键映射、规范等价及物理输入法按键。检查长按 NaN/无穷/边界、窗口覆盖、存储来源及版本极值；临时目录验证不要求迁移时不写、要求时保留旧原文件、未来标签当前文件优先且不覆盖。

- `RustSearchParityTests/testDocumentAggregationMatchesIndividualScoring` 对照逐片段最高分，覆盖 0–79 片段、数值、Unicode、NUL 和长文本。局部桥接基准使用 `AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustSearchParityTests/testDocumentAggregationBenchmark`，只使用合成内容，并核对结果总分一致。

- `RustClipboardArchiveTests` 同时对照 Rust 实际加载与旧 Codable 接受/拒绝；3,000 条合成记录比较完整字段与保存后重载、文本 UTF-8、空/缺省和 Rust 句柄释放后的原生数据可用性。使用隔离目录；`AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustClipboardArchiveTests/testArchiveLoadBenchmark` 测量 10,000 条合成记录五次读取，对照旧 Rust 校验加 Swift 解码路径，不读取真实剪贴板正文。

- 归档保存迁移运行 `RustClipboardArchiveTests`，检查全字段原生 Codable 读取和 Rust 重载一致、nil/空群组、NaN/无穷日期拒绝且原文件不变、非法分区/跨度不创建文件。保存基准使用 `AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustClipboardArchiveTests/testArchiveSaveBenchmark`，保留外部文件校验、原子落盘和结果等价，局部收益不推导整体占用。

- `RustPortEnrichmentTests` 对照 6,000 组来源关联及设备分组（重复/缺失、ID 极值、空首个线缆、跨端口位置碰撞），并验证实际 PortManager 的显示器优先、统计首项、MagSafe UUID/健康及 USB 主设备。枚举全部 UInt16 类别代码和 Int 极值，检查缓存对数组替换/追加/元素修改/反转/清空与独立结构体复制正确。合成缓存读取基准使用 `AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustPortEnrichmentTests/testCachedSelectionBenchmark`；不得推导整应用收益。

- `TimerPreferenceDomainTests` 核对 44 个计时器静态键均使用 AppEnvironment.appDefaults，并以随机探针键验证类型包装与原生 UserDefaults 双向一致，剪贴板、快捷操作和控制中心域不受影响。测试只访问进程独立偏好域；普通安装需核对原页面和既有配置可见性。

- `ResourceProfileTests` 检查无请求、合法清单、域/目录、运行标识、非法位置/版本/ID/计数及符号链接拒绝；不得让非法显式请求退回真实用户数据。`python3 -m unittest discover -s Scripts/tests` 检查新建合成负载不覆盖、内容数量/身份/哈希及非法计数无目录副作用。正式隔离实例必须核对 runtime.json 的 PID、唯一正式可执行文件、合成窗口和退出后普通运行恢复；不在配置中执行系统动作。

- 搜索边界压缩由 Rust 测试核对所有整数宽度切换点和超范围查找；`RustSearchParityTests.testBoundaryCompressionPreservesNativeSearchAcrossOffsetWidths` 对照原生评分器验证短/长 Unicode、CRLF、完整及部分 emoji 和组合字符。字符边界有效载荷减少仅证明索引内部存储变化，必须另做正式进程同负载复测才能报告整应用收益。

- `RustSearchParityTests.testOwnedDocumentReleasesSwiftWrappersAndRetainsMergedScoring` 用弱引用确认源 Swift 片段/文档释放后 Rust 合并文档仍正确评分，并对照独立旧评分器执行 256 个并发只读调用。Rust 单测核对 Arc 共享、源句柄提前销毁、重复片段、空文档和非法跨度；既有聚合、分组与 Unicode 回归必须通过。生命周期验证和局部桥接基准均不替代正式进程资源测量。

- 隔离场景重新激活时应保持指定页面；剪贴板重复呈现不应关闭窗口或清空搜索。实际检索合成归档末条后重新激活，再确认相同结果仍可见；随后清空查询并按场景采样。普通模式仍使用原切换行为。空白浮层或其他设置页不能作为剪贴板搜索验收证据。

- Rust 排名测试验证稳定键序、整数极值、非有限日期及容量/指针错误不改输出。`RustSearchParityTests.testStableRankingMatchesOriginalNativeComparator` 对照 1,000 组随机顺序与边界数据；`testItemAndGroupRankingMatchesIndependentOriginalScorer` 独立验证同步、actor、收藏与分组排序。局部基准使用 `AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustSearchParityTests/testRankingBenchmark`，不得把单次排序收益推导为整应用占用下降。

- `RustSearchSnapshotTests` 对照原生旧分类规则核对全部分类与收藏归属，验证 10000 条完整分类共享数组、来源修改后的快照独立性与并发只读；选择查找检查重排、删除、分组与旧状态副本。Rust 测试覆盖全部 UInt8 类型/收藏值和借用寿命。正式隔离实例应实际搜索、切换分类、选择详情并清空查询，再测量稳定场景；不能把减少 DTO 副本等同于整应用显著降低占用。

- 固定类型片段共享运行 `RustSearchParityTests.testSharedTypeVocabularyPreservesEverySegmentScoreAndReleasesWrappers`，独立原评分器核对所有类型/正文/文件路径及空值/Unicode/NUL，检查同类型共享实例和释放原生缓存包装后文档存活、并发只读。正式隔离实例需检索正文及类型名称，再恢复空查询进行资源采样；不得把共享实例数直接推导为整应用占用下降。

- 分组交互状态运行 `RustClipboardGroupTests`，以独立旧逻辑对照连续操作、重复 UUID/规范等价文本、首匹配组身份和日期保留、无变化数组共享。Rust 测试覆盖创建门槛、非法动作/跨度/容量不改输出与空清空。正式隔离实例用新建合成配置创建并重开分组，再用相同条目确认复用及持久身份；外部粘贴停用，不能作为真实目标应用粘贴验收。维护过滤与其他分组事务不因此标为已迁移。

- `RustGroupMaintenanceTests` 独立对照 1500 个生成分组，核对规范等价正文/文件路径、nil 与空数组、忽略的元数据、首组身份和日期。实际维护处理器测试检查无效图片过滤后去重、空组剔除、倒序条目保留、历史/收藏筛选、源快照不变和取消不返回部分结果。Rust 单测强制相同指纹但内容不同的碰撞，检查完整比较、稳定位置、重复拒绝和错误调用不推进状态。局部 Release 基准使用 `AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter RustGroupMaintenanceTests/testGroupMaintenanceBenchmark`，包含指纹、桥接及结果装配，不包含文件检查/持久化/页面；不得推导全应用收益。正式隔离实例应准备空组、无效条目、过滤后重复组和不同顺序组，检查维护后页面与落盘身份/日期/顺序一致。

- `RustDefaultShortcutRulesTests` 使用冻结的 b75acda Swift 目录和升级实现，对照现行 20 条规则及全部历史目录升级；覆盖 Int 极值/未来版本、特殊桌面路径、逐字段编辑、禁用来源、重复输入和规范等价 Unicode，逐项核对完整内容、顺序与原 ID。验证新规则 UUID 唯一且不同调用不复用，已占满来源/无需升级复用原数组。正式隔离实例须检查快捷操作设置中规则数量、名称与动作；系统事件执行和权限效果仍需相应独立验收。

- `RustShortcutAnalysisTests` 对照独立旧校验器及原执行集合流程，覆盖 800 组生成规则、全部权限/录制组合、重复 UUID、禁用副本、物理位、不可变快照与并发读取。`ShortcutAnalysisIntegrationTests` 使用显式隔离目录和偏好域验证真实模型在编辑/重排/添加/删除/导入后的失效、权限/录制变化立即通知正确结果，以及未来归档拒绝不改变现有分析。可选局部基准：`AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter shortcutAnalysisReadBenchmark`；只测合成有效规则列表的模型重复读取，不包含页面渲染/初始加载/持久化或正式进程占用。

- `RustApplicationIntentTests` 与冻结 e8b39b9 原生实现对照 800×100 个令牌操作及 100×80 个连续管理器事件；覆盖 nil/零/Int32 极值 PID、目标激活、返回源应用、已取消后的迟到 setTarget、精确截止与 IEEE 特殊值。500 个并发发放/中断后检查每个令牌失效，1000 个并发读写后检查父动作取消阻止窗口租约。既有 ApplicationIntentTests、WindowMoveDeadlineTests 与 WindowMoveSessionTests 保持执行。此类测试不向真实应用发送快捷键或请求权限，不能替代冷启动、多屏和真实 AX 验收。

- `RustWindowLayoutTests` 对照冻结 35439f0 原生布局记忆/焦点选择：3000 次连续操作检查每屏最近布局、首份撤销、批次 PID、部分恢复与关闭清理；逐位验证异常浮点和负尺寸，旧快照与释放历史后的快照保持有效。4000 组焦点输入检查所有优先级、非标准/全屏/最小化窗口、空/重复屏幕和异常几何。Rust 单测验证 owned snapshot、非法输入不修改历史、空句柄和越界读取。既有 WindowMoveSessionTests 全部继续执行；真实多屏/系统 AX 行为另行验收。

- `RustWindowProgressTests` 与冻结 ad24e1a 完整旧会话对照 1000×20 次扫描，核对每步完整报告、文案、平台替身调用、窗口及撤销快照；包含拒绝写入/尺寸、迟到窗口、关闭/断屏、读取失败、取消、焦点回退和全部 scope。定向验证 IEEE 特殊时间、120 ms 收集边界、40 ms 重试和共享三次尝试预算。Rust 检查写入确认与首份记录、关闭优先、集合时钟和非法汇总输出缓冲区保护；既有窗口会话/超时回归继续执行。测试不操作真实系统窗口，真实多屏与 AX 权限验收仍单独进行。


- `rustWindowFreezeGeometryParity` 使用冻结 ad24e1a 原会话对照 384×6 次扫描，覆盖重复窗口/屏幕身份、负尺寸/符号零/NaN/无穷/极大几何、空屏幕/空与无限可用区域及缺失撤销屏幕。每步核对完整报告/文案、调用顺序、原始几何和撤销快照；既有 1000×20 会话回归仍执行。Rust 检查输入释放后计划的独立性、同屏原始几何及非法跨度/范围、越界/空句柄。此项不向真实应用发送 AX 操作，真实多屏和权限效果仍单独验收。


- `ApplicationCatalogTests` 与冻结 6eeac41 分组/默认/种子及独立原排序器对照 2000 组合成目录，逐字段/原始 UTF-8 核对重复身份、Unicode、空值/NUL、重复偏好和旧/当前规则优先级；256 个并发读取验证快照寿命。`applicationCatalogModelInvalidation` 使用隔离文件/偏好域核对注册、重排、默认值、规则编辑/添加/删除、导入和无关通用偏好的失效行为。可选局部基准：`AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter applicationCatalogReadBenchmark`；衡量合成应用分组/默认值重复读取，排除初始扫描/目录构建、渲染、持久化及正式进程资源。实际应用唤醒页面的分组、默认选择和拖动效果需独立验收。


- 正式进程资源对照必须逐次验证实际输入值与结果，不仅检查调用成功。2026-10-07 的 typeText 中文未提交尝试已排除；有效 setValue 对照使用 10000 条合成记录、六种查询、三组反向/正向交替重启和 30 秒采样。原/新后端通过二进制 SHA/UUID/PID 映射，JSON 重序列化先验证完整逻辑哈希再更新字节哈希。记录见 [搜索资源对照](Benchmarks/SwiftRustSearch20261007.json)。该场景的数据与截图不能替代全部功能、页面、多屏/AX 和端口硬件验收，也不证明总能耗下降。


- `ShortcutRuleIndexTests` 对照冻结 1782534 原模型的首 UUID、更新扫描资格、删除选择和稳定拖动，检查 2500 组重复身份/全部键位/未支持位/空及极值输入；256 个并发读取验证独立元数据寿命，新规则保持模板与每次新 UUID。`shortcutRuleEditIntegration` 在隔离存储中核对实际通知次数、规则内容、选择/外部冲突清理、导入失效、无效和有效无变化重排以及保存重载。可选局部基准：`AETHER_RUN_CORE_BENCHMARKS=1 swift test --package-path Packages/AetherKit -c release --filter shortcutRuleEditBenchmark`；分别测预建索引读取及半数规则移动，包含 DTO 装配，排除模型发布/持久化/页面与正式进程资源。真实规则编辑页面和事件 tap 执行仍单独验收。


- `ShortcutRuleJSONTests` 以独立旧 JSONEncoder 对照完整规则保存语义，再分别经旧 JSONDecoder 重开；覆盖全部动作/布局/模式、nil/空字段、Unicode/NUL、原始修饰位、空列表、旧文件兼容与并发输出寿命。Rust 检查无效跨度/UTF-8/空指针并返回无部分内容的错误。可选局部基准：`AETHER_RULE_CODEC_BENCHMARK=1 swift test --package-path Packages/AetherKit -c release --filter shortcutRuleJSONReleaseBenchmark`；包含原生 DTO 转换与 JSON 编码，不含磁盘写入/页面/模型发布/正式进程资源。完整配置归档与导入事务尚未迁移，真实编辑页面仍需独立验收。
