#!/usr/bin/env python3
"""A local TCP listener standing in for "the network": logs every connection
and its first request line, so a test can tell whether an extractor fetched
a remote resource. usage: listen.py PORT LOGFILE"""
import socket
import sys
import threading
import time

port, log = int(sys.argv[1]), sys.argv[2]
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(64)


def handle(c):
    c.settimeout(2)
    try:
        first = c.recv(4096).split(b"\r\n", 1)[0].decode(errors="replace")
    except Exception:  # noqa: BLE001
        first = "(no data)"
    with open(log, "a") as f:
        f.write(f"{time.strftime('%H:%M:%S')} {first}\n")
    try:
        c.sendall(b"HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    except Exception:  # noqa: BLE001
        pass
    c.close()


while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
