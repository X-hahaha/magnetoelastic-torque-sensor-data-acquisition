# DS_system 上位机

这个目录下包含当前板端程序对应的 UDP 上位机：

- `ds_host.py`：命令行接收/控制脚本。
- `ds_host_gui.py`：Tkinter 图形界面版，上板调试时建议优先使用。

## 设计方式

上位机把一次采集当成一个完整事务：

1. 从 PC 本地 UDP `50010` 端口向板端 UDP `5000` 端口发送 `CAPTURE`。
2. 接收所有 `WV32` 原始波形包。
3. 接收所有 `LS32` 激光/温度时间线包。
4. 接收最后的 CSV summary。
5. 落盘完成后才允许发起下一次 `CAPTURE`。

UDP 不做重传；如果丢包，程序会在 metadata 里记录缺失的 chunk 编号。原始波形文件中缺失区域保持为 0。

板端当前固定回发目标是 `192.168.1.100:50010`，所以 PC 网卡建议配置为 `192.168.1.100`。

## 常用命令

在本目录运行：

```powershell
python .\ds_host.py --board-ip 192.168.1.10 ping
python .\ds_host.py --board-ip 192.168.1.10 status
python .\ds_host.py --board-ip 192.168.1.10 capture
```

如果板端 IP 不是 `192.168.1.10`，把 `--board-ip` 改成实际地址。

连续采集 10 次：

```powershell
python .\ds_host.py --board-ip 192.168.1.10 capture -n 10 --interval 1
```

同时拆分保存 A/B 两个通道：

```powershell
python .\ds_host.py --board-ip 192.168.1.10 capture --split-channels
```

发送任意调试命令：

```powershell
python .\ds_host.py --board-ip 192.168.1.10 command DMA_DEBUG --wait 1
python .\ds_host.py --board-ip 192.168.1.10 command FR16_DUMP --wait 1
```

## GUI 上位机

在本目录运行：

```powershell
python .\ds_host_gui.py
```

GUI 默认参数和命令行版一致：

- 板端 IP：`192.168.1.10`
- 板端 UDP 端口：`5000`
- PC 本地 UDP 端口：`50010`
- 默认输出目录：`software/captures/`

界面主要区域：

- 顶部连接/命令栏：可修改板端 IP、PC绑定IP、端口和输出目录；“浏览”按钮右侧实时显示标定扭矩，并可点击“扭矩曲线”查看最近 60 秒的变化；同时支持 `Ping`、`DMA_STATUS`、查询/开始/清除校准、自定义 ASCII 命令和“采集一帧”。
- 左侧采集信息：手动和L2触发采集共用，显示模式、当前帧号、记录耗时、WV32收包进度、summary、缺包数量、收包统计和输出路径；L2触发采集不回传LS32，因此对应字段会明确标注。
- 左侧校准信息：显示 `cal_state`、`cal_valid`、A/B 增益、零点残差和 `me_norm_ppm`。
- 中间波形预览：每帧固定最多抽取 3000 个显示点（不改变实际采集点数），并按 `voltage_V = int16_code × 9.0 / 65536` 换算为电压显示；纵轴单位为 V，蓝色为 ADC A，红色为 ADC B。
- 底部页签：`网口 Log` 显示命令和板端文本回复；`Summary` 显示本帧 summary 字段；`激光/温度时间线` 显示本帧内的 LS32 记录。

GUI 在采集过程中会禁用命令按钮，直到本帧完成并落盘后才允许再次发起采集，避免上位机重复发送 `CAPTURE`。

### 实验推荐顺序

1. 静态、卸载、信号稳定时，点击 **① 开始通道校准**。上位机自动完成所有 CAPTURE，等待 READY；不需要再手动点“采集一帧”。
2. 改为动态工况，例如加载设备设定 100 N·m、1000 rpm。设置 L2 转速、阈值、实际采集点数；输入 T0（默认 100 N·m）、模型标定时间（默认 60 s）和平均帧数（默认 15）。
3. 点击 **开始标定**。未监测时会先启动 L2 监测；从首个有效触发帧开始计时，自动保存标定原始数据并计算 V0。已有监测也可以直接开始标定，但必须先停止实验记录。
4. 完成后自动应用模型、清空平均窗口，继续监测。稳定负载后点击 **开始记录** 保存实验数据。
5. **停止记录** 只结束本次文件会话，实时扭矩和曲线继续更新；可以再次开始记录。**停止监测** 才停止板端触发与接收，并解锁触发参数及平均帧数。

T0 来源是加载设备设定值，不是独立扭矩仪实测值。标定仅更新零点和参考负载，固定斜率不变，不能证明绝对精度。

### 通道校准：3125 点短帧

新版 PS 固件支持 `CAL_START_SHORT`，响应 `cal_protocol=2,points=3125`。GUI 会检查此能力和实际回传点数；旧固件不兼容此一键短帧校准，请先在 SDK 中重新编译、下载修改后的 PS 程序。无需为此修改 PL 采集点数上限。

每帧 3125 点，在 15.625 MSPS 下为 0.2 ms，即 50 kHz 信号的 10 个周期。默认丢弃 **8 帧**、收集 **96 帧**、验证 **96 帧**，每轮 200 帧，最多 3 次尝试（均为有效帧时最多 600 帧，无效帧另计）。原均值/标准差/漂移限值保持 100/2000/500 µV。帧数由 PS 固件决定，必须重新编译、下载才能生效；短帧校准通过率、重复性仍需上板验证。

每帧结束查询 `CAL_STATUS`，进度采用板端阶段和目标值。数据保存到 `calibration_YYYYMMDD_HHMMSS/`。完成校准的最后一帧仍按 3125 点发送；下一次普通手动采集恢复长帧，L2 采集按输入点数执行。

手动/校准接收同时支持长帧和短帧的 LS32，校验 LS32 与 WV32 的实际采样点数一致（允许乱序）。数据及 summary 收齐即结束；只有缺包时保留 summary 后的宽限等待，不再让完整短帧固定多等约 0.8 秒。长帧接收按已收包数量判断完成，不再每包遍历整帧缺包列表。校准仍按“采集、保存、查询状态、下一帧”执行，并非 L2 的 55 ms 触发节拍；0.2 ms 只是 ADC 采样时间，不是整个事务耗时。

**清除校准信息** 清除通道校准并使扭矩模型失效；再次通道校准也会使旧模型失效。改变激励、安装或其他测量链条件后必须重新进行相应校准/标定。程序重启不会自动加载历史模型，以免沿用已失效的板端增益。

### 模型标定与实时扭矩

```text
V0 [µV] = mean(标定时间内有效完整帧的原始 me_2x_uV)
T [N·m] = 0.4424 × (mean_N(me_2x_uV) − V0) + T0
```

V0 不使用重叠滑动平均的二次平均。仅接纳通道 READY/valid、增益一致、点数匹配、ADC 未过量程、有效峰峰值、有限 ME 的完整帧。首帧超时 20 s，标定中有效帧中断超过 5 s 会终止标定；至少需要一个平均窗口且不少于 2 帧，有效时间覆盖至少 80%。取消/失败不会应用半成品模型；原模型仍有效时继续保留原模型。

平均帧数支持 1～1000，监测前设置。无模型、窗口预热、缺包、数据无效或平均窗口跨度超过 5 s 时不输出正式扭矩；连续帧号中断和超过 5 s 无更新会重置窗口。停止记录不重置窗口，重新监测或应用新模型会重置。显示、曲线和保存共用一个计算结果，不存在两套独立平均器。

改变采集点数、转速、L2 阈值或板端地址后，GUI 保守地要求重新标定模型。模型绑定通道增益；增益变动或通道失效时停止使用模型。

界面显示标定区间的滤波峰峰值（最大减最小）、估计窗口时长，并单独给出区间稳定性检查是否达到 **≤200 N·m / ≤5 s**。这不是后续全程稳定性、绝对精度或阶跃响应的验收承诺。扭矩弹窗显示最近 60 秒及该显示区间的峰峰值。

### 监测、记录与数据文件

转速范围 `1～4000 rpm`，阈值为有符号 32 位微米值，实际采集点数范围 `16～4,687,500`、默认 3125。**预览显示点数始终固定为最多 3000，与实际采集点数独立。**

- **开始监测**：先绑定接收 socket，再发送带参数的 AUTO_START；仅显示，不创建记录目录。
- **开始记录**：监测已启动后，为本次记录建立独立 `auto_log_YYYYMMDD_HHMMSS/`。
- **停止记录**：禁止新帧进入本次记录，收尾已经开始接收的帧；接收和实时计算不中断。
- **停止监测**：发送 AUTO_STOP 并等待确认，结束记录和未完成标定。只有确认停止后才恢复触发参数和平均帧数编辑。

模型标定自动建立 `model_cal_YYYYMMDD_HHMMSS/`，与实验记录互斥。两个类型的会话都包含：

- `summary.csv`：收到的板端 summary，每行附加 `pc_timestamp`（PC 收到 summary 的本地 ISO-8601 时间，含时区/微秒，不是板端采样时间）。
- `integrity.csv`：帧完整性、缺包、重复包、结束原因、PC 时间，以及完整波形的 `wave_byte_offset`、`wave_bytes`、`wave_total_samples`。
- `wave_interleaved_a_b_u16le.bin`：按完成顺序追加完整帧；每点为小端 ADC A、ADC B 各 16 位，共 4 B。电压解释用两个 int16；缺包帧不写入波形文件。
- `torque.csv`：逐帧 PC 时间、帧号、原始/平均 ME、扭矩、平均窗口长度/已填帧数/时间跨度、模型 ID 和质量状态。不合格或预热扭矩留空。`used_for_model=1` 标记实际纳入 V0 的样本，`model_calibration_id` 指向本次标定目录名。
- `session.json`：记录开始时的模型快照、触发配置、平均帧数和 T0 来源。

成功模型标定另保存不可覆盖的 `model.json`：含斜率、V0、T0、模型 ID、PC 时间、增益、配置、有效/拒绝帧数、原始标准差、漂移和滤波区间检查结果。失败/取消的标定目录保留原始证据，但不生成成功模型。

按 `integrity.csv` 的字节偏移读取二进制帧，不要用帧号或行号推断位置。记录开始前已在途的帧不进入新会话；停止时尚未完成的帧按完整性规则收尾。模型标定结束边界的未完成帧会明确标记，不混入 V0。

### 离线回归检查

在项目根目录执行（不会连接板端）：

```powershell
python -m unittest discover -s software -p test_ds_workflow.py -v
```

## MATLAB 绘图

`plot_capture_frame.m` 可以绘制任意一帧上位机输出的二进制波形文件，并自动读取同目录下匹配的 metadata、summary 和激光/温度时间线。

在 MATLAB 中进入本目录后运行：

```matlab
plot_capture_frame
```

或者直接指定某一帧：

```matlab
plot_capture_frame("captures/capture_20260808_150309/frame_000032_wave_interleaved_a_b_u16le.bin")
```

如果希望同时保存 PNG：

```matlab
r = plot_capture_frame("captures/capture_20260808_150309/frame_000032_wave_interleaved_a_b_u16le.bin", "SavePng", true);
disp(r.pngPath)
```

图中包含：

- 本帧基础信息、采样点数、UDP WV32/LS32 收包和缺包情况。
- summary 中的 ADC 峰峰值、校准状态、校准增益和残差。
- A/B 通道整帧电压波形，横轴覆盖完整 0 到 300 ms 帧时间。
- A/B 通道整帧电压 min/max 包络，用于观察幅值范围。
- L2 激光在本帧内的时间线。

ADC 电压换算默认使用 `9.0 Vpp / 65536 code`，即：

```matlab
voltage_V = int16_code * 9.0 / 65536
```

整帧有 4,687,500 点/通道，脚本默认等间隔抽取 250,000 点绘制整帧波形。若想强制绘制全部点：

```matlab
plot_capture_frame("captures/capture_20260808_150309/frame_000032_wave_interleaved_a_b_u16le.bin", "WaveformSamples", Inf)
```

## 输出文件

默认输出到 `software/captures/capture_YYYYMMDD_HHMMSS/`。

每帧主要文件：

- `frame_xxxxxx_wave_interleaved_a_b_u16le.bin`
  原始波形，按样点交织保存，每个样点 4 字节：`uint16 ADC_A` + `uint16 ADC_B`，小端。
  文件保持 ADC 原始 16bit 位模式不变；如果按 AD9268 二进制补码查看，应解释为小端 `int16`。

- `frame_xxxxxx_sensor_timeline.csv`
  激光/温度时间线：
  `timestamp_us, adc_sample_index, update_mask, sensor_status, l1_um, l2_um, l3_um, l4_um, l5_um, temp_x10`

- `frame_xxxxxx_summary.csv`
  板端 summary，包含 ADC 峰峰值、校准状态、`ls_count` 和 `ls_overflow`；行末附加PC接收时间 `pc_timestamp`。

- `frame_xxxxxx_metadata.json`
  收包统计、缺失 chunk、重复包、坏包、耗时等。

## 注意事项

- 上位机必须绑定本地 UDP `50010`，板端只向这个端口发数据。
- 一帧波形约 18.75 MB，加上少量激光时间线和 metadata。
- 如果 `metadata.json` 中 `missing_chunks` 非空，说明 UDP 包丢失，本脚本不会重传。
- GUI 手动采集和命令行版仍按帧保存；GUI L2触发模式以每次“开始记录”为独立目录，使用聚合文件并额外保存扭矩与模型快照。仅监测不会建立记录目录。
