# 正式进程资源测量

`python3 Scripts/measure-installed-resources.py` 只读取 `/Applications/Aether.app/Contents/MacOS/Aether` 的聚合进程计数，不启动应用、不读取用户历史或 API Key、不更改设置。工具验证签名、唯一 Aether 进程、可执行路径、进程启动标识、运行映像与产物 Mach-O UUID 和安装二进制 SHA-256；任意变化会拒绝输出有效结果。已有结果文件不覆盖。

```sh
python3 Scripts/measure-installed-resources.py --scenario settings-closed --duration 30 --output .build/benchmarks/settings-closed.json
python3 Scripts/measure-installed-resources.py --scenario general-visible --duration 30 --output .build/benchmarks/general.json
python3 Scripts/measure-installed-resources.py --scenario ports-visible --duration 30 --output .build/benchmarks/ports.json
python3 Scripts/measure-installed-resources.py --scenario general-after-ports --duration 30 --output .build/benchmarks/after-ports.json
python3 Scripts/measure-installed-resources.py --scenario clipboard-visible --duration 30 --output .build/benchmarks/clipboard.json
```

每条命令前通过原生界面准备对应场景，并核对页面；scenario 是操作者标签，脚本不会观察或控制页面。测量期间维持页面、设备连接和设置稳定，避免输入/搜索、硬件热插拔及其他主动工作；至少记录三轮并比较中位值。首次打开页面、暖缓存及返回后的保留内存分别测量，不混作冷启动。不同用户数据量、系统压力、设备和授权环境的结果不可直接比较。

采样辅助程序由本机 SDK 编译，使用 `proc_pid_rusage(RUSAGE_INFO_V4)`，结构直接来自系统头文件。记录 RSS、physical footprint、累计 CPU、唤醒和磁盘字节数，以及每次读取耗时；不采集进程地址空间或正文。CPU 为两次累计 user+system 差值乘以本机 Mach timebase，除以真实采样间隔，单核 100%，并行可超过 100%。不是 `ps %cpu` 的整个进程生命周期平均。RSS 与 footprint 口径不同，不能互相替代；唤醒计数不是整机电量或能耗。

计数含义核对 [Apple XNU 进程资源填充](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) 与 [task power 时间计数实现](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)：user/system 来自 Mach 时间统计，physical footprint 来自任务 ledger。保留原始 Mach 计数及 numer/denom，避免将其直接当纳秒。这里只报告进程资源，不能等同于整机能耗。旧 Swift 的隔离/呈现适配已有单次正式进程对照，尚未建立足够的交替多轮证据；不能据此宣称 Rust 显著降低整应用占用。

工具验证：`python3 -m unittest discover -s Scripts/tests` 检查 Mach 换算、双模式 CPU、并行超过 100%、内存汇总及无效区间；辅助程序对零/无效 PID 和非正式进程拒绝读取。真实采样仍须核对进程与场景。原始 JSON 保存在 `.build/benchmarks`，记录提交、工作区状态、架构、macOS、产物哈希和全部样本，不提交真实环境数据。

## 固定负载的隔离准备

通用与计时偏好已统一经 AppEnvironment.appDefaults 注入；正常安装仍为原标准域，单元测试为独立域。44 个静态计时键和 AppStorage 已显式绑定，避免偏好注入后仍读写真实配置。当前正式产物的隔离模式已通过 10000 条合成归档加载与末条搜索验收；旧 Swift 的启动、偏好、系统动作和呈现隔离已单独适配并记录来源，但其单次对照不代表完整基线或全功能验收。适配与原始证据位于 `.build/baselines/swift-profile-adapter-v2.json` 和 `.build/benchmarks/296df46-swift-v2-rust-comparison.json`。

## 显式隔离配置

`python3 Scripts/create-resource-profile.py --clipboard-items 10000` 创建新的 `.build/resource-profiles/UUID/profile.json` 和合成归档、字段数/内容哈希记录，不读取或复制真实数据。0 条为默认空负载，支持至 100000 条。每次运行独立偏好域重置为固定值；从正式可执行文件启动时显式设置 `AETHER_RESOURCE_PROFILE` 为清单绝对路径，`--resource-scene` 接受 `settings-closed`、`general-visible`、`ports-visible`、`clipboard-visible`。仍必须先退出已有实例，不能运行构建目录副本。

配置跳过迁移、登录项动作及快捷键执行，禁止向外部应用粘贴和监控系统计时器；剪贴板保持原频率读取私有板，端口仍采样硬件。它衡量同配置下的固定场景差异，不能代替正常服务、权限或完整页面验收。`runtime.json` 记录就绪 PID 和清单 ID，应与实时唯一正式进程核对；状态文件本身不是存活证明。测量后退出配置实例并恢复普通正式启动。旧 Swift 基线需要相同适配才能运行比较，不可直接启动未适配产物。

显式场景在隔离模式重新打开应用时再次呈现；剪贴板采用幂等呈现而非显示/隐藏切换，现有窗口及搜索状态保留。普通模式的重新打开行为保持原样。比较旧 Swift 与新产物时，两边应使用相同呈现适配，且每轮采样前仍需检查实际页面；不能以启动参数代替页面证据。

隔离采样时另传 `--profile /绝对仓库路径/.build/resource-profiles/UUID/profile.json`。工具只接受此显式目录，拒绝相关路径上的符号链接，并在采样前后核对清单、就绪记录 PID、条数及实际合成归档 SHA-256，输出 `synthetic_profile` 元数据。归档被修改、就绪记录属于其他进程或负载不一致时不输出测量结果。未传此参数时不读取任何历史文件，元数据为 null。此核对证明记录与负载一致；操作者仍须确认启动环境及实际页面，不能仅凭就绪文件证明隔离模式或页面状态。

## 固定类型片段共享的三组对照（2026-10-07）

比较共享前 `3a7fcb6` 与共享后 `22bd985`，两者均为 Rust 接入版本，不能当作原 Swift 到 Rust 的总收益。使用同一 10000 条合成文本归档、正式安装路径、剪贴板全部分类；每次独立启动后依次搜索“文本”“9999”、清空，再点击搜索框移开行悬停。每轮实际核对首条结果和详情，之后固定预热 15 秒、采样 30 秒。运行顺序 B1/A1/A2/B2/B3/A3，B 为共享后版本。每轮核对签名、唯一正式 PID、运行映像、安装哈希及归档字节/语义哈希；全部采样期间磁盘读写增量为零。

| 配对轮次 | 共享前 footprint 中位数 | 共享后 footprint 中位数 |
| --- | --- | --- |
| 1 | 42.13 MiB | 41.88 MiB |
| 2 | 45.22 MiB | 42.08 MiB |
| 3 | 43.36 MiB | 41.69 MiB |
| 启动间中位数 | 43.36 MiB | 41.88 MiB |

本机该场景的启动间中位数低约 1.48 MiB（3.4%），三个配对均为共享后较低；仍只有每版本三次启动，不能作为统计显著性、所有负载或整应用显著下降的证明。共享前各轮 42.13–45.22 MiB，共享后 41.69–42.08 MiB，不能将此前查询步骤不同的单次 47.63→41.99 MiB 当作该改动的因果收益。单核 CPU 中位数为 0.0897% 与 0.0853%，范围重叠，不得宣称稳定 CPU 改善。没有测量总能耗或覆盖其他功能页面。

完整协议、每轮身份、原始样本及汇总保存在 `.build/benchmarks/vocabulary-paired/`，汇总为 `comparison.json`。采样器的 git_revision 表示当时工作区 HEAD，两边实际版本以安装 SHA 和对应 identity.json 为准。实验结束恢复共享后正式安装及普通运行，不保留第二个实例。整个重构和显著降低全应用占用目标继续进行。
