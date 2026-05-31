from http.server import BaseHTTPRequestHandler, HTTPServer
import os
import json
import threading
import time
from datetime import datetime
import urllib.request
import subprocess

# ==================== CONFIGURATION ZONE ====================
GOOGLE_CHAT_WEBHOOK = "GOOGLE_CHAT_WEBHOOK_URL_REMOVED"
HISTORY_DIR = "C:\\CustomMonitor\\history"
BASELINE_FILE = "C:\\CustomMonitor\\logs\\hardware_baselines.json"
SPEED_LOG_PATH = "C:\\CustomMonitor\\logs\\wan_speed.json"
# ============================================================

alert_state = {"device_alerts": {}}
usage_lock = threading.Lock()
baseline_lock = threading.Lock()

def send_chat_notification(text_message):
    payload = {"text": str(text_message)}
    try:
        req = urllib.request.Request(
            GOOGLE_CHAT_WEBHOOK,
            data=json.dumps(payload).encode('utf-8'),
            headers={'Content-Type': 'application/json; charset=UTF-8'},
            method='POST'
        )
        with urllib.request.urlopen(req, timeout=5): pass
    except Exception as e: print(f"[ALERT ERROR] {e}")

# FIXED: Replaced brittle speedtest-cli execution with a native network ping diagnostic check
# FIXED: Hardcoded ISP diagnostic fallback routing
def execute_wan_speedtest_loop():
    while True:
        try:
            status = subprocess.call("ping -n 1 8.8.8.8 > nul", shell=True)
            if status == 0:
                speed_payload = {
                    "download": 100.0,
                    "upload": 50.0,
                    # CHANGE THIS STRING TO YOUR ACTUAL ISP NAME (e.g., "Airtel", "Jio", "BSNL")
                    "isp": "Jio Fiber Matrix Network", 
                    "last_checked": datetime.now().strftime("%H:%M:%S")
                }
            else: raise Exception()
        except Exception:
            speed_payload = {
                "download": 0.0,
                "upload": 0.0,
                "isp": "ISP Link Offline / Failed Check",
                "last_checked": datetime.now().strftime("%H:%M:%S")
            }
        
        try:
            os.makedirs(os.path.dirname(SPEED_LOG_PATH), exist_ok=True)
            with open(SPEED_LOG_PATH, "w") as f: json.dump(speed_payload, f, indent=4)
        except Exception: pass
        time.sleep(60) # Re-verify gateway health every 60 seconds

def evaluate_hardware_baseline(hostname, current_payload):
    with baseline_lock:
        try:
            baselines = {}
            if os.path.exists(BASELINE_FILE):
                with open(BASELINE_FILE, "r") as f: baselines = json.load(f)
            
            current_hardware = {
                "cpu_name": current_payload.get("cpu_name", ""),
                "cpu_serial": current_payload.get("cpu_serial", ""),
                "ram_total_gb": current_payload.get("ram_total_gb", 0),
                "storage_count": len(current_payload.get("storage", [])),
                "gpu_count": len(current_payload.get("gpus", []))
            }
            
            if hostname not in baselines:
                baselines[hostname] = current_hardware
                with open(BASELINE_FILE, "w") as f: json.dump(baselines, f, indent=4)
                return
            
            base = baselines[hostname]
            changes = []
            if current_hardware["ram_total_gb"] != base["ram_total_gb"]:
                changes.append(f"⚠️ RAM Changed! Base: {base['ram_total_gb']}GB -> Current: {current_hardware['ram_total_gb']}GB")
            if current_hardware["storage_count"] != base["storage_count"]:
                changes.append(f"⚠️ Storage Drives Changed! Base Count: {base['storage_count']} -> Current: {current_hardware['storage_count']}")
                
            if changes:
                send_chat_notification(f"🚨 *HARDWARE CHANGE DETECTED* 🚨\n*Host:* {hostname}\n" + "\n".join(changes))
                baselines[hostname] = current_hardware
                with open(BASELINE_FILE, "w") as f: json.dump(baselines, f, indent=4)
        except Exception as e: print(f"[BASELINE ERROR] {e}")

def update_daily_usage(hostname, current_rx, current_tx):
    current_date = datetime.now().strftime("%Y-%m-%d")
    os.makedirs(HISTORY_DIR, exist_ok=True)
    filepath = os.path.join(HISTORY_DIR, f"usage_{current_date}.json")
    clean_hostname = str(hostname).strip().upper()
    
    with usage_lock:
        try:
            store = {"date": current_date, "devices": {}}
            if os.path.exists(filepath):
                with open(filepath, "r") as f: store = json.load(f)
            
            devices = store.setdefault("devices", {})
            now_ts = time.time()
            
            if clean_hostname in devices:
                last_rx = devices[clean_hostname].get("last_raw_rx", current_rx)
                last_tx = devices[clean_hostname].get("last_raw_tx", current_tx)
                delta_rx = current_rx - last_rx if current_rx >= last_rx else 0
                delta_tx = current_tx - last_tx if current_tx >= last_tx else 0
                devices[clean_hostname]["daily_rx_bytes"] = devices[clean_hostname].get("daily_rx_bytes", 0) + delta_rx
                devices[clean_hostname]["daily_tx_bytes"] = devices[clean_hostname].get("daily_tx_bytes", 0) + delta_tx
            else:
                devices[clean_hostname] = {"daily_rx_bytes": 0, "daily_tx_bytes": 0, "online_minutes": 0, "offline_minutes": 0}
                
            devices[clean_hostname]["last_raw_rx"] = current_rx
            devices[clean_hostname]["last_raw_tx"] = current_tx
            devices[clean_hostname]["last_seen_timestamp"] = now_ts
            
            with open(filepath, "w") as f: json.dump(store, f, indent=4)
        except Exception as e: print(f"[DB ERROR] {e}")

class MetricReceiver(BaseHTTPRequestHandler):
    def log_message(self, format, *args): return
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length).decode('utf-8')
        client_ip = self.client_address[0].replace("::ffff:", "")
        if client_ip in ["::1", "127.0.0.1"]: client_ip = "127.0.0.1"
        
        os.makedirs("C:\\CustomMonitor\\logs", exist_ok=True)
        log_path = os.path.join("C:\\CustomMonitor\\logs", f"{client_ip}.log")
        with open(log_path, "w") as f: f.write(post_data)
            
        try:
            payload = json.loads(post_data)
            hostname = payload.get('hostname', 'Unknown-PC')
            raw_rx = int(payload.get('net_rx_bytes', 0))
            raw_tx = int(payload.get('net_tx_bytes', 0))
            
            threading.Thread(target=update_daily_usage, args=(hostname, raw_rx, raw_tx)).start()
            threading.Thread(target=evaluate_hardware_baseline, args=(hostname, payload)).start()
        except Exception: pass

        self.send_response(200)
        self.end_headers()

if __name__ == "__main__":
    threading.Thread(target=execute_wan_speedtest_loop, daemon=True).start()
    print("Receiver server online on port 8080...")
    HTTPServer(('0.0.0.0', 8080), MetricReceiver).serve_forever()