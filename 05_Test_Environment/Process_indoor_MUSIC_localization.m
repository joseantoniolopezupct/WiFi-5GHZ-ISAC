%% ========================================================================
%  Process_indoor_MUSIC_localization.m
%
%  Description:
%    RSSI-based indoor direction-of-arrival (DoA) estimation using correlation
%    with calibrated steering vectors. Loads the steering matrix from
%    anechoic chamber calibration and indoor RSSI measurements from
%    multiple angular positions. Performs correlation-based angle
%    estimation with pseudo-spectrum analysis and computes MAE.
%
%  Dataset Structure employed and data generated:
%	05_Test_Environment/
%	 └── Process_indoor_MUSIC_localization.m (this script)
%
%  Dataset Structure:
% 	Anechoic_chamber_data/
%    └── steering_matrix_normalized.mat (input)
%   
%  Indoor_test_environment_data
%    └── <antenna>/<angle_deg>/<ch>/
%        │   └── Measurements_Ch<ch>_BW<bw>.txt
%        └── Localization/<antenna>_MUSIC/
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
%  PATH CONFIGURATION (automatic, relative to this script)
%  ========================================================================

script_dir = fileparts(mfilename('fullpath'));
if isempty(script_dir)
    script_dir = pwd;
end

% Script is in:  <root>/Processing/
% root = 03_Indoor_environment/
root_dir     = fullfile(script_dir, '..');


%% ========================================================================
%  CONFIGURATION (MODIFY HERE)
%  ========================================================================

% --- Antenna under test ---
antenna = 'LWA'; 

% --- Bandwidth ---
bandwidth = 80;
bw_str = num2str(bandwidth);

% --- Wi-Fi channels ---
channels = [44, 64, 108, 124, 140, 161];

% --- Measurement points (ground-truth angles, degrees) ---
measured_angles = [0, 20, -20, 40, -40, 50, -50];

% --- Samples per point ---
num_samples = 400;

% --- Visual style per measurement point ---
point_styles = struct( ...
    'color',      {[0 0 1], [1 0 0], [1 0 0], [0 0.5 0], [0 0.5 0], [0 0 0], [0 0 0]}, ...
    'line_style', {'-',     '-',     '--',    '-',       '--',      '-',     '--'});

% --- Paths ---
steering_mat_path = fullfile(root_dir, 'Anechoic_chamber_Data', 'steering_matrix_normalized.mat');

indoor_data_dir = fullfile(root_dir, 'Indoor_test_environment_data', antenna);

results_dir = fullfile(root_dir, 'Indoor_test_environment_data', 'Localization', [antenna '_MUSIC']);
if ~exist(results_dir, 'dir')
    mkdir(results_dir);
end

N_points   = length(measured_angles);
N_channels = length(channels);

fprintf('Antenna              : %s\n', antenna);
fprintf('Steering matrix      : %s\n', steering_mat_path);
fprintf('Indoor data directory: %s\n', indoor_data_dir);
fprintf('Output directory     : %s\n\n', results_dir);

%% ========================================================================
%  STEP 1: LOAD CALIBRATED STEERING MATRIX
%  ========================================================================

fprintf('--- Step 1: Loading steering matrix ---\n');

if ~isfile(steering_mat_path)
    error('Steering matrix not found:\n  %s\nRun compute_steering_vectors.m first.', steering_mat_path);
end

cal = load(steering_mat_path);
steering_matrix_normalized = cal.steering_matrix_normalized;
angle_list             = cal.angle_list;
column_labels              = cal.column_labels;

fprintf('  Matrix size   : %d angles x %d vectors\n', size(steering_matrix_normalized));
fprintf('  Angular range : [%d, %d] degrees\n\n', angle_list(1), angle_list(end));

%% ========================================================================
%  STEP 2: LOAD INDOOR MEASUREMENT DATA
%  ========================================================================

fprintf('--- Step 2: Loading indoor data ---\n');

combined_matrix_total = [];
combined_matrix_total_mean = zeros(N_points, 2 * N_channels);

for a_idx = 1:N_points
    current_angle = measured_angles(a_idx);
    angle_folder  = sprintf('%ddeg', current_angle);

    RSSI1_matrix = NaN(num_samples, N_channels);
    RSSI2_matrix = NaN(num_samples, N_channels);

    for ch_idx = 1:N_channels
        ch = channels(ch_idx);
        file_name = sprintf('Measurements_Ch%d_BW%d.txt', ch, bandwidth);
        file_path = fullfile(indoor_data_dir, angle_folder, num2str(ch), file_name);

        if ~isfile(file_path)
            warning('File not found: %s', file_path);
            continue;
        end

        data = readmatrix(file_path);

        if size(data, 1) >= num_samples
            data = data(1:num_samples, :);
        else
            warning('Channel %d, angle %d: fewer than %d samples.', ch, current_angle, num_samples);
        end

        RSSI1_matrix(:, ch_idx) = data(:, 2);
        RSSI2_matrix(:, N_channels - ch_idx + 1) = data(:, 3);
    end

    combined_angle = [RSSI2_matrix, RSSI1_matrix];
    combined_matrix_total = [combined_matrix_total; combined_angle]; %#ok<AGROW>
    combined_matrix_total_mean(a_idx, :) = mean(combined_angle, 1);

    fprintf('  Point %+3d deg: loaded\n', current_angle);
end

fprintf('  Combined matrix: %d samples x %d columns\n\n', size(combined_matrix_total));

%% ========================================================================
%  STEP 3: NORMALIZE INDOOR DATA
%  ========================================================================

fprintf('--- Step 3: Normalizing ---\n');

norm_vector = zeros(1, size(combined_matrix_total_mean, 2));
for j = 1:size(combined_matrix_total_mean, 2)
    norm_vector(j) = max(combined_matrix_total_mean(:, j));
end

combined_matrix_normalized = combined_matrix_total;
for j = 1:size(combined_matrix_total, 2)
    combined_matrix_normalized(:, j) = combined_matrix_normalized(:, j) - norm_vector(j);
end

combined_mean_normalized = combined_matrix_total_mean;
for j = 1:size(combined_matrix_total_mean, 2)
    combined_mean_normalized(:, j) = combined_mean_normalized(:, j) - norm_vector(j);
end

fprintf('  Done.\n\n');

%% ========================================================================
%  STEP 4: ANGLE ESTIMATION AND MAE
%  ========================================================================

fprintf('--- Step 4: Angle estimation ---\n');

angle_candidates = angle_list;
num_candidates   = length(angle_candidates);

MAE_per_point    = zeros(N_points, 1);
estimated_angles = zeros(N_points, num_samples);

for a_idx = 1:N_points
    gt_angle = measured_angles(a_idx);

    row_start = (a_idx - 1) * num_samples + 1;
    row_end   = a_idx * num_samples;
    eval_matrix = combined_matrix_normalized(row_start:row_end, :);

    sample_errors = zeros(num_samples, 1);

    for s = 1:num_samples
        sample_vector = eval_matrix(s, :);

        corr_values = zeros(num_candidates, 1);
        for cand = 1:num_candidates
            corr_mat = corrcoef(steering_matrix_normalized(cand, :), sample_vector);
            corr_values(cand) = corr_mat(1, 2);
        end

        max_corr = max(corr_values);
        min_corr = min(corr_values);
        norm_corr = (corr_values - min_corr) / (max_corr - min_corr);

        pseudo_spectrum = 1 ./ (1 - norm_corr / max(norm_corr));
        pseudo_spectrum(isinf(pseudo_spectrum)) = NaN;
        max_ps = max(pseudo_spectrum);
        pseudo_spectrum(isnan(pseudo_spectrum)) = max_ps * 2;
        pseudo_spectrum = pseudo_spectrum / max(pseudo_spectrum);
        pseudo_spectrum = 10 * log10(pseudo_spectrum);

        [~, max_idx] = max(pseudo_spectrum);
        predicted_angle = angle_candidates(max_idx);

        estimated_angles(a_idx, s) = predicted_angle;
        sample_errors(s) = gt_angle - predicted_angle;
    end

    MAE_per_point(a_idx) = mean(abs(sample_errors));
    fprintf('  Point %+3d deg: MAE = %.2f deg\n', gt_angle, MAE_per_point(a_idx));
end

fprintf('\n  Overall MAE: %.2f deg\n\n', mean(MAE_per_point));

%% ========================================================================
%  STEP 5: SAVE RESULTS
%  ========================================================================

save(fullfile(results_dir, 'localization_results.mat'), ...
    'measured_angles', 'channels', 'bandwidth', 'antenna', ...
    'MAE_per_point', 'estimated_angles', ...
    'combined_matrix_total', 'combined_matrix_normalized', ...
    'combined_matrix_total_mean', 'combined_mean_normalized', ...
    'norm_vector');
fprintf('Results saved.\n\n');

%% ========================================================================
%  FIGURE 1: STEERING VECTOR VS MEASURED RSSI (bar chart)
%  ========================================================================

display_angle_steering = -50;
display_point_index    = 7;

[found, steer_idx] = ismember(display_angle_steering, angle_list);
if ~found
    [~, steer_idx] = min(abs(angle_list - display_angle_steering));
    display_angle_steering = angle_list(steer_idx);
end

y_steering = steering_matrix_normalized(steer_idx, :);
y_measured = combined_mean_normalized(display_point_index, :);
x_positions = 1:2*N_channels;

fig = figure('Name', 'Steering vs Measured', 'Color', 'w');
hold on;
h_blue_rep = []; h_green_rep = [];
for i = 1:length(x_positions)
    if y_steering(i) > y_measured(i)
        b_blue  = bar(x_positions(i), y_steering(i), 'FaceColor', 'b', 'BaseValue', -30, 'BarWidth', 0.9);
        b_green = bar(x_positions(i), y_measured(i),  'FaceColor', 'g', 'BaseValue', -30, 'BarWidth', 0.9);
    else
        b_green = bar(x_positions(i), y_measured(i),  'FaceColor', 'g', 'BaseValue', -30, 'BarWidth', 0.9);
        b_blue  = bar(x_positions(i), y_steering(i), 'FaceColor', 'b', 'BaseValue', -30, 'BarWidth', 0.9);
    end
    if i == 1, h_blue_rep = b_blue; h_green_rep = b_green; end
end
hold off; grid on; ylim([-30, 0]);
set(gca, 'XTick', x_positions, 'XTickLabel', column_labels, 'FontSize', 14);
xlabel('Port / Wi-Fi Channel', 'FontSize', 16); ylabel('Normalized Level (dB)', 'FontSize', 16);
title(sprintf('%s - Steering vs Measured at %+d%s', antenna, measured_angles(display_point_index), char(176)), 'FontSize', 18);
legend([h_blue_rep, h_green_rep], {'Calibrated steering', 'Measured RSSI'}, 'FontSize', 14);
saveas(fig, fullfile(results_dir, 'comparison_steering_vs_measured.fig'));
saveas(fig, fullfile(results_dir, 'comparison_steering_vs_measured.png'));
close(fig);

%% ========================================================================
%  FIGURE 2: PSEUDO-SPECTRUM
%  ========================================================================

pseudo_spec_sample_indices = [11, 170, 1, 148, 253, 19, 230];

fig = figure('Name', 'Pseudo-spectrum', 'Color', 'w');
hold on;
for a_idx = 1:N_points
    sample_row = pseudo_spec_sample_indices(a_idx);
    if sample_row < 1 || sample_row > num_samples, sample_row = 1; end

    row_start = (a_idx - 1) * num_samples + sample_row;
    sample_vector = combined_matrix_normalized(row_start, :);

    corr_values = zeros(num_candidates, 1);
    for cand = 1:num_candidates
        corr_mat = corrcoef(steering_matrix_normalized(cand, :), sample_vector);
        corr_values(cand) = corr_mat(1, 2);
    end
    max_corr = max(corr_values); min_corr = min(corr_values);
    norm_corr = (corr_values - min_corr) / (max_corr - min_corr);
    ps = 1 ./ (1 - norm_corr / max(norm_corr));
    ps(isinf(ps)) = NaN; max_ps = max(ps);
    ps(isnan(ps)) = max_ps * 2;
    ps = 10 * log10(ps / max(ps));

    plot(angle_candidates, ps, 'Color', point_styles(a_idx).color, ...
        'LineStyle', point_styles(a_idx).line_style, 'LineWidth', 1.5, ...
        'DisplayName', sprintf('%+d%s', measured_angles(a_idx), char(176)));
end
xlabel('Angle (\circ)', 'FontSize', 14); ylabel('Pseudo-spectrum (dB)', 'FontSize', 14);
title(sprintf('%s - Pseudo-spectrum - BW %d MHz', antenna, bandwidth), 'FontSize', 16);
legend('Location', 'best'); grid on;
saveas(fig, fullfile(results_dir, 'pseudo_spectrum.fig'));
saveas(fig, fullfile(results_dir, 'pseudo_spectrum.png'));
close(fig);

%% ========================================================================
%  FIGURE 3: MEASURED RSSI BAR CHART
%  ========================================================================

bar_point_index = 7;
y_bar = combined_mean_normalized(bar_point_index, :);

fig = figure('Name', 'Measured RSSI', 'Color', 'w');
bar(y_bar, 'FaceColor', [0.2 0.7 0.3], 'BaseValue', -30);
grid on; ylim([-30 0]);
set(gca, 'XTick', 1:2*N_channels, 'XTickLabel', column_labels, 'FontSize', 14);
xlabel('Port / Wi-Fi Channel', 'FontSize', 16); ylabel('Normalized Level (dB)', 'FontSize', 16);
title(sprintf('%s - Measured RSSI at %+d%s', antenna, measured_angles(bar_point_index), char(176)), 'FontSize', 18);
saveas(fig, fullfile(results_dir, sprintf('measured_rssi_%+ddeg.fig', measured_angles(bar_point_index))));
saveas(fig, fullfile(results_dir, sprintf('measured_rssi_%+ddeg.png', measured_angles(bar_point_index))));
close(fig);

%% ========================================================================
%  FIGURE 4: MAE SUMMARY
%  ========================================================================

fig = figure('Name', 'MAE Summary', 'Color', 'w');
bar_data = categorical(arrayfun(@(x) sprintf('%+d%s', x, char(176)), measured_angles, 'UniformOutput', false));
bar_data = reordercats(bar_data, arrayfun(@(x) sprintf('%+d%s', x, char(176)), measured_angles, 'UniformOutput', false));
bar(bar_data, MAE_per_point, 'FaceColor', [0.2 0.4 0.8]);
grid on; ylabel('MAE (degrees)', 'FontSize', 14); xlabel('Measurement Point', 'FontSize', 14);
title(sprintf('%s - MAE - BW %d MHz', antenna, bandwidth), 'FontSize', 16);
for i = 1:N_points
    text(i, MAE_per_point(i) + 0.3, sprintf('%.1f%s', MAE_per_point(i), char(176)), ...
        'HorizontalAlignment', 'center', 'FontSize', 11);
end
saveas(fig, fullfile(results_dir, 'mae_summary.fig'));
saveas(fig, fullfile(results_dir, 'mae_summary.png'));
close(fig);

%% ========================================================================
%  SUMMARY
%  ========================================================================

fprintf('\n=== PROCESSING COMPLETE ===\n');
fprintf('Antenna              : %s\n', antenna);
fprintf('Bandwidth            : %d MHz\n', bandwidth);
fprintf('Channels             : %s\n', num2str(channels));
fprintf('Measurement points   : %s\n', num2str(measured_angles));
fprintf('Overall MAE          : %.2f deg\n', mean(MAE_per_point));
fprintf('Figures saved to     : %s\n', results_dir);