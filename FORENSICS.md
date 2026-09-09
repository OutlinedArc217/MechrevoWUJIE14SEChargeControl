# FORENSICS.md — 本机充电控制接口取证记录

> 记录 2026-xx 对这台 MECHREVO WUJIE 14(AMD 7445HS)电池充电控制的调查,
> 全部只读操作。命令基于 PowerShell。

## 1. 设备身份

```
Manufacturer/Model : MECHREVO / WUJIE Series
BIOS               : American Megatrends  WUJIE14SE_SE4_APX336_7445HS_Rev04 (2026-06-17)
Chassis            : 10 (Notebook)
Battery            : Li-ion; root\WMI BatteryFullChargedCapacity = 54996 mWh; CycleCount=0
```

## 2. 固件暴露的 ACPI-WMI 充电接口(root\WMI)

设备:`ACPI\PNP0C14\HWMI`(厂商专用 WMI-ACPI;另一个 `WMID` 是微软标准块)

| 类 | GUID | 方法(Data:UInt64,in/out) |
| --- | --- | --- |
| `EmdAcpi_Battery_Charge_Mode` | `666d92bd-f6e0-4979-9b9f-0436a9a379d0` | `Battery_Charge_Mode(Data)` — "Switch Battery_Charge_Mode" |
| `EmdAcpi_BatteryChargeRationing` | `6B40A935-7FEF-42b6-B08D-6C79B57D6C35` | `GetBatteryChargeRationing(Data)` / `SetBatteryChargeRationing(Data)` |
| `EmdAcpi_BatteryInfo` | `6377F67E-DA51-45F6-8898-33EF5F1F5A16` | `GetBatteryBasicInfo / GetBatteryRealtimeInfo / GetBatteryLifecapacity / GetBatterySN` |
| `EmdAcpi_ECInformation` | `861F913E-1B25-41E5-B4DD-D1FD9091713F` | `GetEcVersion / GetPdVersion / GetCpuTemperature` |

观察到的行为(普通权限 Medium IL):
- `Get-CimInstance` 枚举 → `拒绝访问`
- `Invoke-CimMethod`(Get 类,各种 Data 值 0…0xFFFFFFFF)→ 全部 `无效的方法参数`(参数类型已匹配 UInt64,数组形式报"类型不匹配")

⇒ 结论:**调用需要管理员**,且 Data 字协议未知(很可能带实例上下文或特定命令字)。

## 3. "控制台是空壳"的证据

- 在 `C:\Program Files\OEM\机械革命控制中心` 与 `C:\Program Files\IGRS\Mechrevo`(星界智联)全部 exe/dll 上
  以 ASCII 与 UTF-16 两种方式搜索 `EmdAcpi`、`BatteryChargeRationing`、`Battery_Charge_Mode`、`ECRW`/`ECRR` 等
  → **零命中**(仅 `GCUService.exe` 含 `BatteryProtection` 字样,指向注册表路径/端点名)。
- 官方遗留状态:
  - 注册表 `HKLM\SOFTWARE\OEM\GamingCenter2\BatteryProtection2\HealthProtectionStatus = 1`,`TypeCAdaptorPriorityStatus = 0`;
  - `C:\ProgramData\ControlCenter\2026-09-*.log`:`[StartUpTask] Enable BatteryProtection2`(开机执行);
  - UI 文案(logo/Language/zh-cn.json):"电池保护模式" = 长效模式 / 平衡模式 / 工作站模式;
  - `GCUBridge.exe`(服务,运行中)监听 `0.0.0.0:13688`,对 GET 无响应(非普通 HTTP,未继续逆向)。

## 4. 参照:Linux 内核 Uniwill 驱动的同系 EC 寄存器

来源:torvalds/linux `drivers/platform/x86/uniwill/uniwill-acpi.c` + 内核文档(见 §6)。

- 该系 EC 通过 ACPI 方法 `ECRR(reg)`/`ECRW(reg,val)` 读写(对应 ACPI 设备 `INOU0000`);
- **充电档位**:EC `0x07A6` bits[5:4]:`0`=HIGH_CAPACITY(满电/长效)、`1`=BALANCED(平衡)、`2`=STATIONARY(工作站);支持"充电档位(charge_types)"的机型用此寄存器;
- **充电上限**:EC `0x07B9` bits[6:0] = 上限百分比,bit7 = 已达阈值(REACHED);支持"充电阈值(charge_control_end_threshold,1..100)"的机型用此寄存器;
- **Type-C 电源优先级**:EC `0x07CC` bit7;
- 特性位 `BATTERY_CHARGE_LIMIT` 与 `BATTERY_CHARGE_MODES` **互斥**,视机型而定;
- ⚠️ 内核文档警告:部分机型**阈值接口实现有缺陷**,内核 `force` 加载也**不会**开启该功能,以免损坏电池;文档特别提到"启用档位后 EC 会向 OS 隐藏真实充电状态"。

本机差异:Windows PnP 中**没有** `ACPI\INOU0000` 设备(`UWACPIDriver.sys` 为 Uniwill 遗留驱动,未加载),
因此不存在可用户态直连的 `ECRR/ECRW` 节点 ⇒ Windows 侧唯一正道就是 **EmdAcpi ACPI-WMI 类**。

## 5. 推论(供编码假设,均未验证)

- 界面文案"长效/平衡/工作站" ↔ 档位 0/1/2(对应 `0x07A6` 的 0/1/2),而"BatteryProtection2"
  的名字/注册表值很可能就是"健康保护档位"(现为 1)。
- Windows 的 `Battery_Charge_Mode(Data)` ≈ 档位切换(`0x07A6`);`Get/SetBatteryChargeRationing(Data)` ≈ 阈值读写(`0x07B9`)。
- 待定:Data 字到底是"档位码 0/1/2""百分比 0..100"还是"位打包(低字节值+高字节标志)"——
  由 `probe-interface.ps1`(管理员、只读)实测确认。

## 6. 参考链接

- 内核文档 Uniwill 笔记本特性(充电控制段):<https://docs.kernel.org/next/admin-guide/laptops/uniwill-laptop.html>
- Uniwill ACPI 驱动源码:torvalds/linux `drivers/platform/x86/uniwill/uniwill-acpi.c`
  <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/platform/x86/uniwill/uniwill-acpi.c>
- 内核 ABI 文件:`Documentation/ABI/testing/sysfs-driver-uniwill-laptop`
- 内核补丁讨论(platform/x86: Add Uniwill laptop driver):
  <https://lkml.iu.edu/hypermail/linux/kernel/2506.2/09618.html>
- Linux 提交(引入 uniwill 驱动):<https://github.com/intel-lab-lkp/linux/commit/84815b7206a700d093870b75d98a49e7ececb23e>

## 7. 局限

- 本记录不含对任何 Set 方法/EC 寄存器的写入实验;所有写入实验须用户在有意的、可回滚的前提下进行。
- GCUBridge:13688 端口的本地协议未逆向;官方 UI 与服务的具体交互未完全还原。

## 8. 追加:官方 GCUService.exe 静态反射(2026,PowerShell reflection-only)

工具:`tools/inspect-gcu.ps1`。对 `AiStoneService\MyControlCenter\GCUService.exe` 反射枚举结果:

- 命名空间 `GCUService.MySystem` 内:
  - `BatteryProtection`(旧版)与 **`BatteryProtection2`**(当前),字段 `EcCtrl : MyEcCtrl`、`m_MQTTClient : MqttClientCtrl`、注册表路径 `\OEM\GamingCenter2\BatteryProtection`;
  - 枚举 `BatteryHealthProtection_Status`:`PERFORMANCEDMODE=0 / BALANCEDMODE=1 / HEALTHYMODE=2`;
  - 枚举 `Battery_Commands`:`GET=0, CHARGING_UP_LIMIT=1, CHARGING_DOWN_LIMIT=2, RECOVERY=3, TYPE_C_ADAPTOR_PRIORITY_SWITCH_ON=4, OFF=5`;
  - 方法:`SetHealthProtectionStatus / High / Middle / Low`、`Set|ReadBatteryChargingLimit_Up / _Down`、`EnableByService / Init / LoadBatteryLimitationDefault / Resume / Receive(byte[])`(UI↔服务消息,MQTT);
- `MyECIO.MyEcCtrl` / `IOdriverEC`:EC 访问层,含 `LoadDrv/UnloadDrv/Read/Write`,同程序集内含一组 GPD 驱动 IOCTL 常量(`IOCTL_GPD_ACPI_ECREAD/ECWRITE/CMREAD/…`),即官方写 EC 走内核驱动而非裸端口;
- `MyControlCenter.WMIEC` / `MyRGBKeyboard.WMIEC`:`WMIReadECRAM/WMIWriteECRAM` 等 WMI 通道封装(自绘常量 `SMRW_CMD_READ=187(0xBB)`、`SMRW_CMD_WRITE=170(0xAA)`、`GETSETULONG2_CMD_*` 等暗示其内部协议);

推论:官方"电池保护模式"由 GCUService 服务端实现(BatteryProtection2),UI 通过 MQTT 发 `Battery_Commands` 消息,服务再经 MyEcCtrl(驱动)或 WMIEC 写 EC/WMI——因此"空壳"更可能是 **UI 未对这台机型暴露该项/或写入被 EC stored-limit 门控静默失败**,而非服务端没有实现。方法体级(IL/反编译)细节需 dnSpy 或 ilspycmd,本机无此类工具。

## 9. 追加:第二轮资料调研来源索引

- 主线内核驱动 uniwill-acpi.c(全文核对):<https://cdn.jsdelivr.net/gh/torvalds/linux@master/drivers/platform/x86/uniwill/uniwill-acpi.c> ;Debian 源镜像目录 <https://sources.debian.org/src/linux/7.2.3-1~exp1/drivers/platform/x86/uniwill/>
- 内核文档 uniwill-laptop.rst(充电控制/警告节):<https://sources.debian.org/src/linux/7.2.3-1~exp1/Documentation/admin-guide/laptops/uniwill-laptop.rst/>
- ArchWiki MECHREVO WUJIE14X(门控 bug 修复与 60–100 范围):<https://wiki.archlinux.org/title/Mechrevo_WUJIE14X>
- w568w 充电阈值分析 gist:<https://gist.github.com/w568w/957976b59906e0ce5d6c13ad342e1593>
- 社区 Linux 实测:LongSang01/wujie14X-Linux-Driver <https://github.com/LongSang01/wujie14X-Linux-Driver> ;sund3RRR/mechrevo14X-linux <https://github.com/sund3RRR/mechrevo14X-linux> ;minortex/mech-forza-control <https://github.com/minortex/mech-forza-control>
- Emdoor/ITE EC 参考实现 Lecoo-Control-Center:<https://github.com/LaVashikk/Lecoo-Control-Center>
- GCUService 逆向思路(e411):<https://www.e411.cn/posts/patch-mechrevo-gcuservice.html>
- 内核"阈值缺陷伤电池"警告出处(XMG/reddit):<https://www.reddit.com/r/XMG_gg/comments/ld9yyf/battery_limit_hidden_function_discovered_on/>
- 补丁系列封面 LWN:<https://lwn.net/Articles/1066674/> ;Debian 启用请求:<https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1131166>

## 10. 追加:管理员实测确认(2026-09-09,本机 WUJIE14SE)

方法:`tools\probe2-elevated.ps1 -AllowCalibration`(UAC 提权,实例 `ACPI\PNP0C14\HWMI_0`)。

关键事实:
- **类级 `Invoke-CimMethod` 全部失败**("无效的方法参数",HRESULT 0x80131500),**实例级全部成功** → 调用姿势必须是"枚举实例 → 实例上执行方法",枚举要求管理员;
- 只读矩阵:`GetBatteryChargeRationing` 对任意 Data 均返回 0(阈值未激活);`GetEcVersion=0xE0000`、`GetPdVersion=0x19170000`、`GetCpuTemperature=0x2`、`GetBatteryBasicInfo/Realtime/Lifecapacity` 随 Data 输入变化(疑似按字段索引的 EC 数据块);
- **自校准(两次无功能影响写入)**:
  - 写前 `Get=0x0`;
  - `Set 100` → `Get=0x64630000`(字节流含 0x64=100);
  - `Set 0`(还原)→ `Get=0xFF0000`(0xFF=未启用标记字节,limit 字节为 0);
  - 结论:`SetBatteryChargeRationing(Data)` **Data=上限百分比直传 0–100**,0=未激活(充满),与 EC `0x07B9`/Linux 语义一致;
- `Battery_Charge_Mode`(档位)未做写实验。

遗留:官方 GCUService 是否同时写档位(0x07A6)或"下限/恢复"寄存器(命令枚举里另有 CHARGING_DOWN_LIMIT、RECOVERY)待 ilspycmd 反编译确认;对日常"充到 X% 停"而言,百分比上限通道已足够。
