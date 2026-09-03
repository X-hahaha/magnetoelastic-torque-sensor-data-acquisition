# DS_system_02ms 上位机

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

- 顶部连接/命令栏：可修改板端 IP、本地绑定IP、端口和输出目录；支持 `Ping`、`DMA_STATUS`、`CAL_STATUS`、`CAL_START`、自定义 ASCII 命令和“采集一帧”。
- 左侧采集信息：手动和自动模式共用，显示模式、当前帧号、记录耗时、WV32收包进度、summary、缺包数量、收包统计和输出路径；自动模式不回传LS32，因此对应字段显示“自动模式不回传”。
- 左侧校准信息：显示 `cal_state`、`cal_valid`、A/B 增益、零点残差和 `me_norm_ppm`。
- 中间波形预览：采集完成后对 4,687,500 点/通道的原始 16bit 数据按有符号 `int16` 抽样显示，蓝色为 ADC A，红色为 ADC B。
- 底部页签：`网口 Log` 显示命令和板端文本回复；`Summary` 显示本帧 summary 字段；`激光/温度时间线` 显示本帧内的 LS32 记录。

GUI 在采集过程中会禁用命令按钮，直到本帧完成并落盘后才允许再次发起采集，避免上位机重复发送 `CAPTURE`。

### GUI 自动模式

自动模式参数与板端约束一致：转速 `1~4000 rpm`，阈值为有符号 32 位微米值，点数为 `16~4,687,500`。界面按钮含义如下：

- `启动自动`：把当前三个输入框参数随 `AUTO_START` 一次性发送；之后只修改输入框不会自动下发。
- `应用参数`：发送 `AUTO_CFG`，用于更新已运行的自动模式，或者设置下一次自动启动的预设值。
- `启动并记录`：推荐的实验入口。上位机先绑定 UDP 50010，再发送 `AUTO_START`，避免自动模式启动后、记录线程建立前丢失首批帧。
- `仅开始记录`：只被动接收当前已经运行的自动模式，不修改板端参数，也不启动自动模式。
- `停止记录`：只停止上位机落盘；板端自动模式仍然运行，需要再点击 `停止自动` 才会发送 `AUTO_STOP`。

自动连续记录目录为 `auto_log_YYYYMMDD_HHMMSS/`，包含：

- `summary.csv`：所有收到的板端 summary。
- `wave_interleaved_a_b_u16le.bin`：本次记录中所有完整帧共用的一个二进制波形文件，按帧完成落盘的顺序连续追加。每个样点依次为小端 `uint16 ADC_A + uint16 ADC_B`，即每个样点 4 字节；按 AD9268 二进制补码解释时可读作两个小端 `int16`。
- `integrity.csv`：逐帧记录期望/实收分包数、缺包编号、重复包、坏包及结束原因。完整帧通过 `wave_file`、`wave_byte_offset`、`wave_bytes` 和 `wave_total_samples` 标出它在上述二进制文件中的位置；UDP 缺包帧不写入波形文件，这些字段留空。

一帧波形可按以下方式从聚合文件中取出：从 `wave_byte_offset` 开始读取 `wave_bytes` 字节，再按 `<i2` 的 `ADC_A, ADC_B` 交织顺序解释。帧在文件中的顺序以 `integrity.csv` 记录为准，不应直接用帧号或行号推算偏移量。

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
  板端 summary，包含 ADC 峰峰值、校准状态、`ls_count` 和 `ls_overflow`。

- `frame_xxxxxx_metadata.json`
  收包统计、缺失 chunk、重复包、坏包、耗时等。

## 注意事项

- 上位机必须绑定本地 UDP `50010`，板端只向这个端口发数据。
- 一帧波形约 18.75 MB，加上少量激光时间线和 metadata。
- 如果 `metadata.json` 中 `missing_chunks` 非空，说明 UDP 包丢失，本脚本不会重传。
- GUI 手动采集和命令行版仍按帧保存波形、时间线、summary 和 metadata；GUI 自动连续记录则以每次“开始记录”为一个目录，使用聚合的 `summary.csv`、`integrity.csv` 和单个 `wave_interleaved_a_b_u16le.bin`。
