# 正式进程资源测量

`python3 Scripts/measure-installed-resources.py` 只读取 `/Applications/Aether.app/Contents/MacOS/Aether` 的聚合进程计数，不启动应用、不读取用户历史或 API Key、不更改设置。工具验证签名、唯一 Aether 进程、可执行路径、进程启动标识、运行映像与产物 Mach-O UUID 和安装二进制 SHA-256；任意变化会拒绝输出有效结果。已有结果文件不覆盖。

```sh
python3 Scripts/measure-installed-resources.py --scenario settings-closed --duration 30 --output .build/benchmarks/settings-closed.json
python3 Scripts/measure-installed-resources.py --scenario general-visible --duration 30 --output .build/benchmarks/general.json
python3 Scripts/measure-installed-resources.py --scenario ports-visible --duration 30 --output .build/benchmarks/ports.json
python3 Scripts/measure-installed-resources.py --scenario general-after-ports --duration 30 --output .build/benchmarks/after-ports.json
```

每条命令前通过原生界面准备对应场景，并核对页面；scenario 是操作者标签，脚本不会观察或控制页面。测量期间维持页面、设备连接和设置稳定，避免输入/搜索、硬件热插拔及其他主动工作；至少记录三轮并比较中位值。首次打开页面、暖缓存及返回后的保留内存分别测量，不混作冷启动。不同用户数据量、系统压力、设备和授权环境的结果不可直接比较。

采样辅助程序由本机 SDK 编译，使用 `proc_pid_rusage(RUSAGE_INFO_V4)`，结构直接来自系统头文件。记录 RSS、physical footprint、累计 CPU、唤醒和磁盘字节数，以及每次读取耗时；不采集进程地址空间或正文。CPU 为两次累计 user+system 差值乘以本机 Mach timebase，除以真实采样间隔，单核 100%，并行可超过 100%。不是 `ps %cpu` 的整个进程生命周期平均。RSS 与 footprint 口径不同，不能互相替代；唤醒计数不是整机电量或能耗。

计数含义核对 [Apple XNU 进程资源填充](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) 与 [task power 时间计数实现](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)：user/system 来自 Mach 时间统计，physical footprint 来自任务 ledger。保留原始 Mach 计数及 numer/denom，避免将其直接当纳秒。这里只报告进程资源，尚未建立同负载旧 Swift 基线或能耗测量，不能据此宣称 Rust 显著降低整应用占用。

工具验证：`python3 -m unittest discover -s Scripts/tests` 检查 Mach 换算、双模式 CPU、并行超过 100%、内存汇总及无效区间；辅助程序对零/无效 PID 和非正式进程拒绝读取。真实采样仍须核对进程与场景。原始 JSON 保存在 `.build/benchmarks`，记录提交、工作区状态、架构、macOS、产物哈希和全部样本，不提交真实环境数据。

## 固定负载的隔离准备

通用与计时偏好已统一经 AppEnvironment.appDefaults 注入；正常安装仍为原标准域，单元测试为独立域。44 个静态计时键和 AppStorage 已显式绑定，避免偏好注入后仍读写真实配置。完整性能配置还须隔离启动迁移、剪贴板监听与系统动作，将相同配置用于旧 Swift 与当前正式产物；目前没有运行该隔离模式，不能把这一步当作旧版基线已经建立。
