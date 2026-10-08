"""Local SSH server for test/ssh_integration_test.dart.

Lets the real SSH adapter (lib/src/dartssh2_runner.dart) talk to an actual SSH
peer without touching a Pi: key exchange, host-key verification, password and
public-key auth, exec with stdin/stdout/stderr and exit status. Commands run in
a local bash, so the tests can use ordinary shell.

Needs Python 3 with asyncssh (pip install asyncssh). Not used by CI; the test
is skipped unless PITOOL_TEST_SSHD_PYTHON points at a Python that has it.

Usage: python tool/ssh_test_server.py <authorized_keys file>
Prints one line when ready: LISTENING <port> <SHA256 host-key fingerprint>

Three commands are answered by the server itself instead of bash, because they
need control over the wire:
  pitool-test split-utf8   sends "grün" with the two bytes of "ü" in separate
                           SSH packets
  pitool-test reset        sends one line, then resets the TCP connection (RST)
  pitool-test freeze <s>   answers nothing at all for <s> seconds (no channel
                           open, no exec reply), then prints "thawed"
"""

import asyncio
import os
import socket
import struct
import sys
import time

import asyncssh

USER = 'pi'
PASSWORD = os.environ.get('PITOOL_TEST_SSHD_PASSWORD', 'test-pw')
BASH = os.environ.get('PITOOL_TEST_BASH', 'bash')


class Server(asyncssh.SSHServer):
    def __init__(self, authorized):
        self._authorized = authorized

    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == USER and password == PASSWORD

    def public_key_auth_supported(self):
        return True

    def validate_public_key(self, username, key):
        return username == USER and key.export_public_key().split()[1] in self._authorized()


async def pump(reader, writer):
    while True:
        data = await reader.read(65536)
        if not data:
            break
        writer.write(data)
        await writer.drain()


async def handle(process):
    command = process.command or ''
    if command == 'pitool-test split-utf8':
        raw = 'grün\n'.encode('utf-8')
        cut = raw.index(b'\xc3') + 1  # between the two bytes of "ü"
        process.stdout.write(raw[:cut])
        await process.stdout.drain()
        await asyncio.sleep(0.3)
        process.stdout.write(raw[cut:])
        process.exit(0)
        return
    if command == 'pitool-test reset':
        process.stdout.write(b'before reset\n')
        await process.stdout.drain()
        await asyncio.sleep(0.3)
        conn = process.channel.get_connection()
        sock = conn.get_extra_info('socket')
        # Linger 0 turns the close into a TCP reset: the client sees a socket
        # ERROR (as on a dropped Wi-Fi link), not a clean end of stream.
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('HH', 1, 0))
        conn.abort()
        return
    if command.startswith('pitool-test freeze '):
        # Let the reply to this very exec request go out first.
        await asyncio.sleep(0.2)
        # Blocks the event loop on purpose: the server reads and answers
        # nothing meanwhile, on any connection — to the client that is a link
        # that died without a word.
        time.sleep(float(command.split()[2]))
        process.stdout.write(b'thawed\n')
        process.exit(0)
        return

    child = await asyncio.create_subprocess_exec(
        BASH, '-c', command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)

    async def feed():
        try:
            while True:
                data = await process.stdin.read(65536)
                if not data:
                    break
                child.stdin.write(data)
                await child.stdin.drain()
        except (asyncssh.BreakReceived, asyncssh.SignalReceived,
                asyncssh.TerminalSizeChanged, BrokenPipeError, ConnectionError):
            pass
        finally:
            try:
                child.stdin.close()
            except Exception:
                pass

    # Like sshd: the command ending ends the session, whether or not the client
    # ever closed stdin.
    feeder = asyncio.ensure_future(feed())
    await asyncio.gather(
        pump(child.stdout, process.stdout),
        pump(child.stderr, process.stderr))
    status = await child.wait()
    feeder.cancel()
    process.exit(status)


async def main():
    keys_file = sys.argv[1]

    def authorized():
        try:
            with open(keys_file, encoding='utf-8') as f:
                return {line.split()[1].encode() for line in f if len(line.split()) >= 2}
        except OSError:
            return set()

    host_key = asyncssh.generate_private_key('ssh-ed25519')
    server = await asyncssh.listen(
        '127.0.0.1', 0,
        server_factory=lambda: Server(authorized),
        server_host_keys=[host_key],
        process_factory=handle,
        encoding=None)
    port = server.sockets[0].getsockname()[1]
    print('LISTENING %d %s' % (port, host_key.get_fingerprint()), flush=True)
    await server.wait_closed()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
