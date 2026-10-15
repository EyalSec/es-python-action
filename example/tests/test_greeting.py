"""A deliberately vulnerable test, so the end-to-end workflow has something to report.

greet() receives a name over a network connection and builds a shell command
from it. A name such as "world; echo injected" runs a second command: command
injection. Under es-python with the socket source on, that flow is reported
as an event. The payload here only echoes text.
"""

import socket
import subprocess
import threading


def greet(sock):
    name = sock.recv(1024).decode().strip()
    # Vulnerable on purpose: untrusted text joined into a shell command.
    return subprocess.run("echo hello " + name, shell=True,
                          capture_output=True, text=True).stdout


def test_greet_runs_the_injected_command():
    server = socket.create_server(("127.0.0.1", 0))
    port = server.getsockname()[1]

    def send_name():
        conn, _ = server.accept()
        with conn:
            conn.sendall(b"world; echo injected\n")

    sender = threading.Thread(target=send_name)
    sender.start()
    with socket.create_connection(("127.0.0.1", port)) as client:
        out = greet(client)
    sender.join()
    server.close()
    assert out.splitlines() == ["hello world", "injected"]
