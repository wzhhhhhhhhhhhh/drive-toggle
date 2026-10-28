# 开发与维护说明

> 这份是给"要改这个工具的人（或 AI）"看的，普通用户看 [README.md](README.md) 就够了。
> 测试用例与变更记录在 [TESTING.md](TESTING.md)。

---

## 1. 目录结构

```
Drive-Toggle\
├── 初始化.exe              唯一入口：双击＝初始化；也是计划任务和快捷方式的目标
├── README.md               给用户看
├── DEVELOPING.md           本文件：给维护者看
├── TESTING.md              测试体系与用例矩阵
├── config.json             要管理哪些盘（初始化时生成，不进版本库）
├── LOCAL.md                本机专属信息（型号/序列号/盘内清单，不进版本库）
├── app\
│   ├── dd-core.ps1         引擎：读配置、找盘、挂载/卸载、SMART、日志、图标
│   ├── ui-wpf.ps1          界面层逻辑：选盘 / 进度 / 确认 / 提示
│   ├── ui-picker.xaml      选盘窗
│   ├── ui-progress.xaml    进度窗
│   ├── ui-confirm.xaml     初始化确认窗
│   ├── setup.ps1           初始化流程
│   ├── install.ps1         建计划任务 + 桌面快捷方式
│   ├── mount-all.ps1       强制挂载
│   ├── unmount-all.ps1     强制卸载
│   ├── toggle-all.ps1      切换（总开关 / -Only N 单盘）
│   ├── test.ps1            静态检查 + 集成测试（76 项）
│   ├── test-logic.ps1      内存假盘逻辑测试（57 条）
│   ├── run-e2e.ps1         真机端到端（可选，手工跑）
│   ├── build-launcher.ps1  重新编译 初始化.exe
│   └── _launcher_src.cs    初始化.exe 的源码
├── icons\
│   ├── app.ico             应用图标（嵌入 exe + 所有窗口的任务栏图标）
│   ├── toggle-on/off.ico   总开关图标
│   ├── disks\              每盘图标 A–Z × 2 状态 = 52 个
│   └── _src\               图标生成脚本与素材
└── logs\                   运行日志（不进版本库）
```

---

## 2. 分层

```
初始化.exe ──┬─ 无参数        → 提权 → app\setup.ps1
             ├─ task <名字>   → schtasks /run（静默）
             └─ run <脚本>    → powershell -NoProfile -File，CreateNoWindow
                                 ↑ 计划任务走这条，所以点开关不闪黑窗

setup/toggle ──→ ui-wpf.ps1（界面） ──→ dd-core.ps1（引擎，无界面依赖）
```

**引擎与界面完全分开**：`dd-core.ps1` 不引用任何 UI 类型，可以直接在命令行里测；
界面层只负责"显示 + 收集输入"。改界面不会碰到磁盘逻辑，改逻辑也不会碰界面。

---

## 3. 关键实现点

| 事情 | 怎么做的 |
|---|---|
| 认盘 | 用 `SerialNumber` 匹配，不用盘符（盘符会变） |
| 脱机/联机 | `Set-Disk -IsOffline $true/$false` |
| 免 UAC | 初始化时注册计划任务（`RunLevel Highest` + `LogonType Interactive`），之后点图标是触发任务 |
| 不闪控制台 | 不用 `powershell.exe -WindowStyle Hidden`（仍会创建 conhost），而是由 GUI 子系统的 `初始化.exe` 以 `CreateNoWindow` 拉起 |
| 真停转 | USB 盘额外设 `MSPower_DeviceEnable.Enable = true`（省电挂起） |
| 卸载前检查 | 关资源管理器窗口 → 查占用进程 → 采样 2 秒读写，写入 > 64 KB/s 则放弃 |
| 界面不卡 | 磁盘操作跑在**后台 STA runspace**，UI 线程只刷新；进度用同步哈希表回传 |
| 图标随状态变 | 改快捷方式的 `IconLocation` + `Description`，桌面与开始菜单两处都改 |

---

## 4. 几个必须知道的坑

这些都是实际踩过、并且**会让程序静默出错而不报异常**的：

### 4.1 `.ps1` 必须 UTF-8 **带 BOM**

PowerShell 5.1 会把无 BOM 的脚本按 GBK 读，中文全部变乱码并引发语法错误。
`test.ps1` 的 **F2** 会检查这一点，改完文件记得补 BOM。

### 4.2 PowerShell 脚本块是**动态作用域**，不是词法闭包

脚本块里的自由变量，在调用时才按**调用方**的作用域链解析。踩过四次：

- 进度回调里 `$st` 被下层同名变量顶掉 → 报"属性不存在"
- worker 的 `$targets` 被 dd-core 的 `$script:Targets` 覆盖 → 单盘变成全量
- `toggle-all` 里 `$targets` 覆盖 `$Targets` → 总开关图标算错

**对策**：跨层传递的状态一律放进哈希表当**参数**传；需要长期存在的用
`$global:__dshXxx` 这种带前缀的名字。`test.ps1` 的 **D7** 会拦住"只差大小写"的变量名。

### 4.3 WPF 的 `BitmapImage` 读 `.ico` 只取第一帧

图标文件里明明有 256px 的帧，`BitmapImage` 只解码第一帧（16px），
系统再把它塞进 40px 的图标位，内容只占 40%，看起来就特别小。

**对策**：用 `BitmapDecoder` 取 `PixelWidth` 最大的一帧（见 `Get-UiIcon`）。
`TESTING.md` 的 M43 里有实测办法（`WM_GETICON` 量内容占比）。

### 4.4 无边框 + 透明的 WPF 窗口默认不进任务栏

这种窗口是分层窗口，需要显式补 `WS_EX_APPWINDOW`、去掉 `WS_EX_TOOLWINDOW`，
再 `SetWindowPos(SWP_FRAMECHANGED)` 刷新；同时设 `AppUserModelID`，
否则任务栏会把它算成 `powershell.exe`。

### 4.5 `$host`、`$args`、`$env` 等是只读自动变量

`$host = ...` 会静默失败（`SessionStateUnauthorizedAccessException`），
后续 `$host.Children.Add()` 全都加到空对象上——表现为"窗口一片空白但不报错"。

### 4.6 计划任务里写的是**绝对路径**

移动文件夹后必须重新双击 `初始化.exe`。`test.ps1` 的 **J3/J4** 会检查任务指向的
脚本和 exe 是否还存在。

---

## 4.7 唤醒哨兵（脱机期间有没有被读）

每次操作前后各记一次 SMART 累计值（启停 `StartStopCycleCount`、磁头加载
`LoadUnloadCycleCount`、通电小时 `PowerOnHours`），存在 `logs\disk-state.json`。

- 操作**前**：`Get-OfflineWakeups` 比对「上次快照（state=off）」与当前读数，
  计数变大就写 `steps.csv`（阶段=`唤醒`/WARN）+ `logs\wakeups.csv`，并把结果交给界面
- 操作**后**：`Save-DiskState` 写入新快照（含当前 state）
- 界面：进度窗 footer 显示"疑似被唤醒"，并显示「知道了」按钮，**必须点击才关窗**
  （最多等 10 分钟，避免无人值守卡死）

判定细节在 `Compare-DiskSnapshot`（纯函数，可测）：上次不是 off、
SMART 读不到、计数没变 —— 都不告警。

**阈值为什么是 2**：读 SMART 这个动作本身就会把停转的盘唤醒（启停 +1）。
那一次是我们自己造成的，不算"脱机期间被别人碰过"，所以 `Compare-DiskSnapshot`
默认要求增量 ≥ 2 才报警。代价是：如果盘全程没停转过，别人碰它也不会增加计数，
那种情况查不出来。

**局限**：启停次数增加不等于"被读了 N 次"。盘按电源策略自己停转再被唤醒，
计数同样会 +1。所以文案一律写"疑似"，并把三个数一起记下来让人自己判断。

## 5. 维护操作

| 想做什么 | 怎么做 |
|---|---|
| 重装 / 修复任务和图标 | 双击 `初始化.exe` → UAC「是」→「沿用现有配置」 |
| 换管理的盘 | 双击 `初始化.exe` →「重新选盘」 |
| 改应用图标 | 改 `icons\_src\make_app_icon.py` → `python icons\_src\make_app_icon.py` → `app\build-launcher.ps1` |
| 改每盘图标 | 改 `icons\_src\make_perdisk_icons.py` 里的配色/字形 → 重跑 → 重新初始化 |
| 重新编译入口 exe | `powershell -File app\build-launcher.ps1`（用 csc，`Add-Type` 无法嵌图标） |
| 跑测试 | `powershell -File app\test.ps1`（76 项，约 1 分钟） |
| 只看逻辑 | `powershell -File app\test-logic.ps1`（57 条，内存假盘，几秒） |
| 端到端真机测 | `powershell -File app\run-e2e.ps1`（会真的开关盘，手工决定跑不跑） |

---

## 6. 已知风险

**目录的提权面**：计划任务以管理员身份运行 `app\*.ps1`。如果这个目录对普通用户可写
（例如放在 `C:\Apps\` 继承了 `Authenticated Users: Modify`），那么任何以该用户身份运行
的程序都能改写脚本，进而以管理员权限执行任意代码。

建议把目录收紧到只有管理员和 SYSTEM 可写：

```powershell
icacls "D:\Tools\Drive-Toggle" /inheritance:r `
    /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /grant "Users:(OI)(CI)RX"
```

---

## 7. 约定

- 改完代码：跑 `test.ps1` → 补 `TESTING.md`（矩阵/用例/变更记录）→ 再跑一次 → 提交
- 提交信息写清「改了什么 + 为什么 + 验证结果」
- 文档不得早于代码（`test.ps1` 的 **D3** 会检查），也不得含本机专属信息（**D5**）
