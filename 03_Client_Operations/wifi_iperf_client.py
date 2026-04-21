#!/usr/bin/env python3
"""
wifi_iperf_client.py
--------------------
Connects a Linux WiFi client to a designated access point (AP) and then
continuously runs an iperf3 client and a ping process toward the AP.
When the link drops, the script cleans up both processes, 
disconnects the interface, and automatically retries the full association cycle.

Requirements: nmcli, iw, ip, iperf3, ping

Usage
-----
    python3 wifi_iperf_client.py
"""

import os
import signal
import shutil
import subprocess
import sys
import threading
import time

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- WiFi credentials --------------------------------------------------------
SSID = "Radxa_5G"
PSK = "123456789"

# NetworkManager connection profile name (created/replaced on every run).
CON_NAME = "radxa_auto"

# --- Interface ---------------------------------------------------------------
# WiFi interface to use.  Leave empty for automatic detection via `iw dev`.
IFACE = ""

# --- Network / IP ------------------------------------------------------------
# IP address of the AP where iperf3 server is running.
AP_IP = "192.168.4.1"

# Set to True to assign a static IP to the client interface instead of DHCP.
USE_STATIC_IP = False

# Static IP (with prefix length) to assign when USE_STATIC_IP is True.
CLIENT_IP_CIDR = "192.168.4.4/24"

# --- iperf3 options ----------------------------------------------------------
# iperf3 server port (passed with -p).  Leave empty to use iperf3's default.
IPERF3_PORT = ""

# Extra iperf3 flags appended to every client invocation.
# Default: reverse mode (-R), 0.2 s intervals, unlimited duration, force-flush.
IPERF3_EXTRA_FLAGS = "-R -i 0.2 -t 0 --forceflush"

# --- Ping options ------------------------------------------------------------
PING_INTERVAL_OPTS = "-i 0.2"

# --- Logging -----------------------------------------------------------------
LOG_FILE = "/var/log/client_wifi_iperf.log"

# --- Binary paths (auto-detected from PATH) ----------------------------------
NMCLI_BIN = shutil.which("nmcli") or ""
IW_BIN = shutil.which("iw") or ""
IP_BIN = shutil.which("ip") or ""
IPERF3_BIN = shutil.which("iperf3") or ""
PING_BIN = shutil.which("ping") or ""

# --- Timing ------------------------------------------------------------------
SCAN_INTERVAL = 2        # seconds between SSID scan retries
ASSOC_TIMEOUT = 40       # max seconds to wait for association
RETRY_AFTER_DOWN = 3     # seconds to wait before reconnecting
IPERF_RESTART_GAP = 1    # seconds between iperf3 restarts

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

# Global state for background threads / processes.
_iperf_process: subprocess.Popen | None = None
_iperf_thread: threading.Thread | None = None
_stop_iperf: bool = False

_ping_process: subprocess.Popen | None = None
_ping_thread: threading.Thread | None = None
_stop_ping: bool = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(message: str) -> None:
    """Print a timestamped message and append it to LOG_FILE."""
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {message}"
    print(line)
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def run_cmd(command: list[str]) -> subprocess.CompletedProcess:
    """Run a command and return the CompletedProcess result."""
    return subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _kill_process(proc: subprocess.Popen | None) -> None:
    """Terminate a subprocess if it is still running."""
    if proc is not None and proc.poll() is None:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Privilege escalation
# ---------------------------------------------------------------------------

def _ensure_root() -> None:
    """Re-exec the script under sudo if not already running as root."""
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", sys.executable] + sys.argv)


# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

def _check_binaries() -> None:
    """Exit immediately if any required binary is missing."""
    binaries = {
        "nmcli": NMCLI_BIN,
        "iw": IW_BIN,
        "ip": IP_BIN,
        "iperf3": IPERF3_BIN,
        "ping": PING_BIN,
    }
    for name, path in binaries.items():
        if not path:
            print(
                f"ERROR: required binary '{name}' is missing. "
                "Install it or set the corresponding *_BIN variable.",
                file=sys.stderr,
            )
            sys.exit(1)


# ---------------------------------------------------------------------------
# Interface detection
# ---------------------------------------------------------------------------

def detect_iface() -> str:
    """Return the WiFi interface name, auto-detecting via `iw dev` if needed."""
    global IFACE
    if IFACE:
        log(f"Using WiFi interface: {IFACE}")
        return IFACE

    result = run_cmd([IW_BIN, "dev"])
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("Interface"):
            IFACE = line.split()[1]
            break

    if not IFACE:
        log("ERROR: no WiFi interface found via 'iw dev'.")
        sys.exit(1)

    log(f"Auto-detected WiFi interface: {IFACE}")
    return IFACE


# ---------------------------------------------------------------------------
# WiFi link management
# ---------------------------------------------------------------------------

def bring_iface_up() -> None:
    """Enable the WiFi radio and bring the interface up."""
    run_cmd([NMCLI_BIN, "radio", "wifi", "on"])
    run_cmd([NMCLI_BIN, "dev", "set", IFACE, "managed", "yes"])
    run_cmd([IP_BIN, "link", "set", IFACE, "up"])


def scan_for_ssid() -> bool:
    """Trigger a WiFi scan and return True if *SSID* is visible."""
    run_cmd([NMCLI_BIN, "device", "wifi", "rescan", "ifname", IFACE])
    result = run_cmd([NMCLI_BIN, "-t", "-f", "SSID", "device", "wifi", "list",
                      "ifname", IFACE])
    for line in result.stdout.splitlines():
        if line.strip() == SSID:
            return True
    return False


def link_is_up() -> bool:
    """Return True if the WiFi interface is connected."""
    result = run_cmd([NMCLI_BIN, "-t", "-f", "DEVICE,STATE", "dev"])
    for line in result.stdout.splitlines():
        if line.startswith(f"{IFACE}:connected"):
            return True

    result2 = run_cmd([IW_BIN, "dev", IFACE, "link"])
    if "Connected to" in result2.stdout:
        return True

    return False


def apply_ip_settings() -> None:
    """Apply static or DHCP IP settings to the NetworkManager profile."""
    if USE_STATIC_IP:
        log(f"Applying static IP {CLIENT_IP_CIDR} to profile {CON_NAME} (no default route)...")
        run_cmd([NMCLI_BIN, "con", "mod", CON_NAME,
                 "ipv4.method", "manual",
                 "ipv4.addresses", CLIENT_IP_CIDR,
                 "ipv4.never-default", "yes"])
    else:
        log(f"Using DHCP on {CON_NAME} (no default route)...")
        run_cmd([NMCLI_BIN, "con", "mod", CON_NAME,
                 "ipv4.method", "auto",
                 "ipv4.never-default", "yes"])

    run_cmd([NMCLI_BIN, "con", "up", CON_NAME, "ifname", IFACE])


def nmcli_connect() -> bool:
    """
    Create a fresh NetworkManager profile and connect to *SSID*.

    Returns True on successful association within ASSOC_TIMEOUT seconds.
    """
    # Remove any existing profile with the same name.
    result = run_cmd([NMCLI_BIN, "con", "show", CON_NAME])
    if result.returncode == 0:
        run_cmd([NMCLI_BIN, "con", "delete", CON_NAME])

    log(f"Connecting via nmcli: SSID='{SSID}', interface='{IFACE}'...")
    connect_result = run_cmd([
        NMCLI_BIN, "--wait", "20", "dev", "wifi", "connect", SSID,
        "password", PSK, "ifname", IFACE, "name", CON_NAME,
    ])

    if connect_result.returncode != 0:
        log("nmcli connect failed.")
        try:
            with open(LOG_FILE, "a") as fh:
                fh.write(connect_result.stdout + "\n")
                fh.write(connect_result.stderr + "\n")
        except OSError:
            pass
        return False

    elapsed = 0
    while elapsed < ASSOC_TIMEOUT:
        if link_is_up():
            log(f"Associated with '{SSID}'.")
            return True
        time.sleep(1)
        elapsed += 1

    log("Association timeout reached.")
    return False


# ---------------------------------------------------------------------------
# iperf3 client (background thread)
# ---------------------------------------------------------------------------

def _iperf_worker() -> None:
    """Continuously restart iperf3 client until *_stop_iperf* is set."""
    global _iperf_process

    cmd = [IPERF3_BIN, "-c", AP_IP]
    if IPERF3_PORT:
        cmd += ["-p", IPERF3_PORT]
    cmd += IPERF3_EXTRA_FLAGS.split()

    while not _stop_iperf:
        try:
            _iperf_process = subprocess.Popen(
                cmd,
                stdout=open(LOG_FILE, "a"),
                stderr=subprocess.STDOUT,
            )
            _iperf_process.wait()
        except Exception:
            pass
        finally:
            _iperf_process = None

        if _stop_iperf:
            break
        time.sleep(IPERF_RESTART_GAP)


def start_iperf_client() -> None:
    """Launch the iperf3 client loop in a background thread."""
    global _iperf_thread, _stop_iperf
    _stop_iperf = False
    _iperf_thread = threading.Thread(target=_iperf_worker, daemon=True)
    _iperf_thread.start()
    log(f"Starting iperf3 client -> {AP_IP} (auto-restart on failure)...")


def stop_iperf_client() -> None:
    """Stop the background iperf3 client."""
    global _iperf_thread, _stop_iperf
    _stop_iperf = True
    _kill_process(_iperf_process)
    if _iperf_thread is not None:
        _iperf_thread.join(timeout=5)
        _iperf_thread = None


# ---------------------------------------------------------------------------
# Continuous ping (background thread)
# ---------------------------------------------------------------------------

def _ping_worker() -> None:
    """Run a continuous ping until *_stop_ping* is set."""
    global _ping_process
    cmd = [PING_BIN] + PING_INTERVAL_OPTS.split() + ["-I", IFACE, AP_IP]
    try:
        _ping_process = subprocess.Popen(
            cmd,
            stdout=open(LOG_FILE, "a"),
            stderr=subprocess.STDOUT,
        )
        _ping_process.wait()
    except Exception:
        pass
    finally:
        _ping_process = None


def start_ping() -> None:
    """Launch the continuous ping in a background thread."""
    global _ping_thread, _stop_ping
    _stop_ping = False
    _ping_thread = threading.Thread(target=_ping_worker, daemon=True)
    _ping_thread.start()
    log(f"Starting continuous ping to {AP_IP} via {IFACE}...")


def stop_ping() -> None:
    """Stop the background ping."""
    global _ping_thread, _stop_ping
    _stop_ping = True
    _kill_process(_ping_process)
    if _ping_thread is not None:
        _ping_thread.join(timeout=5)
        _ping_thread = None


# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

def full_cleanup() -> None:
    """Stop iperf3 / ping and disconnect the WiFi interface."""
    log("Cleaning up processes and interface...")
    stop_iperf_client()
    stop_ping()

    run_cmd([NMCLI_BIN, "con", "down", CON_NAME])
    run_cmd([NMCLI_BIN, "dev", "disconnect", IFACE])
    run_cmd([IP_BIN, "addr", "flush", "dev", IFACE])


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

def _signal_handler(sig: int, frame) -> None:
    full_cleanup()
    sys.exit(0)


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main_loop() -> None:
    """Endlessly connect -> measure -> reconnect cycle."""
    detect_iface()

    while True:
        bring_iface_up()

        log(f"Scanning for SSID '{SSID}'...")
        while not scan_for_ssid():
            time.sleep(SCAN_INTERVAL)
        log(f"SSID '{SSID}' found. Starting connection...")

        if not nmcli_connect():
            log("Retrying connection...")
            full_cleanup()
            time.sleep(RETRY_AFTER_DOWN)
            continue

        apply_ip_settings()

        if not link_is_up():
            log("Link not confirmed after association. Retrying...")
            full_cleanup()
            time.sleep(RETRY_AFTER_DOWN)
            continue

        log("Connected. Launching iperf3 and ping...")
        start_iperf_client()
        start_ping()

        # Keep running while the link is alive.
        while link_is_up():
            time.sleep(1)

        log("Link lost. Stopping iperf3 and ping...")
        stop_iperf_client()
        stop_ping()

        log("Disconnecting and cleaning up before retry...")
        full_cleanup()
        time.sleep(RETRY_AFTER_DOWN)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    _ensure_root()
    _check_binaries()

    # Initialise log file.
    os.makedirs(os.path.dirname(os.path.abspath(LOG_FILE)), exist_ok=True)
    try:
        with open(LOG_FILE, "w"):
            pass
    except OSError:
        pass

    main_loop()

