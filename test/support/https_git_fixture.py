"""Disposable localhost HTTPS smart-Git fixture.

Never prints credentials, request headers, repository contents, or server logs.
The CA key and all credentials are ephemeral. No system trust is modified.
"""
import base64
import http.server
import json
import os
import secrets
import shutil
import ssl
import subprocess
import sys
import threading
import urllib.parse

config = json.loads(sys.stdin.readline())
root = os.path.abspath(config['root'])
openssl = config.get('openssl') or shutil.which('openssl')
if not openssl and sys.platform == 'win32':
    openssl = r'C:\Program Files\Git\usr\bin\openssl.exe'
for name in ['repo', 'bare', 'tls']:
    os.makedirs(os.path.join(root, name), exist_ok=True)
secret = secrets.token_urlsafe(24)
username = 'fixture-user'
expected = 'Basic ' + base64.b64encode((username + ':' + secret).encode()).decode()


def run(args, cwd=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Fixture setup failed while running ' + args[0])
    return result.stdout


tls = os.path.join(root, 'tls')
ca_key = os.path.join(tls, 'ca.key')
ca_pem = os.path.join(tls, 'ca.pem')
server_key = os.path.join(tls, 'server.key')
server_csr = os.path.join(tls, 'server.csr')
server_pem = os.path.join(tls, 'server.pem')
run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
     '-keyout', ca_key, '-out', ca_pem, '-subj', '/CN=Agent Resource disposable CA',
     '-addext', 'basicConstraints=critical,CA:TRUE'])
run([openssl, 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', server_key,
     '-out', server_csr, '-subj', '/CN=localhost'])
ext = os.path.join(tls, 'server.ext')
with open(ext, 'w', encoding='ascii') as stream:
    stream.write('subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
run([openssl, 'x509', '-req', '-in', server_csr, '-CA', ca_pem, '-CAkey', ca_key,
     '-CAcreateserial', '-days', '1', '-out', server_pem, '-extfile', ext])
repository = os.path.join(root, 'repo')
with open(os.path.join(repository, 'SKILL.md'), 'w', encoding='utf-8') as stream:
    stream.write('---\nname: tls-demo\ndescription: Inert TLS fixture.\n---\nNo executable content.\n')
run(['git', 'init', '--quiet', repository])
run(['git', '-C', repository, 'add', 'SKILL.md'])
run(['git', '-C', repository, '-c', 'user.name=Fixture',
     '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'])
run(['git', 'clone', '--quiet', '--bare', repository, os.path.join(root, 'bare', 'repo.git')])
events = []
servers = []


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def dispatch(self):
        parsed = urllib.parse.urlsplit(self.path)
        supplied = self.headers.get('Authorization')
        correct = supplied == expected
        events.append({'server': self.server.label,
                       'authorizationPresent': supplied is not None,
                       'authorizationCorrect': correct})
        if self.server.label == 'primary' and not correct:
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="disposable-fixture"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.server.label == 'primary' and parsed.path.startswith('/cross/'):
            self.redirect(other, parsed.path[6:], parsed.query)
            return
        if self.server.label == 'primary' and parsed.path.startswith('/down/'):
            self.redirect(plain, parsed.path[5:], parsed.query)
            return
        if self.server.label != 'primary':
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        size = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(size) if size else b''
        env = dict(os.environ)
        env.update({'GIT_PROJECT_ROOT': os.path.join(root, 'bare'),
                    'GIT_HTTP_EXPORT_ALL': '1', 'PATH_INFO': parsed.path,
                    'QUERY_STRING': parsed.query, 'REQUEST_METHOD': self.command,
                    'CONTENT_TYPE': self.headers.get('Content-Type', ''),
                    'CONTENT_LENGTH': str(size), 'REMOTE_USER': username,
                    'SERVER_PROTOCOL': self.request_version})
        result = subprocess.run(['git', 'http-backend'], input=body,
                                capture_output=True, env=env, timeout=20)
        if result.returncode:
            self.send_response(500)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        separator = b'\r\n\r\n' if b'\r\n\r\n' in result.stdout else b'\n\n'
        header_bytes, payload = result.stdout.split(separator, 1)
        pairs = [line.decode().split(':', 1) for line in header_bytes.splitlines()]
        status = next((int(value.strip().split()[0]) for key, value in pairs
                       if key.lower() == 'status'), 200)
        self.send_response(status)
        for key, value in pairs:
            if key.lower() not in ('status', 'content-length', 'transfer-encoding'):
                self.send_header(key, value.strip())
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def redirect(self, base, path, query):
        self.send_response(302)
        self.send_header('Location', base + path + (('?' + query) if query else ''))
        self.send_header('Content-Length', '0')
        self.end_headers()


class QuietServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, address):
        # Expected TLS reset from rejected certificate/auth probes.
        pass


def bind(label, secure):
    server = QuietServer(('127.0.0.1', 0), Handler)
    server.label = label
    if secure:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(server_pem, server_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    servers.append(server)
    return ('https' if secure else 'http') + '://localhost:' + str(server.server_port)


primary = bind('primary', True)
other = bind('other-origin', True)
plain = bind('plaintext', False)
print(json.dumps({'secret': secret, 'username': username, 'ca': ca_pem,
                  'primary': primary + '/repo.git', 'cross': primary.replace('/repo.git', '') + '/cross/repo.git',
                  'down': primary.replace('/repo.git', '') + '/down/repo.git'}), flush=True)
for line in sys.stdin:
    command = line.strip()
    if command == 'events':
        print(json.dumps({'events': events}), flush=True)
        events.clear()
    if command == 'stop':
        break
for server in servers:
    server.shutdown()
    server.server_close()
print(json.dumps({'events': events}), flush=True)
