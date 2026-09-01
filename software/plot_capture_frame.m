function result = plot_capture_frame(waveFile, varargin)
%PLOT_CAPTURE_FRAME Plot one DS_system_02ms capture frame.
%
% Usage:
%   plot_capture_frame
%   plot_capture_frame("captures/capture_20260808_150309/frame_000032_wave_interleaved_a_b_u16le.bin")
%   result = plot_capture_frame(..., "SavePng", true, "EnvelopeBins", 5000)
%   result = plot_capture_frame(..., "WaveformSamples", 250000)
%
% The binary waveform file stores the raw 16-bit ADC bit pattern as
% interleaved little-endian samples:
%   int16 ADC_A, int16 ADC_B, int16 ADC_A, int16 ADC_B, ...
% The plot converts ADC codes to voltage with:
%   voltage_V = int16_code * AdcFullScaleVpp / 65536
%
% The function also looks for matching files in the same directory:
%   frame_xxxxxx_metadata.json
%   frame_xxxxxx_summary.csv
%   frame_xxxxxx_sensor_timeline.csv

    if nargin < 1 || isempty(waveFile)
        [name, folder] = uigetfile( ...
            {'*_wave_interleaved_a_b_u16le.bin;*.bin', 'Waveform binary (*.bin)'}, ...
            'Select one DS_system waveform binary');
        if isequal(name, 0)
            result = [];
            return;
        end
        waveFile = fullfile(folder, name);
    end

    opt = parse_options(varargin{:});
    waveFile = char(waveFile);
    if exist(waveFile, 'file') ~= 2
        error('Waveform file does not exist: %s', waveFile);
    end

    [folder, baseName, ~] = fileparts(waveFile);
    frameTag = regexp(baseName, 'frame_\d+', 'match', 'once');
    if isempty(frameTag)
        frameTag = baseName;
    end

    metadataPath = fullfile(folder, [frameTag '_metadata.json']);
    summaryPath = fullfile(folder, [frameTag '_summary.csv']);
    sensorPath = fullfile(folder, [frameTag '_sensor_timeline.csv']);

    metadata = read_metadata(metadataPath);
    summary = read_summary(summaryPath);
    sensor = read_sensor(sensorPath);

    adc = read_wave_int16(waveFile);
    adcA = adc(1, :);
    adcB = adc(2, :);
    sampleCount = size(adc, 2);
    sampleRateHz = opt.SampleRateHz;
    frameMs = sampleCount / sampleRateHz * 1000.0;
    codeToVolt = opt.AdcFullScaleVpp / 65536.0;
    adcAV = double(adcA) * codeToVolt;
    adcBV = double(adcB) * codeToVolt;

    stats = struct();
    stats.aCodeMin = double(min(adcA));
    stats.aCodeMax = double(max(adcA));
    stats.aCodePp = stats.aCodeMax - stats.aCodeMin;
    stats.bCodeMin = double(min(adcB));
    stats.bCodeMax = double(max(adcB));
    stats.bCodePp = stats.bCodeMax - stats.bCodeMin;
    stats.aMinV = min(adcAV);
    stats.aMaxV = max(adcAV);
    stats.aPpV = stats.aMaxV - stats.aMinV;
    stats.bMinV = min(adcBV);
    stats.bMaxV = max(adcBV);
    stats.bPpV = stats.bMaxV - stats.bMinV;

    [waveTimeMs, waveAV] = decimate_trace(adcAV, sampleRateHz, opt.WaveformSamples);
    [~, waveBV] = decimate_trace(adcBV, sampleRateHz, opt.WaveformSamples);
    [envTimeMs, envAMin, envAMax] = make_envelope(adcAV, sampleRateHz, opt.EnvelopeBins);
    [~, envBMin, envBMax] = make_envelope(adcBV, sampleRateHz, opt.EnvelopeBins);

    fig = figure('Name', ['DS capture ' frameTag], 'Color', 'w');
    fig.Position(3:4) = [1380 920];
    tl = tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    axInfo = nexttile(tl, 1);
    axis(axInfo, 'off');
    text(axInfo, 0.01, 0.98, build_info_text(frameTag, waveFile, metadata, summary, stats, sampleCount, frameMs), ...
        'Units', 'normalized', ...
        'VerticalAlignment', 'top', ...
        'HorizontalAlignment', 'left', ...
        'FontName', 'Consolas', ...
        'FontSize', 10, ...
        'Interpreter', 'none');

    axWave = nexttile(tl, 2);
    hold(axWave, 'on');
    plot(axWave, waveTimeMs, waveAV, 'Color', [0.10 0.35 0.90], 'LineWidth', 0.8, 'DisplayName', 'ADC A');
    plot(axWave, waveTimeMs, waveBV, 'Color', [0.90 0.15 0.15], 'LineWidth', 0.8, 'DisplayName', 'ADC B');
    grid(axWave, 'on');
    xlabel(axWave, 'Time in frame (ms)');
    ylabel(axWave, 'Voltage (V)');
    title(axWave, sprintf('Full-frame ADC voltage waveform (%s plotted samples)', comma_int(numel(waveTimeMs))));
    legend(axWave, 'Location', 'best');
    format_axes_plain(axWave, '%.0f', '%.3f');
    hold(axWave, 'off');

    axEnvelope = nexttile(tl, 3);
    hold(axEnvelope, 'on');
    plot_envelope(axEnvelope, envTimeMs, envAMin, envAMax, [0.10 0.35 0.90], 'ADC A envelope');
    plot_envelope(axEnvelope, envTimeMs, envBMin, envBMax, [0.90 0.15 0.15], 'ADC B envelope');
    grid(axEnvelope, 'on');
    xlabel(axEnvelope, 'Time in frame (ms)');
    ylabel(axEnvelope, 'Voltage (V)');
    title(axEnvelope, sprintf('Full-frame ADC voltage min/max envelope (%s bins)', comma_int(numel(envTimeMs))));
    legend(axEnvelope, 'Location', 'best');
    format_axes_plain(axEnvelope, '%.0f', '%.3f');
    hold(axEnvelope, 'off');

    axL2 = nexttile(tl, 4);
    plot_l2(axL2, sensor, sampleRateHz);
    title(axL2, 'L2 laser timeline');

    linkaxes([axWave axEnvelope axL2], 'x');
    set_full_frame_x([axWave axEnvelope axL2], frameMs);

    if opt.SavePng
        pngPath = fullfile(folder, [frameTag '_matlab_plot.png']);
        save_png(fig, pngPath, opt.PngDpi);
    else
        pngPath = '';
    end

    result = struct();
    result.waveFile = waveFile;
    result.metadataPath = metadataPath;
    result.summaryPath = summaryPath;
    result.sensorPath = sensorPath;
    result.frameTag = frameTag;
    result.sampleCount = sampleCount;
    result.sampleRateHz = sampleRateHz;
    result.frameMs = frameMs;
    result.adcFullScaleVpp = opt.AdcFullScaleVpp;
    result.codeToVolt = codeToVolt;
    result.stats = stats;
    result.metadata = metadata;
    result.summary = summary;
    result.sensor = sensor;
    result.figure = fig;
    result.pngPath = pngPath;
end

function opt = parse_options(varargin)
    opt = struct();
    opt.SampleRateHz = 15.625e6;
    opt.FrameCycles = 15000;
    opt.AdcFullScaleVpp = 9.0;
    opt.WaveformSamples = 250000;
    opt.EnvelopeBins = 6000;
    opt.SavePng = false;
    opt.PngDpi = 160;

    if mod(numel(varargin), 2) ~= 0
        error('Options must be name/value pairs.');
    end
    for k = 1:2:numel(varargin)
        name = char(varargin{k});
        value = varargin{k + 1};
        if ~isfield(opt, name)
            error('Unknown option: %s', name);
        end
        opt.(name) = value;
    end
end

function adc = read_wave_int16(waveFile)
    fid = fopen(waveFile, 'rb', 'ieee-le');
    if fid < 0
        error('Failed to open waveform file: %s', waveFile);
    end
    cleanup = onCleanup(@() fclose(fid));
    adc = fread(fid, [2 inf], 'int16=>int16');
    if size(adc, 1) ~= 2 || isempty(adc)
        error('Waveform file is empty or not interleaved int16 A/B: %s', waveFile);
    end
end

function metadata = read_metadata(path)
    metadata = struct();
    if exist(path, 'file') ~= 2
        return;
    end
    txt = fileread(path);
    metadata = jsondecode(txt);
end

function summary = read_summary(path)
    summary = struct();
    if exist(path, 'file') ~= 2
        return;
    end
    fid = fopen(path, 'r');
    if fid < 0
        return;
    end
    cleanup = onCleanup(@() fclose(fid));
    header = fgetl(fid);
    values = fgetl(fid);
    if ~ischar(header) || ~ischar(values)
        return;
    end
    names = strsplit(strtrim(header), ',');
    vals = strsplit(strtrim(values), ',');
    for k = 1:min(numel(names), numel(vals))
        name = matlab.lang.makeValidName(strtrim(names{k}));
        summary.(name) = strtrim(vals{k});
    end
end

function sensor = read_sensor(path)
    sensor = table();
    if exist(path, 'file') ~= 2
        return;
    end
    sensor = readtable(path, 'Delimiter', ',');
end

function [timeMs, yd] = decimate_trace(y, sampleRateHz, maxPoints)
    n = numel(y);
    if isinf(maxPoints) || n <= maxPoints
        idx = 1:n;
    else
        idx = unique(round(linspace(1, n, max(2, round(maxPoints)))));
    end
    yd = y(idx);
    timeMs = (idx - 1) / sampleRateHz * 1000.0;
end

function [timeMs, yMin, yMax] = make_envelope(y, sampleRateHz, maxBins)
    n = numel(y);
    if n <= maxBins
        timeMs = (0:(n - 1)) / sampleRateHz * 1000.0;
        yd = double(y(:)).';
        yMin = yd;
        yMax = yd;
        return;
    end

    binCount = min(maxBins, n);
    binSize = floor(n / binCount);
    usable = binSize * binCount;
    yr = reshape(y(1:usable), binSize, binCount);
    yMin = double(min(yr, [], 1));
    yMax = double(max(yr, [], 1));
    centerSamples = ((0:(binCount - 1)) * binSize) + (binSize - 1) / 2;
    timeMs = centerSamples / sampleRateHz * 1000.0;
end

function plot_envelope(ax, t, yMin, yMax, color, displayName)
    plot(ax, t, yMax, '-', 'Color', color, 'LineWidth', 1.0, ...
        'DisplayName', [displayName ' max']);
    plot(ax, t, yMin, '--', 'Color', color, 'LineWidth', 1.0, ...
        'DisplayName', [displayName ' min']);
end

function plot_l2(ax, sensor, sampleRateHz)
    cla(ax);
    if isempty(sensor) || ~ismember('l2_um', sensor.Properties.VariableNames)
        axis(ax, 'off');
        text(ax, 0.01, 0.5, 'No sensor timeline CSV found.', ...
            'Units', 'normalized', 'Interpreter', 'none');
        return;
    end

    if ismember('timestamp_us', sensor.Properties.VariableNames)
        tMs = double(sensor.timestamp_us) / 1000.0;
    elseif ismember('adc_sample_index', sensor.Properties.VariableNames)
        tMs = double(sensor.adc_sample_index) / sampleRateHz * 1000.0;
    else
        tMs = 1:height(sensor);
    end

    l2 = double(sensor.l2_um);
    stairs(ax, tMs, l2, '-o', 'Color', [0.05 0.55 0.20], ...
        'LineWidth', 1.2, 'MarkerSize', 4, 'DisplayName', 'L2');
    grid(ax, 'on');
    xlabel(ax, 'Time in frame (ms)');
    ylabel(ax, 'L2 (um)');
    legend(ax, 'Location', 'best');
    format_axes_plain(ax, '%.0f', '%.1f');
end

function txt = build_info_text(frameTag, waveFile, metadata, summary, stats, sampleCount, frameMs)
    lines = {};
    lines{end + 1} = sprintf('%s | samples/ch=%s | duration=%.3f ms | file=%s', ...
        frameTag, comma_int(sampleCount), frameMs, waveFile);
    lines{end + 1} = sprintf('Voltage: A min/max/pp=%.6f/%.6f/%.6f V, B min/max/pp=%.6f/%.6f/%.6f V', ...
        stats.aMinV, stats.aMaxV, stats.aPpV, stats.bMinV, stats.bMaxV, stats.bPpV);
    lines{end + 1} = sprintf('Raw int16: A min/max/pp=%.0f/%.0f/%.0f codes, B min/max/pp=%.0f/%.0f/%.0f codes', ...
        stats.aCodeMin, stats.aCodeMax, stats.aCodePp, stats.bCodeMin, stats.bCodeMax, stats.bCodePp);

    if isfield(metadata, 'wave') && isfield(metadata, 'sensor_timeline')
        lines{end + 1} = sprintf('UDP wave: %s/%s chunks, missing=%s, dup=%s, bad=%s', ...
            field_to_str(metadata.wave, 'received_chunks'), ...
            field_to_str(metadata.wave, 'total_chunks'), ...
            missing_to_str(metadata.wave, 'missing_chunks'), ...
            field_to_str(metadata.wave, 'duplicate_chunks'), ...
            field_to_str(metadata.wave, 'bad_packets'));
        lines{end + 1} = sprintf('UDP sensor: %s/%s chunks, missing=%s, records=%s, overflow=%s', ...
            field_to_str(metadata.sensor_timeline, 'received_chunks'), ...
            field_to_str(metadata.sensor_timeline, 'total_chunks'), ...
            missing_to_str(metadata.sensor_timeline, 'missing_chunks'), ...
            field_to_str(metadata.sensor_timeline, 'total_records'), ...
            summary_field(summary, 'ls_overflow'));
    elseif ~isempty(fieldnames(metadata))
        lines{end + 1} = 'Metadata JSON found, but expected wave/sensor_timeline fields are missing.';
    else
        lines{end + 1} = 'Metadata JSON not found.';
    end

    lines{end + 1} = sprintf('Summary: A raw_pp=%s, B raw_pp=%s, A mVpp=%s, B mVpp=%s, status=%s, missed_total=%s', ...
        summary_field(summary, 'adc_a_raw_pp'), ...
        summary_field(summary, 'adc_b_raw_pp'), ...
        summary_field(summary, 'adc_a_mVpp'), ...
        summary_field(summary, 'adc_b_mVpp'), ...
        summary_field(summary, 'status'), ...
        summary_field(summary, 'missed_total'));
    lines{end + 1} = sprintf('Calibration: state=%s, valid=%s, gain_a_ppm=%s, gain_b_ppm=%s, residual_uV=%s', ...
        summary_field(summary, 'cal_state'), ...
        summary_field(summary, 'cal_valid'), ...
        summary_field(summary, 'gain_a_ppm'), ...
        summary_field(summary, 'gain_b_ppm'), ...
        summary_field(summary, 'cal_zero_residual_uV'));

    txt = strjoin(lines, sprintf('\n'));
end

function value = summary_field(summary, fieldName)
    if isstruct(summary) && isfield(summary, fieldName)
        value = value_to_char(summary.(fieldName));
    else
        value = '-';
    end
end

function value = field_to_str(s, fieldName)
    if isstruct(s) && isfield(s, fieldName)
        value = value_to_char(s.(fieldName));
    else
        value = '-';
    end
end

function format_axes_plain(ax, xFmt, yFmt)
    ax.XAxis.Exponent = 0;
    ax.YAxis.Exponent = 0;
    xtickformat(ax, xFmt);
    ytickformat(ax, yFmt);
end

function set_full_frame_x(axesList, frameMs)
    ticks = 0:50:frameMs;
    if isempty(ticks) || ticks(end) < frameMs
        ticks = [ticks frameMs]; %#ok<AGROW>
    end
    for k = 1:numel(axesList)
        ax = axesList(k);
        xlim(ax, [0 frameMs]);
        ax.XAxis.Exponent = 0;
        ax.XTick = ticks;
        xtickformat(ax, '%.0f');
    end
end

function value = missing_to_str(s, fieldName)
    if ~isstruct(s) || ~isfield(s, fieldName)
        value = '-';
        return;
    end
    missing = s.(fieldName);
    if isempty(missing)
        value = '0';
        return;
    end
    missing = missing(:).';
    shown = missing(1:min(numel(missing), 10));
    value = sprintf('%d', numel(missing));
    value = [value ' [' sprintf('%d ', shown) ']']; %#ok<AGROW>
    value = strrep(value, ' ]', ']');
    if numel(missing) > numel(shown)
        value = [value '...']; %#ok<AGROW>
    end
end

function s = comma_int(n)
    s = sprintf('%.0f', double(n));
    signPart = '';
    if ~isempty(s) && s(1) == '-'
        signPart = '-';
        s = s(2:end);
    end
    k = length(s) - 3;
    while k > 0
        s = [s(1:k) ',' s((k + 1):end)]; %#ok<AGROW>
        k = k - 3;
    end
    s = [signPart s];
end

function value = value_to_char(x)
    if isempty(x)
        value = '';
    elseif isnumeric(x)
        if isscalar(x)
            value = plain_number(x, 6);
        else
            parts = cell(1, numel(x));
            for k = 1:numel(x)
                parts{k} = plain_number(x(k), 6);
            end
            value = ['[' strjoin(parts, ' ') ']'];
        end
    elseif islogical(x)
        value = sprintf('%d', x);
    elseif ischar(x)
        value = x;
    else
        value = strtrim(evalc('disp(x)'));
    end
end

function value = plain_number(x, precision)
    if abs(x - round(x)) < eps(max(1, abs(x)))
        value = sprintf('%.0f', x);
    else
        fmt = sprintf('%%.%df', precision);
        value = sprintf(fmt, x);
        value = regexprep(value, '0+$', '');
        value = regexprep(value, '\.$', '');
    end
end

function save_png(fig, pngPath, dpi)
    if exist('exportgraphics', 'file') == 2
        exportgraphics(fig, pngPath, 'Resolution', dpi);
    else
        print(fig, pngPath, '-dpng', sprintf('-r%d', dpi));
    end
end
