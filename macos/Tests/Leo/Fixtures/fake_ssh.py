#!/usr/bin/env python3
"""A tiny `ssh -L` stand-in used by Leo tunnel tests."""

import os
import signal
import socket
import sys


def socket_path(arguments):
    for index, argument in enumerate(arguments):
        if argument == "-L" and index + 1 < len(arguments):
            return arguments[index + 1].split(":", 1)[0]
    raise ValueError("missing -L local:remote")


def serve(path):
    unhealthy = os.environ.get("FAKE_SSH_UNHEALTHY") is not None
    version = os.environ.get("FAKE_SSH_VERSION")

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen()
    while True:
        client, _ = server.accept()
        with client:
            client.recv(65536)
            if unhealthy:
                status, body = b"500 Internal Server Error", b'{"ok":false}'
            elif version:
                status = b"200 OK"
                body = ('{"ok":true,"data":{"version":"%s"}}' % version).encode()
            else:
                status, body = b"200 OK", b'{"ok":true}'
            response = b"HTTP/1.1 " + status + b"\r\nContent-Length: " + str(len(body)).encode()
            client.sendall(response + b"\r\nConnection: close\r\n\r\n" + body)


def publish(path, text):
    """Write `text` so `path` never exists with partial contents: tests poll
    for the file's existence and then read it, so a plain `open(path, "w")`
    exposes an empty file between create and write."""
    staging = "%s.%d.tmp" % (path, os.getpid())
    with open(staging, "w") as handle:
        handle.write(text)
    os.replace(staging, path)


def main():
    # Installed before anything below can block, per the contract every fixture
    # variant is expected to satisfy.
    if os.environ.get("FAKE_SSH_IGNORE_TERM"):
        signal.signal(signal.SIGTERM, lambda _signal, _frame: None)

    argv_file = os.environ.get("FAKE_SSH_ARGV_FILE")
    if argv_file:
        publish(argv_file, "\n".join(sys.argv[1:]))

    pid_file = os.environ.get("FAKE_SSH_PID_FILE")
    if pid_file:
        publish(pid_file, str(os.getpid()))

    immediate = os.environ.get("FAKE_SSH_EXIT_IMMEDIATELY")
    if immediate is not None:
        message = os.environ.get("FAKE_SSH_STDERR_MESSAGE", "auth failed\n")
        sys.stderr.write(message)
        sys.stderr.flush()
        return int(immediate)

    count = int(os.environ.get("FAKE_SSH_STDERR_BYTES", "0"))
    if count:
        sys.stderr.write("x" * count)
        sys.stderr.flush()

    if os.environ.get("FAKE_SSH_NEVER_BIND"):
        signal.pause()
        return 0

    serve(socket_path(sys.argv[1:]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
