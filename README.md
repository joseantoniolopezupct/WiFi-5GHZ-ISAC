# Wi-Fi Antenna Characterization and Localization Dataset

This repository contains the code and measurement data for a Wi-Fi-based antenna characterization and indoor direction-of-arrival (DoA) estimation system. The setup uses a **Radxa SBC** configured as a 5 GHz 802.11 access point (AP) to collect RF metrics — RSSI, bitrate, MCS index, and throughput — across multiple channels and antenna types, both in an anechoic chamber and in a real indoor environment.

**Authors:** Guillermo Inglés Muñoz, José Antonio López Pastor  
**Date:** April 2026  
**License:** [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/)

---

## Repository Structure

```
.
├── 01_Config_Files/            # hostapd and network interface configuration
│   ├── hostapd_daemon.conf     # System-level hostapd daemon config
│   ├── hostapd_files/          # Per-channel hostapd configs (ch36–ch161, 80 MHz)
│   ├── dnsmasq.conf            # DHCP server config for AP subnet
│   └── wlp1s0_interface.conf   # AP wireless interface config
│
├── 02_Data_Acquisition/        # Python scripts running on the AP (Radxa)
│   ├── channel_test.py         # Main measurement loop: cycles channels, streams RF metrics via UDP
│   └── get_throughput.py       # iperf3 server wrapper: writes live throughput to a text file
│
├── 03_Client_Operations/       # Python script running on the Wi-Fi client
│   └── wifi_iperf_client.py    # Connects to the AP, runs iperf3 + ping, auto-reconnects
│
├── 04_Anechoic_Chamber/        # MATLAB scripts for anechoic chamber tests
│   ├── Acquire_anechoic_digital.m    # Real-time UDP acquisition with turntable sweep
│   ├── Compute_steering_vectors.m    # Builds steering matrix from chamber data
│   ├── Compute_monopulse_function.m  # Computes monopulse ratio curves
│   ├── Plot_anechoic_information.m   # Plots antenna patterns and chamber results
│   └── Dirplot_modified.m            # Polar directivity plot utility
│
├── 05_Test_Environment/        # MATLAB scripts for indoor environment tests
│   ├── Acquire_indoor.m                      # Real-time UDP acquisition at fixed positions
│   ├── Process_indoor_antenna_comunications.m # Communication performance analysis
│   ├── Process_indoor_MUSIC_localization.m    # RSSI-based DoA via correlation pseudo-spectrum
│   ├── Process_indoor_monopulse_localization.m # DoA estimation using monopulse ratio
│   └── Process_indoor_comparison.m            # Cross-antenna and cross-method comparison
│
├── Anechoic_chamber_data/      # Measured data from anechoic chamber
│   └── LWA/<ch>/Measurements_Ch<ch>_BW80.{mat,txt}
│
└── Indoor_test_environment_data/  # Measured data from indoor environment
    ├── LWA/<angle_deg>/<ch>/Measurements_Ch<ch>_BW80.{mat,txt}
    ├── Monopole/<angle_deg>/<ch>/...
    ├── Panel/<angle_deg>/<ch>/...
    ├── indoor_comparison_data_LWA.mat
    ├── indoor_comparison_data_Monopole.mat
    └── indoor_comparison_data_Panel.mat
```

---

## System Overview

The measurement pipeline involves three components running in parallel:

**1. AP side (Radxa SBC) — Python**
- `channel_test.py` iterates over a set of `hostapd` configuration files, restarting the AP on each channel. It waits for a known client MAC to associate, then samples `iw station dump` to collect per-packet RSSI and link-rate metrics, and streams each record over UDP to a MATLAB listener.
- `get_throughput.py` runs an `iperf3` server in the background and writes the current throughput (Mbit/s) to a file that `channel_test.py` reads in real time.

**2. Client side — Python**
- `wifi_iperf_client.py` scans for the AP's SSID, connects via `nmcli`, applies a static or DHCP IP, and then continuously runs an `iperf3` client and a `ping` process. If the link drops it automatically reconnects and resumes traffic generation.

**3. PC side — MATLAB**
- Acquisition scripts (`Acquire_anechoic_digital.m`, `Acquire_indoor.m`) listen on a UDP port, parse incoming comma-separated records, average metrics per angle, and save `.mat` / `.txt` files.
- The anechoic chamber script also controls a GPIB-connected turntable to sweep the antenna under test through 191 angular positions (−95° to +95°).
- Processing scripts compute steering vectors, monopulse functions, and DoA estimates (correlation-based MUSIC and monopulse), then compare results across antennas and methods.

### UDP Record Format

Each datagram sent from the AP to MATLAB is one comma-separated line:

```
timestamp, rssi1, rssi2, tx_bitrate, tx_mcs, rx_bitrate, rx_mcs, throughput, channel, bandwidth
```

The MATLAB acquisition scripts append the current `angle` field before saving to disk.

---

## Hardware Requirements

| Component | Details |
|-----------|---------|
| Access Point | Radxa SBC with a 5 GHz 802.11ac/ax capable Wi-Fi card (interface `wlp1s0`) |
| Client device | Any Linux host with `nmcli`, `iw`, `iperf3`, `ping` |
| PC | MATLAB R2022b or later with Instrument Control Toolbox (for VISA/GPIB turntable control) |
| Turntable | GPIB-controlled positioner (Agilent/Keysight compatible) |
| Antennas | LWA (Leaky Wave Antenna), Panel array, Monopole |

---

## Software Requirements

**AP / Client (Python 3.10+)**
- `hostapd`, `hostapd_cli`, `iw`, `ip`
- `iperf3`
- `dnsmasq` (DHCP server)
- `nmcli` (NetworkManager, client side only)

**PC (MATLAB)**
- MATLAB R2022b+
- Instrument Control Toolbox (for VISA/GPIB turntable communication)

---

## Quick Start

### 1. Configure the AP

Copy the configuration files to the Radxa:

```bash
sudo cp 01_Config_Files/hostapd_files/*.conf /home/rock/channel_configs/
sudo cp 01_Config_Files/dnsmasq.conf /etc/dnsmasq.conf
sudo cp 01_Config_Files/hostapd_daemon.conf /etc/default/hostapd
```

### 2. Start the client

On the client device, edit the SSID/PSK constants at the top of `wifi_iperf_client.py`, then:

```bash
sudo python3 03_Client_Operations/wifi_iperf_client.py
```

### 3. Run the AP acquisition

On the Radxa, start the measurement sweep (replace MAC and IP with your client's values):

```bash
# Anechoic chamber (191 angles × 100 packets each)
python3 02_Data_Acquisition/channel_test.py \
    --mac a8:93:4a:d5:a3:3f \
    --client-ip 192.168.4.4 \
    --matlab-ip 192.168.1.2 --matlab-port 5005 \
    --angles 191 --packets 100

# Single indoor position (1 angle × 400 packets)
python3 02_Data_Acquisition/channel_test.py \
    --mac a8:93:4a:d5:a3:3f \
    --client-ip 192.168.4.4 \
    --matlab-ip 192.168.1.2 --matlab-port 5005 \
    --angles 1 --packets 400
```

### 4. Acquire on MATLAB

Open and run the appropriate acquisition script on the PC **before** starting the AP sweep:

- Anechoic chamber: `04_Anechoic_Chamber/Acquire_anechoic_digital.m`
- Indoor environment: `05_Test_Environment/Acquire_indoor.m`

Edit the `antenna`, `measurement_angle`, and path variables at the top of each script as needed.

### 5. Process the data

After acquisition, run the processing scripts in `05_Test_Environment/` to compute steering vectors, DoA estimates, and generate plots.

---

## Channels Tested

The repository includes configurations and measured data for the following 5 GHz channels at 80 MHz bandwidth:

| Band | Channels |
|------|----------|
| UNII-1 | 36, 40, 44, 48 |
| UNII-2A | 52, 56, 60, 64 |
| UNII-2C | 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144 |
| UNII-3 | 149, 153, 157, 161 |

---

## Data Format

### Raw measurements (`.txt`)

CSV files with one sample per row:

```
timestamp, rssi1, rssi2, tx_bitrate, tx_mcs, rx_bitrate, rx_mcs, throughput, channel, bandwidth, angle
```

### Averaged measurements (`.mat`)

MATLAB workspace files containing per-angle means:

```
rssi1_mean, rssi2_mean, tx_bitrate_mean, tx_mcs_mean,
rx_bitrate_mean, rx_mcs_mean, throughput_mean, angle_list
```

---

## License

This project is released under the **Creative Commons Attribution 4.0 International (CC-BY-4.0)** license. You are free to share and adapt the material for any purpose, provided appropriate credit is given.
