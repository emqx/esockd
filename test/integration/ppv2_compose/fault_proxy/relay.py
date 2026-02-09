import os
import socket
import threading
import time

MODE = os.getenv("MODE", "timeout").strip()
HOLD_MS = int(os.getenv("HOLD_MS", "800"))
LISTEN_PORT = int(os.getenv("LISTEN_PORT", "19091"))
UPSTREAM_HOST = os.getenv("UPSTREAM_HOST", "host.docker.internal")
UPSTREAM_PORT = int(os.getenv("UPSTREAM_PORT", "7007"))


def pipe(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def handle_conn(client_sock):
    upstream = None
    try:
        upstream = socket.create_connection((UPSTREAM_HOST, UPSTREAM_PORT), timeout=3)
        client_sock.settimeout(3)
        first = client_sock.recv(64)
        if not first:
            return
        if MODE == "pass":
            upstream.sendall(first)
            t1 = threading.Thread(target=pipe, args=(client_sock, upstream), daemon=True)
            t2 = threading.Thread(target=pipe, args=(upstream, client_sock), daemon=True)
            t1.start()
            t2.start()
            t1.join()
            t2.join()
        else:
            chunk = first[:2]
            if chunk:
                upstream.sendall(chunk)

            if MODE == "close":
                return

            # Keep socket open long enough so server side hits proxy_protocol_timeout.
            time.sleep(HOLD_MS / 1000.0)
    except Exception:
        # Intentionally ignore to keep behavior deterministic for test harness.
        pass
    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        if upstream is not None:
            try:
                upstream.close()
            except Exception:
                pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(128)

    while True:
        sock, _addr = srv.accept()
        t = threading.Thread(target=handle_conn, args=(sock,), daemon=True)
        t.start()


if __name__ == "__main__":
    main()
