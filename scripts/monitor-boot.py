#!/usr/bin/env python3
import socket
import sys
import time

sock_path = sys.argv[1] if len(sys.argv) > 1 else "/workspace/build/qemu-monitor.sock"
print(f"[monitor-boot] Waiting for monitor socket: {sock_path}")

sock = None
for _ in range(40):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        sock = s
        print("[monitor-boot] Connected to QEMU monitor socket.")
        break
    except Exception:
        time.sleep(0.5)

if not sock:
    print("[monitor-boot] Timeout connecting to monitor socket.")
    sys.exit(0)

try:
    sock.settimeout(1.0)
    sock.recv(1024)
except Exception:
    pass

for i in range(15):
    try:
        sock.sendall(b"sendkey ret\n")
        print(f"[monitor-boot] Sent 'sendkey ret' ({i+1}/15)")
    except Exception as e:
        print(f"[monitor-boot] Communication ended: {e}")
        break
    time.sleep(1)

try:
    sock.close()
except Exception:
    pass

print("[monitor-boot] Boot monitor task completed.")
