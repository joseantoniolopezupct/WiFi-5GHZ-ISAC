%% ========================================================================
%  Acquire_anechoic_digital.m
%
%  Description:
%    Real-time acquisition of digital Wi-Fi measurements in an anechoic
%    chamber using a turntable angular sweep. Receives UDP datagrams from
%    a hostapd-based access point (via Radxa), computes per-angle
%    averages for RSSI, bitrate, MCS, and throughput, and saves raw data
%    (.txt) and averaged data (.mat) for each channel.
%
%    This is a HARDWARE ACQUISITION script. It requires:
%      - A Radxa running hostapd and the UDP client script
%      - A turntable performing the angular sweep
%      - A PC running MATLAB with UDP connectivity
%
%  Output Structure:
%    Anechoic_chamber_data/
%    └── /<antenna>/<ch>/
%        ├── Measurements_Ch<ch>_BW<bw>.mat   (averaged measurements)
%        └── Measurements_Ch<ch>_BW<bw>.txt   (raw samples, CSV format)
%    
%
%  Raw Data Columns (.txt):
%    timestamp, rssi1, rssi2, tx_bitrate, tx_mcs, rx_bitrate, rx_mcs,
%    throughput, channel, bandwidth, angle
%
%  Averaged Data Variables (.mat):
%    rssi1_mean, rssi2_mean, tx_bitrate_mean, tx_mcs_mean,
%    rx_bitrate_mean, rx_mcs_mean, throughput_mean, angle_list
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

% Script is in:  02_Anechoic_chamber/Acquisition/PC/
% Go up two levels to reach 02_Anechoic_chamber/
anechoic_dir = fullfile(script_dir, '..', '..');

%% ========================================================================
%  CONFIGURATION (MODIFY HERE)
%  ========================================================================

% --- Antenna under test ---
antenna = 'LWA';   % Options: 'LWA', 'Panel'

% --- UDP settings ---
LOCAL_PORT = 5005;  % Must match MATLAB_PORT on the Radxa/Python sender

% --- Angular sweep ---
start_angle       = -1;
end_angle         =  1;
samples_per_angle = 10;
angle_list        = start_angle:1:end_angle;

% --- Auto-stop timeout (seconds) ---
NO_DATA_TIMEOUT = 60;

% --- Output path ---
data_dir = fullfile(anechoic_dir, 'Data', antenna);

fprintf('Antenna          : %s\n', antenna);
fprintf('Data output      : %s\n', data_dir);
fprintf('Angular range    : [%d, %d] degrees (%d points)\n', ...
    start_angle, end_angle, length(angle_list));
fprintf('Samples per angle: %d\n', samples_per_angle);
fprintf('Auto-stop timeout: %d s\n\n', NO_DATA_TIMEOUT);

%% ========================================================================
%  TURNTABLE INITIALIZATION (VISA/GPIB)
%  ========================================================================

h = visa('agilent', 'GPIB0::7::INSTR');
fopen(h);
fprintf('Turntable connected via VISA.\n');

fprintf(h, 'LD 1 DV');                                        % Select turntable
fprintf(h, ['LD ' num2str(start_angle) ' DG NP GO']);         % Move to initial angle
fprintf('Moving turntable to initial angle %d deg...\n', start_angle);
pause(10);                                                     % Wait for movement to complete
fprintf('Turntable ready at %d deg.\n\n', start_angle);

cleanupTurntable = onCleanup(@() local_cleanup_turntable(h)); 

%% ========================================================================
%  UDP INITIALIZATION
%  ========================================================================

format longG;

u = udpport("datagram", "IPV4", "LocalPort", LOCAL_PORT, "Timeout", 1);
flush(u);
fprintf('Listening on UDP port %d ...\n', LOCAL_PORT);

cleanupObj = onCleanup(@() local_cleanup(u));

%% ========================================================================
%  STATE VARIABLES
%  ========================================================================

current_bandwidth = [];
current_channel   = [];
current_angle_index = 1;
current_angle = angle_list(current_angle_index);

measurement_count       = 0;
angle_measurement_count = 0;
configurations_processed = [];

rssi1_mean      = zeros(1, length(angle_list));
rssi2_mean      = zeros(1, length(angle_list));
tx_bitrate_mean = zeros(1, length(angle_list));
tx_mcs_mean     = zeros(1, length(angle_list));
rx_bitrate_mean = zeros(1, length(angle_list));
rx_mcs_mean     = zeros(1, length(angle_list));
throughput_mean  = zeros(1, length(angle_list));

rssi1_buf = []; rssi2_buf = [];
tx_bitrate_buf = []; tx_mcs_buf = [];
rx_bitrate_buf = []; rx_mcs_buf = [];
throughput_buf = [];

fileID = -1;
data_folder_path = "";
pending = "";

last_data_time = tic;
has_received_any_data = false;

disp('Waiting for signal data...');

%% ========================================================================
%  MAIN ACQUISITION LOOP
%  ========================================================================

while true

    if u.NumDatagramsAvailable > 0

        last_data_time = tic;

        while u.NumDatagramsAvailable > 0

            dgram = read(u, 1, "uint8");
            chunk = char(dgram.Data(:))';
            pending = pending + string(chunk);

            lines = regexp(pending, '\r?\n', 'split');

            if endsWith(pending, newline) || endsWith(pending, sprintf('\n')) || endsWith(pending, sprintf('\r\n'))
                pending = "";
            else
                pending = string(lines{end});
                lines = lines(1:end-1);
            end

            for ii = 1:numel(lines)
                line = strtrim(string(lines{ii}));
                if strlength(line) == 0
                    continue;
                end

                has_received_any_data = true;
                disp("Received: " + line + "," + num2str(current_angle));

                parts = split(line, ",");
                values = str2double(parts);

                if any(isnan(values))
                    disp("Warning: non-numeric values received -> " + line);
                    continue;
                end

                if numel(values) ~= 10
                    disp("Warning: received " + numel(values) + " values (expected 10) -> " + line);
                    continue;
                end

                timestamp  = values(1);
                rssi1      = values(2);
                rssi2      = values(3);
                tx_bitrate = values(4);
                tx_mcs     = values(5);
                rx_bitrate = values(6);
                rx_mcs     = values(7);
                throughput = values(8);
                channel    = values(9);
                bandwidth  = values(10);

                % ---- Configuration change detection ----
                if isempty(current_bandwidth) || isempty(current_channel) || ...
                   current_bandwidth ~= bandwidth || current_channel ~= channel

                    if fileID > 0
                        fclose(fileID);
                        fileID = -1;
                    end

                    current_bandwidth = bandwidth;
                    current_channel   = channel;

                    measurement_count       = 0;
                    current_angle_index     = 1;
                    current_angle           = angle_list(current_angle_index);
                    angle_measurement_count = 0;

                    rssi1_mean      = zeros(1, length(angle_list));
                    rssi2_mean      = zeros(1, length(angle_list));
                    tx_bitrate_mean = zeros(1, length(angle_list));
                    tx_mcs_mean     = zeros(1, length(angle_list));
                    rx_bitrate_mean = zeros(1, length(angle_list));
                    rx_mcs_mean     = zeros(1, length(angle_list));
                    throughput_mean  = zeros(1, length(angle_list));

                    rssi1_buf = []; rssi2_buf = [];
                    tx_bitrate_buf = []; tx_mcs_buf = [];
                    rx_bitrate_buf = []; rx_mcs_buf = [];
                    throughput_buf = [];

                    configurations_processed = [configurations_processed; current_channel, current_bandwidth]; %#ok<AGROW>

                    ch_str = num2str(current_channel);
                    data_folder_path = fullfile(data_dir, ch_str);
                    if ~exist(data_folder_path, 'dir')
                        mkdir(data_folder_path);
                    end

                    txt_filename = sprintf('Measurements_Ch%d_BW%d.txt', current_channel, current_bandwidth);
                    txt_filepath = fullfile(data_folder_path, txt_filename);
                    fileID = fopen(txt_filepath, 'w');
                    fprintf(fileID, 'timestamp,rssi1,rssi2,tx_bitrate,tx_mcs,rx_bitrate,rx_mcs,throughput,channel,bandwidth,angle\n');

                    fprintf('Processing channel %d with BW %d MHz\n', current_channel, current_bandwidth);
                    fprintf('Starting measurements for angle %d\n', current_angle);
                end

                % ---- Write raw sample to file ----
                fprintf(fileID, '%f,%d,%d,%.1f,%d,%.1f,%d,%.1f,%d,%d,%d\n', ...
                    values(1), rssi1, rssi2, tx_bitrate, tx_mcs, rx_bitrate, rx_mcs, ...
                    throughput, channel, bandwidth, current_angle);

                % ---- Accumulate for averaging ----
                rssi1_buf      = [rssi1_buf; rssi1];           
                rssi2_buf      = [rssi2_buf; rssi2];           
                tx_bitrate_buf = [tx_bitrate_buf; tx_bitrate];
                tx_mcs_buf     = [tx_mcs_buf; tx_mcs];         
                rx_bitrate_buf = [rx_bitrate_buf; rx_bitrate]; 
                rx_mcs_buf     = [rx_mcs_buf; rx_mcs];         
                throughput_buf = [throughput_buf; throughput];  

                measurement_count       = measurement_count + 1;
                angle_measurement_count = angle_measurement_count + 1;

                % ---- Angle complete: compute means ----
                if angle_measurement_count >= samples_per_angle
                    fprintf('Completed %d samples for angle %d\n', samples_per_angle, current_angle);

                    rssi1_mean(current_angle_index)      = mean(rssi1_buf);
                    rssi2_mean(current_angle_index)      = mean(rssi2_buf);
                    tx_bitrate_mean(current_angle_index)  = mean(tx_bitrate_buf);
                    tx_mcs_mean(current_angle_index)      = mean(tx_mcs_buf);
                    rx_bitrate_mean(current_angle_index)  = mean(rx_bitrate_buf);
                    rx_mcs_mean(current_angle_index)      = mean(rx_mcs_buf);
                    throughput_mean(current_angle_index)   = mean(throughput_buf);

                    rssi1_buf = []; rssi2_buf = [];
                    tx_bitrate_buf = []; tx_mcs_buf = [];
                    rx_bitrate_buf = []; rx_mcs_buf = [];
                    throughput_buf = [];

                    if current_angle_index < length(angle_list)
                        current_angle_index = current_angle_index + 1;
                        current_angle = angle_list(current_angle_index);
                        angle_measurement_count = 0;
                        fprintf('Moving to angle %d\n', current_angle);
                        fprintf(h, 'LD 1 DV');                                    % Select turntable
                        fprintf(h, ['LD ' num2str(current_angle) ' DG NP GO']);   % Move to next angle
                    else
                        fprintf('All angles completed for channel %d, BW %d MHz\n', ...
                            current_channel, current_bandwidth);

                        if fileID > 0
                            fclose(fileID);
                            fileID = -1;
                        end

                        mat_filepath = fullfile(data_folder_path, ...
                            sprintf('Measurements_Ch%d_BW%d.mat', current_channel, current_bandwidth));
                        save(mat_filepath, ...
                            'rssi1_mean', 'rssi2_mean', ...
                            'tx_bitrate_mean', 'tx_mcs_mean', ...
                            'rx_bitrate_mean', 'rx_mcs_mean', ...
                            'throughput_mean', 'angle_list');

                        fprintf('Data saved to: %s\n\n', data_folder_path);

                        % Return turntable to home position (0 deg)
                        fprintf(h, 'LD 1 DV');
                        fprintf(h, 'LD 0 DG NP GO');
                        fprintf('Turntable returned to home position (0 deg).\n\n');

                        current_angle = [];
                        angle_measurement_count = 0;
                        measurement_count = 0;
                        current_angle_index = 1;
                        current_bandwidth = [];
                        current_channel = [];
                    end
                end
            end
        end
    else
        pause(0.05);

        if has_received_any_data && toc(last_data_time) > NO_DATA_TIMEOUT
            fprintf('\n=== No data received for %d seconds. Stopping. ===\n', NO_DATA_TIMEOUT);

            if fileID > 0
                fclose(fileID);
                fileID = -1;
            end

            if ~isempty(configurations_processed)
                fprintf('Configurations completed: %d\n', size(configurations_processed, 1));
                for kk = 1:size(configurations_processed, 1)
                    fprintf('  Channel %d, BW %d MHz\n', ...
                        configurations_processed(kk, 1), configurations_processed(kk, 2));
                end
            end

            fprintf('Acquisition finished.\n');

            % Return turntable to home and close VISA
            try
                fprintf(h, 'LD 1 DV');
                fprintf(h, 'LD 0 DG NP GO');
                fclose(h); delete(h);
                fprintf('Turntable returned to home and VISA connection closed.\n');
            catch
            end

            break;
        end
    end
end


%% ========================================================================
%  LOCAL FUNCTIONS
%  ========================================================================

function local_cleanup(u)
    try flush(u); catch; end
    try clear u;  catch; end
    disp('UDP port closed (cleanup).');
end

function local_cleanup_turntable(h)
    try
        fprintf(h, 'LD 1 DV');
        fprintf(h, 'LD 0 DG NP GO');
        fclose(h);
        delete(h);
        disp('Turntable returned to home and VISA connection closed (cleanup).');
    catch
    end
end