#!/usr/bin/env python3
"""
channel_test.py
---------------
Iterates over a set of hostapd configuration files (one per channel/bandwidth pair), 
restarts the AP for each configuration, waits for a known client device to (re)associate, 
and then streams per-packet RF metrics to a UDP endpoint (e.g., MATLAB) while logging them locally.

Output record format (one line per sample, comma-separated):
    timestamp,rssi1,rssi2,tx_bitrate,tx_mcs,rx_bitrate,rx_mcs,throughput,channel,bandwidth

Usage:
-----
    python3 channel_test.py --mac a8:93:4a:d5:a3:3f --client-ip 192.168.4.4 
    python3 channel_test.py --mac a8:93:4a:d5:a3:3f --client-ip 192.168.4.4 \\
                            --matlab-ip 192.168.1.2 --matlab-port 5005      \\
                            --angles 191 --packets 100                      \\ For anechoic chamber
                            --angles 1   --packets 400                      \\ For single test point
"""

import argparse
import datetime
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time

# =============================================================================
# CONFIGURATION  (values that are NOT expected to change between runs)
# =============================================================================

# Directory that contains hostapd *.conf files named:
#   hostapd_ch<channel>_<bandwidth>mhz.conf
CONFIG_DIR = "/home/rock/channel_configs"

# Path to the log file (created/truncated at startup).
LOG_FILE = "/var/log/channel_test.log"

# Path to the get_throughput.py helper script.
GET_BITRATE_PATH = "/home/rock/get_throughput.py"

# WiFi interface used by the AP.
INTERFACE = "wlp1s0"

# Path to the Throughput.txt file written by get_throughput.py.
BITRATE_FILE = "/home/rock/Throughput.txt"

# Seconds to wait between consecutive cycles within the same channel.
INTER_CYCLE_WAIT = 1.0

# Seconds to wait after the client associates before starting measurements.
PRE_MEASUREMENT_WAIT = 10.0

# Maximum seconds to wait for hostapd to reach state=ENABLED.
HOSTAPD_MAX_WAIT = 800

# Seconds between hostapd readiness polls.
HOSTAPD_POLL_INTERVAL = 5.0

# Seconds between device association polls.
ASSOC_POLL_INTERVAL = 2.0

# Target TX power (dBm) per channel.  Channels not listed use DEFAULT_TX_DBM.
POWER_DBM_BY_CHANNEL: dict[int, int] = {
    44:  10,
    64:  10,
    108: 10,
    124: 10,
    140: 10,
    161: 10,
}
DEFAULT_TX_DBM: int = 10

# Controls the order in which bandwidth classes are tested.
BANDWIDTH_ORDER: dict[int, int] = {20: 1, 40: 2, 80: 3, 160: 4}

# =============================================================================
# PARAMETERS RECEIVED FROM COMMAND LINE  (set in main() via argparse)
# =============================================================================

DEVICE_MAC: str = ""
CLIENT_IP: str = ""
MATLAB_HOST: str = ""
MATLAB_PORT: int = 0
ANGLES_PER_CHANNEL: int = 0
PACKETS_PER_ANGLE: int = 0

# =============================================================================
# END OF CONFIGURATION
# =============================================================================


# ---------------------------------------------------------------------------
# UDP socket
# ---------------------------------------------------------------------------
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# ---------------------------------------------------------------------------
# Global state for background threads / processes
# ---------------------------------------------------------------------------
_stop_ping_thread: bool = False
_ping_thread: threading.Thread | None = None
_bitrate_process: subprocess.Popen | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run_command(command: list[str], use_sudo: bool = False) -> str:
    """Run a shell command and return its stdout as a stripped string."""
    if use_sudo:
        command = ["sudo"] + command
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def log(message: str) -> None:
    """Append *message* to LOG_FILE and print it to stdout."""
    print(message)
    with open(LOG_FILE, "a") as fh:
        fh.write(message + "\n")


def get_last_bitrate() -> str:
    """Return the last non-empty line of BITRATE_FILE, or '0' on any error."""
    try:
        with open(BITRATE_FILE, "r") as fh:
            lines = fh.readlines()
        for line in reversed(lines):
            stripped = line.strip()
            if stripped:
                return stripped
    except Exception:
        pass
    return "0"


# ---------------------------------------------------------------------------
# TX power management
# ---------------------------------------------------------------------------

def _dbm_to_mbm(dbm: float) -> int:
    return int(round(dbm * 100))


def set_tx_power_dbm(dbm: float) -> None:
    mbm = _dbm_to_mbm(dbm)
    run_command(["iw", "dev", INTERFACE, "set", "txpower", "fixed", str(mbm)], use_sudo=True)


def get_current_tx_dbm() -> float | None:
    info = run_command(["iw", "dev", INTERFACE, "info"], use_sudo=True)
    match = re.search(r"txpower\s+([0-9]+\.[0-9]+)\s*dBm", info)
    return float(match.group(1)) if match else None


def apply_tx_power_for_channel(channel: int) -> None:
    target_dbm = POWER_DBM_BY_CHANNEL.get(channel, DEFAULT_TX_DBM)
    set_tx_power_dbm(target_dbm)
    time.sleep(0.2)
    current = get_current_tx_dbm()
    if current is None:
        msg = f"[TX] Target {target_dbm} dBm applied (could not read current value)."
    else:
        msg = f"[TX] Target {target_dbm} dBm; driver reports {current:.2f} dBm"
        if abs(current - target_dbm) > 0.6:
            msg += " (WARNING: possible regulatory / hardware / DFS limit)"
    log(msg)


# ---------------------------------------------------------------------------
# Continuous ping (background thread)
# ---------------------------------------------------------------------------

def _ping_worker() -> None:
    global _stop_ping_thread
    while not _stop_ping_thread:
        subprocess.run(
            ["ping", "-c", "1", CLIENT_IP],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(1)


def start_ping() -> None:
    global _ping_thread, _stop_ping_thread
    _stop_ping_thread = False
    _ping_thread = threading.Thread(target=_ping_worker, daemon=True)
    _ping_thread.start()
    log("Continuous ping to client started.")


def stop_ping() -> None:
    global _ping_thread, _stop_ping_thread
    if _ping_thread is not None:
        _stop_ping_thread = True
        _ping_thread.join()
        _ping_thread = None
        log("Continuous ping to client stopped.")


# ---------------------------------------------------------------------------
# Bitrate helper process (get_throughput.py)
# ---------------------------------------------------------------------------

def start_bitrate_process() -> None:
    global _bitrate_process
    try:
        _bitrate_process = subprocess.Popen(
            ["python3", GET_BITRATE_PATH],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log("get_throughput.py started in background.")
    except Exception as exc:
        log(f"Error starting get_throughput.py: {exc}")


def stop_bitrate_process() -> None:
    global _bitrate_process
    if _bitrate_process is not None and _bitrate_process.poll() is None:
        _bitrate_process.terminate()
        _bitrate_process.wait()
        log("get_throughput.py stopped.")
        _bitrate_process = None


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

def _signal_handler(sig: int, frame) -> None:
    stop_ping()
    stop_bitrate_process()
    sys.exit(0)


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# ---------------------------------------------------------------------------
# Configuration file discovery and sorting
# ---------------------------------------------------------------------------

def _extract_channel_bw(filename: str) -> tuple[int | None, int | None]:
    """Parse channel and bandwidth from a filename like hostapd_ch44_80mhz.conf."""
    match = re.match(r"hostapd_ch(\d+)_(\d+)mhz\.conf", filename, re.IGNORECASE)
    if match:
        return int(match.group(1)), int(match.group(2))
    return None, None


def _load_config_list() -> list[tuple[int, int, str]]:
    """Return a sorted list of (channel, bandwidth, filename) tuples."""
    entries = []
    for name in os.listdir(CONFIG_DIR):
        if name.endswith(".conf"):
            ch, bw = _extract_channel_bw(name)
            if ch is not None and bw is not None:
                entries.append((ch, bw, name))
    entries.sort(key=lambda x: (BANDWIDTH_ORDER.get(x[1], 5), x[0]))
    return entries


# ---------------------------------------------------------------------------
# Per-station signal parsing
# ---------------------------------------------------------------------------

def _parse_station_metrics(
    station_dump: str,
    device_mac: str,
) -> tuple[str, str, str, str, str, str] | None:
    """
    Parse one station's metrics from the output of `iw dev <iface> station dump`.

    Returns (rssi1, rssi2, tx_bitrate, tx_mcs, rx_bitrate, rx_mcs)
    or None if the device is not found / data is incomplete.
    """
    lines = station_dump.split("\n")
    found = False

    for i, line in enumerate(lines):
        if device_mac.lower() in line.lower():
            found = True

        if not found:
            continue

        line_s = line.strip()
        if not line_s.startswith("signal:"):
            continue

        # Parse RSSI values from e.g. "signal: -55 [-60, -58]"
        m_sig = re.search(r"signal:\s*-\d+\s*\[(-\d+),\s*(-\d+)\]", line_s)
        if not m_sig:
            return None

        rssi1, rssi2 = m_sig.group(1), m_sig.group(2)
        tx_bitrate = tx_mcs = rx_bitrate = rx_mcs = "0"

        for k in range(i + 1, len(lines)):
            kline = lines[k].strip()

            if kline.startswith("tx bitrate:"):
                m = re.search(r"tx bitrate:\s*([\d.]+)\s*MBit/s.*MCS\s*(\d+)", kline)
                if m:
                    tx_bitrate, tx_mcs = m.group(1), m.group(2)
                else:
                    m2 = re.search(r"tx bitrate:\s*([\d.]+)\s*MBit/s", kline)
                    if m2:
                        tx_bitrate = m2.group(1)

            if kline.startswith("rx bitrate:"):
                m = re.search(r"rx bitrate:\s*([\d.]+)\s*MBit/s.*MCS\s*(\d+)", kline)
                if m:
                    rx_bitrate, rx_mcs = m.group(1), m.group(2)
                else:
                    m2 = re.search(r"rx bitrate:\s*([\d.]+)\s*MBit/s", kline)
                    if m2:
                        rx_bitrate = m2.group(1)
                break  # rx bitrate is the last field we need

        return rssi1, rssi2, tx_bitrate, tx_mcs, rx_bitrate, rx_mcs

    return None


# ---------------------------------------------------------------------------
# Main measurement loop
# ---------------------------------------------------------------------------

def measure_channel(channel: int, bandwidth: int, filename: str) -> None:
    """Run the full measurement sequence for one channel / bandwidth config."""

    # Stop any leftover bitrate process before reconfiguring the AP.
    stop_bitrate_process()

    log(f"Testing channel {channel} with bandwidth {bandwidth} MHz...")

    # Deploy the new hostapd configuration.
    config_path = os.path.join(CONFIG_DIR, filename)
    run_command(["cp", config_path, "/etc/hostapd/hostapd.conf"], use_sudo=True)
    run_command(["systemctl", "restart", "hostapd"], use_sudo=True)

    # --- Wait for hostapd to reach ENABLED state ---
    log(f"Waiting for hostapd to become operational on channel {channel}...")
    start_time_channel = datetime.datetime.now()
    elapsed_wait = 0

    while True:
        status = run_command(["hostapd_cli", "-i", INTERFACE, "status"], use_sudo=True)
        if "state=ENABLED" in status:
            log("hostapd is operational.")
            apply_tx_power_for_channel(channel)
            break
        time.sleep(HOSTAPD_POLL_INTERVAL)
        elapsed_wait += HOSTAPD_POLL_INTERVAL
        if elapsed_wait >= HOSTAPD_MAX_WAIT:
            log(f"Timeout waiting for hostapd on channel {channel}. Skipping.")
            return

    # --- Wait for the target device to associate ---
    log("Waiting for device to connect...")
    while True:
        station_dump = run_command(
            ["iw", "dev", INTERFACE, "station", "dump"], use_sudo=True
        )
        if DEVICE_MAC.lower() in station_dump.lower():
            log("Device connected.")
            start_ping()
            break
        time.sleep(ASSOC_POLL_INTERVAL)

    # --- Warm-up period ---
    start_bitrate_process()
    time.sleep(5)
    log(f"Device connected. Starting measurement in {PRE_MEASUREMENT_WAIT:.0f} seconds...")
    time.sleep(PRE_MEASUREMENT_WAIT)

    # Reaffirm TX power (driver may have changed it during association).
    apply_tx_power_for_channel(channel)

    log(f"Starting measurement on channel {channel} / {bandwidth} MHz...")
    log(
        f"Collecting {PACKETS_PER_ANGLE} samples x {ANGLES_PER_CHANNEL} cycle(s) "
        f"per channel..."
    )

    packet_count = 0
    cycle_count = 0

    try:
        while True:
            station_dump = run_command(
                ["iw", "dev", INTERFACE, "station", "dump"], use_sudo=True
            )
            metrics = _parse_station_metrics(station_dump, DEVICE_MAC)
            if metrics is None:
                continue  # device temporarily invisible - keep trying

            rssi1, rssi2, tx_bitrate, tx_mcs, rx_bitrate, rx_mcs = metrics
            timestamp = datetime.datetime.now().timestamp()
            throughput = get_last_bitrate()

            # Output record
            record = (
                f"{timestamp},{rssi1},{rssi2},"
                f"{tx_bitrate},{tx_mcs},"
                f"{rx_bitrate},{rx_mcs},"
                f"{throughput},{channel},{bandwidth}"
            )
            log(record)
            sock.sendto(
                (record + "\n").encode("utf-8"),
                (MATLAB_HOST, MATLAB_PORT),
            )

            packet_count += 1

            if packet_count >= PACKETS_PER_ANGLE:
                packet_count = 0
                cycle_count += 1
                log(f"Cycle {cycle_count}/{ANGLES_PER_CHANNEL} complete. Waiting {INTER_CYCLE_WAIT} s...")
                time.sleep(INTER_CYCLE_WAIT)

                if cycle_count >= ANGLES_PER_CHANNEL:
                    cycle_count = 0
                    elapsed = datetime.datetime.now() - start_time_channel
                    log(
                        f"Measurement time for channel {channel} / {bandwidth} MHz: "
                        f"{elapsed}"
                    )
                    log("Moving to next channel.")
                    raise StopIteration

    except StopIteration:
        pass
    finally:
        stop_ping()


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="WiFi channel measurement tool for AP side.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python3 channel_test.py --mac a8:93:4a:d5:a3:3f --client-ip 192.168.4.4\n"
            "  python3 channel_test.py --mac a8:93:4a:d5:a3:3f --client-ip 192.168.4.4 \\\n"
            "                          --matlab-ip 192.168.1.2 --matlab-port 5005 \\\n"
            "                          --angles 191 --packets 100\n"
        ),
    )

    parser.add_argument(
        "--mac", "-m",
        required=True,
        help="MAC address of the client device to wait for (e.g. a8:93:4a:d5:a3:3f).",
    )
    parser.add_argument(
        "--client-ip", "-c",
        required=True,
        help="IP address of the client device (for ping).",
    )
    parser.add_argument(
        "--matlab-ip",
        default="192.168.1.2",
        help="IP of the MATLAB/UDP listener (default: 192.168.1.2).",
    )
    parser.add_argument(
        "--matlab-port",
        type=int,
        default=5005,
        help="UDP port of the MATLAB/UDP listener (default: 5005).",
    )
    parser.add_argument(
        "--angles", "-a",
        type=int,
        default=191,
        help="Number of measurement cycles (angles) per channel (default: 191).",
    )
    parser.add_argument(
        "--packets", "-p",
        type=int,
        default=100,
        help="Number of samples per cycle/angle (default: 100).",
    )

    return parser.parse_args()

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    global DEVICE_MAC, CLIENT_IP, MATLAB_HOST, MATLAB_PORT
    global ANGLES_PER_CHANNEL, PACKETS_PER_ANGLE

    args = parse_args()

    # Assign command-line values to module-level variables.
    DEVICE_MAC = args.mac
    CLIENT_IP = args.client_ip
    MATLAB_HOST = args.matlab_ip
    MATLAB_PORT = args.matlab_port
    ANGLES_PER_CHANNEL = args.angles
    PACKETS_PER_ANGLE = args.packets

    # Initialise log file.
    try:
        os.remove(LOG_FILE)
    except FileNotFoundError:
        pass
    with open(LOG_FILE, "w"):
        pass
    run_command(["chmod", "666", LOG_FILE], use_sudo=True)

    config_list = _load_config_list()
    if not config_list:
        log(f"No hostapd *.conf files found in '{CONFIG_DIR}'. Exiting.")
        sys.exit(1)

    log(
        f"Found {len(config_list)} configuration(s). "
        f"Cycles per channel: {ANGLES_PER_CHANNEL}, "
        f"packets per cycle: {PACKETS_PER_ANGLE}."
    )
    log(f"Device MAC: {DEVICE_MAC}  |  Client IP: {CLIENT_IP}")
    log(f"MATLAB endpoint: {MATLAB_HOST}:{MATLAB_PORT}")

    for channel, bandwidth, filename in config_list:
        measure_channel(channel, bandwidth, filename)
        log("-----------------------------")

    log("Test complete.")
    stop_ping()
    stop_bitrate_process()


if __name__ == "__main__":
    main()