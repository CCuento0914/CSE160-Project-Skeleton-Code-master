import socket
import threading
import sys

HOST = "1"   # wherever your TOSSIM TCP gateway is
PORT = 41          # change to match your setup

TERMINATOR = b"\r\n"


def recv_loop(sock: socket.socket):
    buffer = b""
    try:
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                print("\n[Disconnected from server]")
                break

            buffer += chunk
            # split on CRLF
            while TERMINATOR in buffer:
                line, buffer = buffer.split(TERMINATOR, 1)
                if line:
                    try:
                        print(f"\n[SERVER] {line.decode('utf-8', errors='replace')}")
                    except UnicodeDecodeError:
                        print(f"\n[SERVER] (binary) {line}")
                # re-show prompt
                print("> ", end="", flush=True)
    except OSError:
        pass


def send_line(sock: socket.socket, line: str):
    data = (line + "\r\n").encode("utf-8")
    sock.sendall(data)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} USERNAME")
        sys.exit(1)

    username = sys.argv[1]

    # 1. Create TCP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((HOST, PORT))
    print(f"Connected to chat server at {HOST}:{PORT}")

    # 2. Send hello command (client port is mostly for TinyOS; we can send a dummy)
    hello_cmd = f"hello {username} 3"
    send_line(sock, hello_cmd)
    print(f"Sent: {hello_cmd}")

    # 3. Start receiver thread
    t = threading.Thread(target=recv_loop, args=(sock,), daemon=True)
    t.start()

    # 4. Main loop: read user input and map to protocol commands
    print("Commands:")
    print("  /msg <text>             -> broadcast")
    print("  /w <user> <text>        -> whisper")
    print("  /list                   -> list users")
    print("  /quit                   -> exit")
    print("Anything else is sent as 'msg <text>'")
    print()

    try:
        while True:
            line = input("> ").strip()
            if not line:
                continue

            if line == "/quit":
                break
            elif line.startswith("/msg "):
                msg_text = line[len("/msg "):]
                cmd = f"msg {msg_text}"
            elif line.startswith("/w "):
                rest = line[len("/w "):].strip()
                parts = rest.split(" ", 1)
                if len(parts) < 2:
                    print("Usage: /w <user> <message>")
                    continue
                target, msg_text = parts
                cmd = f"whisper {target} {msg_text}"
            elif line == "/list":
                cmd = "listusr"
            else:
                # default: treat as broadcast message
                cmd = f"msg {line}"

            send_line(sock, cmd)
    except (EOFError, KeyboardInterrupt):
        pass
    finally:
        print("\nClosing connection...")
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


if __name__ == "__main__":
    main()
