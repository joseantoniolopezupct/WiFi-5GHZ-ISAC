#!/usr/bin/env python3
"""
get_throughput.py
-----------------
Runs an iperf3 server and extracts the measured bitrate from its output, 
writing each value (in Mbit/s) to a plain-text file, one value per line.

The file is flushed after each write, so downstream readers always see the 
latest measurement without waiting for the process to finish.


Usage:
-----
    python3 get_throughput.py
"""

import os
import re
import signal
import subprocess
import sys

# =============================================================================
# CONFIGURATION
# =============================================================================

# Path of the output file that receives one bitrate value per line.
BITRATE_FILE = "/home/rock/Throughput.txt"

# Absolute path to the iperf3 binary.
IPERF3_PATH = "/usr/bin/iperf3"

# iperf3 server mode flag.  Change to "-c <host>" to run as a client instead.
IPERF3_MODE = "-s"

# Reporting interval in seconds (passed to iperf3 with -i).
IPERF3_INTERVAL = "0.1"

# Units to capture from iperf3 output.
# Supported: "Mbits/sec", "Kbits/sec", "Gbits/sec"
IPERF3_UNITS = "Mbits/sec"

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

# Global reference to the iperf3 subprocess so signal handlers can reach it.
_process: subprocess.Popen | None = None

# Pre-compile the regex that extracts the bitrate value from iperf3 output.
# Example matched line:
#   [  5]   0.00-0.10 sec  1.25 MBytes  105 Mbits/sec
_BITRATE_PATTERN = re.compile(
    r"\[\s*\d+\]\s+\d+\.\d+-\d+\.\d+\s+sec\s+\S+\s+\S+\s+"
    r"([\d.]+)\s+" + re.escape(IPERF3_UNITS)
)


def _signal_handler(sig: int, frame) -> None:
    """Gracefully terminate iperf3 on SIGINT / SIGTERM."""
    global _process
    if _process is not None and _process.poll() is None:
        _process.terminate()
        _process.wait()
    sys.exit(0)


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


def run_server() -> None:
    """Start the iperf3 process and stream its bitrate values to *BITRATE_FILE*."""
    global _process

    # Ensure the output directory exists.
    os.makedirs(os.path.dirname(os.path.abspath(BITRATE_FILE)), exist_ok=True)

    try:
        bw_file = open(BITRATE_FILE, "w")
    except OSError as exc:
        print(f"[ERROR] Cannot open output file '{BITRATE_FILE}': {exc}", file=sys.stderr)
        sys.exit(1)

    # Build the iperf3 command.
    # stdbuf -oL disables output buffering so lines arrive immediately.
    command = ["stdbuf", "-oL", IPERF3_PATH, IPERF3_MODE, "-i", IPERF3_INTERVAL]

    try:
        _process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
        )
    except FileNotFoundError:
        print(
            f"[ERROR] iperf3 binary not found at '{IPERF3_PATH}'. "
            "Install iperf3 or set IPERF3_PATH.",
            file=sys.stderr,
        )
        bw_file.close()
        sys.exit(1)
    except OSError as exc:
        print(f"[ERROR] Failed to start iperf3: {exc}", file=sys.stderr)
        bw_file.close()
        sys.exit(1)

    try:
        for raw_line in _process.stdout:
            line = raw_line.strip()
            match = _BITRATE_PATTERN.search(line)
            if match:
                bitrate = match.group(1)
                try:
                    bw_file.write(f"{bitrate}\n")
                    bw_file.flush()
                except OSError as exc:
                    print(f"[WARNING] Write error on '{BITRATE_FILE}': {exc}", file=sys.stderr)
    except OSError as exc:
        print(f"[WARNING] Error reading iperf3 output: {exc}", file=sys.stderr)
    finally:
        if _process is not None:
            _process.terminate()
            _process.wait()
        bw_file.close()


if __name__ == "__main__":
    run_server()
