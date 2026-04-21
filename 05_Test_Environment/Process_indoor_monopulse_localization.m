%% ========================================================================
%  process_indoor_monopulse_localization.m
%
%  Description:
%    Monopulse-based Direction of Arrival (DoA) estimation using a
%    Panel antenna array. Loads calibration data (normalization
%    factors and monopulse functions) from the anechoic chamber processing
%    and indoor RSSI measurements from multiple angular positions.
%    Normalizes indoor data, computes monopulse values, and estimates
%    the angle of arrival by matching against the calibrated monopulse
%    function (FM). Reports MAE per channel and measurement point.
%
%  Dataset Structure employed and data generated:
%	05_Test_Environment/
%	 └── process_indoor_monopulse_localization.m   (this script)
%
%  Dataset Structure:
% 	Anechoic_chamber_data/
%    └── Monopulse_function_CH<ch>_BW80.mat (input)
%   
%  Indoor_test_environment_data
%    └── <antenna>/<angle_deg>/<ch>/
%        │   └── Measurements_Ch<ch>_BW<bw>.txt
%        └── Localization/<antenna>_Monopulse/
%
%
%  Authors: [Guillermo Inglés Muñoz, José Antonio López Pastor]
%  Date:    [04/16/2026]
%  License: [CC-BY-4.0]
%  DOI:     [Dataset DOI]
% =========================================================================

clear all;
close all;
clc;

%% ========================================================================
%  PATH CONFIGURATION
%  ========================================================================

script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir)
    script_dir = pwd;
end

% DESPUÉS (sube 2 niveles para llegar a "Dataset - LWA coms")
root_dir     = fullfile(script_dir, '..');          % = 03_Indoor_environment/

% Antenna type
antenna = 'Panel';

% Path to calibration .mat files
calibration_dir = fullfile(root_dir, 'Anechoic_chamber_Data');

indoor_data_dir = fullfile(root_dir, 'Indoor_test_environment_data', antenna);

results_dir = fullfile(root_dir,'Indoor_test_environment_data', 'Localization', [antenna '_Monopulse']);
if ~exist(results_dir, 'dir')
    mkdir(results_dir);
end

fprintf('Dataset root         : %s\n', root_dir);
fprintf('Antenna              : %s\n', antenna);
fprintf('Calibration directory: %s\n', calibration_dir);
fprintf('Indoor data directory: %s\n', indoor_data_dir);
fprintf('Output directory     : %s\n\n', results_dir);

%% ========================================================================
%  CONFIGURATION (MODIFY HERE)
%  ========================================================================

% Wi-Fi channels to process
channels = [64, 161];

% Measurement points: ground-truth angles (degrees), sorted ascending
angles_req = [-50, -40, -20, 0, 20, 40, 50];

% Bandwidth
bandwidth = 80;

% Number of samples per measurement point
num_samples = 400;

% Monopulse FoV: indices of FM to use for angle estimation
% FM(76:116) corresponds to -20:20 degrees in a 191-point sweep (-95:95)
fm_start_idx = 76;
fm_end_idx   = 116;
estimation_angles = -20:20;

N_channels = length(channels);
N_points   = length(angles_req);

% Visual style per measurement point
point_styles = struct( ...
    'color',      {[0 0 1], [0 0.5 0], [0 0.5 0], [0 0 0], [1 0 0], [1 0 0], [0 0 0]}, ...
    'line_style', {'-',     '-',       '--',      '-',     '-',     '--',    '--'});
point_labels = arrayfun(@(a) sprintf('%+d%s', a, char(186)), angles_req, 'UniformOutput', false);

%% ========================================================================
%  STEP 1: LOAD CALIBRATION DATA
%  ========================================================================

fprintf('--- Step 1: Loading calibration data ---\n');

cam = struct();

for k = 1:N_channels
    ch = channels(k);
    key = sprintf('ch%d', ch);

    cal_name = sprintf('Monopulse_function_CH%d_BW%d.mat', ch, bandwidth);
    cal_path = fullfile(calibration_dir, cal_name);

    if ~isfile(cal_path)
        warning('Calibration file not found: %s', cal_path);
        cam.(key) = struct();
        continue;
    end

    S = load(cal_path, 'factor_neg', 'factor_pos', 'FM');

    cam.(key).factor_neg = S.factor_neg;
    cam.(key).factor_pos = S.factor_pos;
    cam.(key).FM         = S.FM;

    fprintf('  Channel %3d: factor_neg=%.2f, factor_pos=%.2f, FM length=%d\n', ...
        ch, S.factor_neg, S.factor_pos, length(S.FM));
end

fprintf('  Done.\n\n');

%% ========================================================================
%  STEP 2: LOAD INDOOR MEASUREMENT DATA
%  ========================================================================

fprintf('--- Step 2: Loading indoor measurement data ---\n');

data = struct();

for ch = channels
    key = sprintf('ch%d', ch);

    rssi1Mat = NaN(N_points, num_samples);
    rssi2Mat = NaN(N_points, num_samples);

    for ai = 1:N_points
        ang = angles_req(ai);
        angle_folder = sprintf('%ddeg', ang);

        file_name = sprintf('Measurements_Ch%d_BW%d.txt', ch, bandwidth);
        file_path = fullfile(indoor_data_dir, angle_folder, num2str(ch), file_name);

        if ~isfile(file_path)
            warning('File not found: %s', file_path);
            continue;
        end

        opts = detectImportOptions(file_path, 'Delimiter', ',');
        T = readtable(file_path, opts);

        r1 = double(T.rssi1(:));
        r2 = double(T.rssi2(:));

        n = numel(r1);
        if n < num_samples
            r1(n+1:num_samples, 1) = NaN;
            r2(n+1:num_samples, 1) = NaN;
            fprintf('  Warning: Ch.%d angle %d has %d samples (padding to %d)\n', ch, ang, n, num_samples);
        end

        rssi1Mat(ai, 1:num_samples) = r1(1:num_samples).';
        rssi2Mat(ai, 1:num_samples) = r2(1:num_samples).';
    end

    data.(key).rssi1 = rssi1Mat;
    data.(key).rssi2 = rssi2Mat;
end

fprintf('  Done.\n\n');

%% ========================================================================
%  STEP 3: NORMALIZE INDOOR DATA USING CALIBRATION FACTORS
%  ========================================================================

fprintf('--- Step 3: Normalizing indoor data ---\n');

data_norm = data;

for ch = channels
    key = sprintf('ch%d', ch);
    if ~isfield(cam.(key), 'factor_pos') || ~isfield(cam.(key), 'factor_neg')
        warning('Calibration factors missing for channel %d. Skipping normalization.', ch);
        continue;
    end
    data_norm.(key).rssi1 = data.(key).rssi1 + abs(cam.(key).factor_pos);
    data_norm.(key).rssi2 = data.(key).rssi2 + abs(cam.(key).factor_neg);
end

fprintf('  Done.\n\n');

%% ========================================================================
%  STEP 4: CONVERT TO LINEAR AND COMPUTE MONOPULSE VALUES
%  ========================================================================

fprintf('--- Step 4: Computing monopulse values ---\n');

data_norm_linear = struct();
monopulse_values = struct();

for ch = channels
    key = sprintf('ch%d', ch);
    data_norm_linear.(key).rssi1 = 10.^(data_norm.(key).rssi1 / 10);
    data_norm_linear.(key).rssi2 = 10.^(data_norm.(key).rssi2 / 10);

    monopulse_values.(key).MV = ...
        (data_norm_linear.(key).rssi1 - data_norm_linear.(key).rssi2) ./ ...
        (data_norm_linear.(key).rssi1 + data_norm_linear.(key).rssi2);
end

fprintf('  Done.\n\n');

%% ========================================================================
%  STEP 5: MONOPULSE ANGLE ESTIMATION AND MAE
%  ========================================================================

fprintf('--- Step 5: Angle estimation ---\n');

estimates = struct();

for ch = channels
    key = sprintf('ch%d', ch);
    estimates.(key).FM = cam.(key).FM(fm_start_idx:fm_end_idx);
end

T_results = table(angles_req(:), 'VariableNames', {'Angle'});

for ch = channels
    key = sprintf('ch%d', ch);

    estimates.(key).estimated_angle = NaN(N_points, num_samples);
    estimates.(key).true_angle      = NaN(N_points, num_samples);
    estimates.(key).error           = NaN(N_points, num_samples);
    estimates.(key).MAE             = NaN(N_points, 1);
    estimates.(key).pseudo_spectrum = NaN(N_points, length(estimation_angles));

    for i = 1:N_points
        for j = 1:size(monopulse_values.(key).MV, 2)
            FE = abs(estimates.(key).FM - monopulse_values.(key).MV(i, j));

            [~, idx_min] = min(FE);

            estimates.(key).estimated_angle(i, j) = estimation_angles(idx_min);
            estimates.(key).true_angle(i, j)      = angles_req(i);
            estimates.(key).error(i, j)           = angles_req(i) - estimation_angles(idx_min);

            pseudo_spectrum = 1 ./ FE;
            pseudo_spectrum(isinf(pseudo_spectrum)) = NaN;
            max_ps = max(pseudo_spectrum, [], 'omitnan');
            pseudo_spectrum(isnan(pseudo_spectrum)) = max_ps * 2;
            pseudo_spectrum = pseudo_spectrum / max(pseudo_spectrum);
            pseudo_spectrum = 10 * log10(pseudo_spectrum);

            estimates.(key).pseudo_spectrum(i, :) = pseudo_spectrum;
        end

        estimates.(key).MAE(i) = mean(abs(estimates.(key).error(i, :)));
    end

    T_results.(sprintf('MAE_ch%d', ch)) = estimates.(key).MAE(:);
end

MAE_mat = zeros(N_points, N_channels);
for k = 1:N_channels
    MAE_mat(:, k) = T_results.(sprintf('MAE_ch%d', channels(k)));
end
[~, idx_min] = min(MAE_mat, [], 2);
T_results.Best_Channel = channels(idx_min).';

fprintf('\n');
disp(T_results);

%% ========================================================================
%  STEP 6: SAVE RESULTS
%  ========================================================================

save(fullfile(results_dir, 'monopulse_doa_results.mat'), ...
    'angles_req', 'channels', 'bandwidth', 'antenna', ...
    'estimates', 'T_results', 'MAE_mat', ...
    'data', 'data_norm', 'monopulse_values', 'cam');

fprintf('Results saved to: %s\n\n', results_dir);

%% ========================================================================
%  FIGURE 1: PSEUDO-SPECTRUM (per channel, selectable)
%  ========================================================================

display_channel = 64;

display_key = sprintf('ch%d', display_channel);
P = estimates.(display_key).pseudo_spectrum;

figure('Name', sprintf('Pseudo-spectrum - Channel %d', display_channel), 'Color', 'w');
hold on; grid on; box on;

for k = 1:N_points
    plot(estimation_angles, P(k, :), ...
        'LineWidth', 2, ...
        'Color', point_styles(k).color, ...
        'LineStyle', point_styles(k).line_style, ...
        'DisplayName', point_labels{k});
end

xlabel('Angle (\circ)', 'FontSize', 14);
ylabel('Level (dB, normalized)', 'FontSize', 14);
title(sprintf('Pseudo-spectrum - %s Ch.%d (FoV %d%s to %d%s)', ...
    antenna, display_channel, estimation_angles(1), char(176), estimation_angles(end), char(176)), 'FontSize', 16);
legend('Location', 'best');
xlim([estimation_angles(1), estimation_angles(end)]);
hold off;

saveas(gcf, fullfile(results_dir, sprintf('pseudo_spectrum_ch%d.png', display_channel)));

%% ========================================================================
%  SUMMARY
%  ========================================================================

fprintf('\n=== PROCESSING COMPLETE ===\n');
fprintf('Antenna              : %s\n', antenna);
fprintf('Bandwidth            : %d MHz\n', bandwidth);
fprintf('Channels             : %s\n', num2str(channels));
fprintf('Measurement points   : %s\n', num2str(angles_req));
fprintf('Samples per point    : %d\n', num_samples);
fprintf('Estimation FoV       : [%d, %d] degrees\n', estimation_angles(1), estimation_angles(end));
fprintf('Results saved to     : %s\n', results_dir);