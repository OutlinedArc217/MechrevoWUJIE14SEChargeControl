# MechrevoChargeControl — 机械革命(WUJIE 系列等)电池充电控制工具

> 针对官方"机械革命控制中心"对部分机型(如本机 WUJIE 14 / AMD 7445HS)不提供
> 实际充电控制的"空壳"问题,设计的一套**直接调用固件 ACPI-WMI 充电接口**的
> 查询/设置/监控小工具。纯 PowerShell,无需编译、无第三方依赖、默认只读。

---

## 1. 结论(针对本机取证,详见 FORENSICS.md)

| 项 | 结果 |
| --- | --- |
| 机型 | MECHREVO WUJIE 14 系列(Uniwill/Emdoor 血统),AMD Ryzen 7 7445HS |
| 电池 | Li-ion,满充 ≈ 55 Wh,循环计数 0,支持 |
| 固件充电控制接口 | **存在**:ACPI 设备 `ACPI\PNP0C14\HWMI` 暴露 `root\WMI` 下的 `EmdAcpi_Battery_Charge_Mode`(GUID `666d92bd-…`)与 `EmdAcpi_BatteryChargeRationing`(GUID `6B40A935-…`),含 `Battery_Charge_Mode(Data)` / `Get|SetBatteryChargeRationing(Data)` |
| 官方控制台 | 已装(GCUService/GCUBridge/GamingCenterU),但**不含/不暴露**本机充电控制逻辑(空壳实证:全部官方 exe/dll 中搜不到 `EmdAcpi`/`BatteryChargeRationing` 等调用) |
| 官方留下的痕迹 | 注册表 `HKLM\SOFTWARE\OEM\GamingCenter2\BatteryProtection2\HealthProtectionStatus=1`;日志 `C:\ProgramData\ControlCenter\*.log` 开机执行 `Enable BatteryProtection2` |
| 参照实现 | Linux 内核 Uniwill 驱动同款 EC:寄存器 `0x07A6[5:4]` 充电档(0=满/长效,1=平衡,2=工作站),`0x07B9[6:0]` 充电上限 % |
| 数据字编码 | **尚未最终确认**(见 §4),需以管理员跑一次只读 `probe` 来锁定 |

## 2. 快速开始

```powershell
# 1) 查看状态(无需管理员,能读到电池/OEM 注册表;固件读取需管理员)
powershell -ExecutionPolicy Bypass -File .\src\chargectl.ps1 status

# 2) 管理员运行只读探测,确定固件认可的 Data 编码(不改任何硬件状态)
#    右键"以管理员身份运行 PowerShell",再:
powershell -ExecutionPolicy Bypass -File .\src\probe-interface.ps1
#    把输出的 config\lastProbe.json / 控制台结果发回给开发者,用于锁定编码

# 3) 确认真实生效:设置前先观察基线
.\chargectl.ps1 watch -Seconds 180

# 4) 设置(管理员 + 显式 -Force;编码未验证前请先跑 probe)
.\chargectl.ps1 set-limit -Percent 80 -Force      # Rationing 通道:Data=80(假设=上限%)
.\chargectl.ps1 set-mode   -Profile Stationary -Force   # Mode 通道:H1 编码 0/1/2

# 5) 复核:充电是否在上限附近停止 / 电量曲线
.\chargectl.ps1 status
.\chargectl.ps1 watch -Seconds 600
```

图形界面(管理员运行):
```powershell
powershell -ExecutionPolicy Bypass -File .\src\chargectl-gui.ps1
```

## 3. 命令一览(`.\src\chargectl.ps1 <cmd>`)

| 命令 | 说明 | 需管理员 |
| --- | --- | --- |
| `status` | 汇总:电池遥测 + OEM 注册表 + 固件可读结果 | 仅固件读取部分需要 |
| `info` | 打印 4 个 EmdAcpi 类的 GUID/方法签名 | 否 |
| `probe` | 调只读 `probe-interface.ps1` 探测矩阵 | 建议是 |
| `watch -Seconds 120` | 轮询充电状态(验证上限是否生效) | 否 |
| `set-limit -Percent 80 -Force` | `SetBatteryChargeRationing(Data=80)` | 是 |
| `set-mode -Profile Stationary -Force` | `Battery_Charge_Mode(Data=0/1/2)`(H1) | 是 |
| `oemreg -Status 1` | 仅把 OEM 注册表标志写为 1(与官方保持一致,不直接改硬件) | 是 |
| `rawset -Class ChargeRationing -Method Set -Data 0x… -Force` | 高级:任意 Data 字 | 是 |

## 4. 未决问题与安全须知(务必阅读)

1. **Data 字编码未官方公开**。`profiles.json` 里给出两组假设(H1:直接小整数 0/1/2 或百分比;H2:位打包),默认 **verified:false**。请先跑 `probe-interface.ps1` 并回传结果。
2. Linux 内核文档明确警告:**部分该系机型"充电阈值(rationing/threshold)"接口实现有缺陷,强行启用可能损伤电池**,内核甚至不允许 `force` 加载该功能;建议优先使用 **Mode(档位)通道**,且任何写入后都要用 `status`/`watch` 复核。
3. 部分 EC 在启用充电档位后会**向 OS 隐藏真实充电状态**(表现为"不充电"),不要仅凭系统百分比判断;请同时看 `ChargeRate`。
4. 官方在启动时会重写注册表(CCU 日志 `Enable BatteryProtection2`),若与官方组件并存,建议用 `oemreg` 保持注册表一致。
5. 改 BIOS/EC 行为有风险,本工具按"只读优先、写需 `-Force`、可审计日志(`C:\ProgramData\MechrevoChargeControl\logs`)"设计;使用即视为接受风险。

## 5. 目录结构

```
MechrevoChargeControl/
├─ README.md                本文件
├─ FORENSICS.md             本机取证与协议分析记录
├─ config/profiles.json     模式/编码表(探测后可更新)
└─ src/
   ├─ MechrevoChargeControl.psm1   核心模块(只读查询 + 受控写)
   ├─ chargectl.ps1                 CLI 入口
   ├─ probe-interface.ps1           只读探测矩阵(管理员)
   └─ chargectl-gui.ps1             WinForms 图形界面(管理员)
```

兼容:Windows PowerShell 5.1 / PowerShell 7;仅 Windows(x64)。

---

## 6. 第二轮调研/静态分析后的新情报(2026 更新)

**官方服务 GCUService.exe(.NET,未混淆)里其实有完整的 `BatteryProtection2` 实现**,只是界面没把它对这台机型开放。静态反射得到(非猜测,来自编译期枚举):

| 项 | 值 |
| --- | --- |
| 健康档枚举 `BatteryHealthProtection_Status` | 0=长效(PERFORMANCE,满充)、1=平衡(BALANCED)、2=工作站(HEALTHY) |
| 命令协议 `Battery_Commands` | GET=0, CHARGING_UP_LIMIT=1, CHARGING_DOWN_LIMIT=2, RECOVERY=3, TYPE_C_ADAPTOR_PRIORITY_SWITCH_ON=4 / OFF=5 |
| 关键方法 | `SetHealthProtectionStatus / High / Middle / Low`、`Set/ReadBatteryChargingLimit_Up/Down`、`EnableByService` |
| EC 通道 | `MyEcCtrl`(GPD 内核驱动 IOCTL:`IOCTL_GPD_ACPI_ECREAD/ECWRITE` 等)+ `WMIEC`(WMI EC-RAM) |
| 本机当前 | 注册表 `HealthProtectionStatus=1`(=平衡档,官方开机任务会写它) |

**寄存器与取值(主线 Linux uniwill 驱动逐行核实 + 社区实测)**
- EC 访问:ACPI `\_SB.INOU` 的 `ECRR(reg)` / `ECRW(reg,val)`,官方软件每次访问后睡 6ms;
- `0x07A6[5:4]` 充电档:0=满/长效、1=平衡、2=工作站(同字节 bit6 是触控板开关,勿整字节覆盖);
- `0x07B9[6:0]` 充电上限 1–100(0=未激活,读回 0 按 100;bit7=已达);14XA 社区实测范围 **60–100**;
- ⚠️ **门控 bug(WUJIE14XA 族)**:写 0x07B9 不生效时,需固件 ≥ N.1.14MRO19(EC2.08)/N.1.14MRO50(EC2.12);社区绕行=临时把 0x07C3 写 0x04 约 2s 再还原,并确认 0x0742 的 bit2(值&0x04)已置位。**本机(WUJIE14SE Rev04)固件较新,EC 版本未核实,先跑 probe 确认,别照搬。**

**主要来源**:内核驱动源码(uniwill-acpi.c)、内核文档 uniwill-laptop.rst、[ArchWiki MECHREVO WUJIE14X](https://wiki.archlinux.org/title/Mechrevo_WUJIE14X)、[w568w EC 分析 gist](https://gist.github.com/w568w/957976b59906e0ce5d6c13ad342e1593)、[Lecoo-Control-Center(Emdoor/ITE EC 参考)](https://github.com/LaVashikk/Lecoo-Control-Center)、[e411 对 GCUService 的逆向文章](https://www.e411.cn/posts/patch-mechrevo-gcuservice.html)、[内核文档警告出处 XMG/reddit](https://www.reddit.com/r/XMG_gg/comments/ld9yyf/battery_limit_hidden_function_discovered_on/)。完整证据见 `FORENSICS.md`。

> 若要一锤定音(官方对 0x07A6/0x07B9 的精确调用与 Data 字),在这台机器上装 `dotnet tool install -g ilspycmd` 后运行
> `ilspycmd -t "C:\Program Files\OEM\机械革命控制中心\AiStoneService\MyControlCenter\GCUService.exe" -o .\decomp` 并把结果发回即可。

---

## 7. ✅ 2026-09-09 实测确认(本机 WUJIE14SE)

管理员自校准探测(只读矩阵 + 无功能影响写入)已**证实**:

- `EmdAcpi_*` 方法**必须通过 WMI 实例 `ACPI\PNP0C14\HWMI_0` 调用**(类级调用一律被固件拒绝;实例枚举需要管理员);
- `SetBatteryChargeRationing(Data)` 的 **Data = 充电上限百分比直传(0–100)**;
  - `Set 100` → 读回含 `0x64=100`;`Set 0` → 读回 `0xFF0000`(0=未激活,0xFF 为未启用标记字节,无功能影响);
  - 0 = 阈值未激活(充满 100%),与 Linux 侧 EC `0x07B9` 语义一致;
- `Battery_Charge_Mode`(档位 0/1/2,对应 EC `0x07A6`)尚未做写测试,默认不动。

**可直接执行的设置方式(普通终端,自动弹 UAC)**:
```powershell
# 设 80% 上限(先插好电源适配器,再运行;每次都会弹 UAC)
powershell -ExecutionPolicy Bypass -File .\tools\SetChargeCap-Elevated.ps1 -Percent 80
# 恢复"充满"(阈值未激活;100 与 0 均可,0 更符合"未激活"语义)
powershell -ExecutionPolicy Bypass -File .\tools\SetChargeCap-Elevated.ps1 -Percent 0
# 观察是否在上限停止充电(无需管理员)
powershell -ExecutionPolicy Bypass -File .\src\chargectl.ps1 watch -Seconds 1800
```

**✅ 本机实测(2026-09-09,设 80%)**:充电功率 ~29 W → 电量 ~79–80%(OS 取整)时 `rate` 归零、百分比停住不再上升;`charging` 标志仍为 True 但电流为 0 —— 符合该系 EC"启用上限后向 OS 隐藏真实充电状态"的已知行为,**判断以电流/功率为准**。门控正常,无 14XA stored-limit bug。

## 8. 🔁 开机自动应用上限(计划任务)

某些同系 EC 在整机断电数分钟后会把上限重置回 100%。项目内置一个"每次开机/登录静默应用上限"的计划任务(以 SYSTEM 运行,无窗口、无 UAC):

```powershell
# 1) 安装(自提权,仅首次弹一次 UAC → 是),默认 80%
powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Percent 80
# 2) 查看状态 / 最近执行结果与日志
powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Status
# 3) 卸载
powershell -ExecutionPolicy Bypass -File .\tools\install-auto-cap.ps1 -Uninstall
```

机制说明:
- 目标值持久化在 `config/autocap.txt`(单个整数 0–100;0 = 阈值未激活);装好后直接改这个文件,下次开机即按新值执行,无需重装任务;
- 每次执行由 `src/apply-cap.ps1` 完成:延迟 20s(等 EC/官方服务就绪)→ `SetBatteryChargeRationing(值)` → 读回 → 记日志 `%ProgramData%\MechrevoChargeControl\logs\apply-cap.log`;
- 提示:装机任务指向仓库内脚本路径,**移动/改名仓库后请重跑一次安装命令**。

## 9. 开源发布(GitHub)说明

- 本仓库代码/文档均为纯文本与 PowerShell,无密钥、无机器标识外的敏感数据;`config/autocap.txt`、日志与探测输出已被 `.gitignore` 排除;
- 发布前建议自查:确认 `FORENSICS.md`/`README.md` 中提到的本机序列号等标识性信息是否要保留(当前文档未含序列号);
- 快速初始化:
```powershell
git init
git add .
git commit -m "Mechrevo/Uniwill ACPI-WMI battery charge control toolkit"
git branch -M main
git remote add origin https://github.com/<你>/<仓库>.git
git push -u origin main
```
