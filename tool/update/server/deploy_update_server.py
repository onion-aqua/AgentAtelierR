#!/usr/bin/env python3
"""Install an isolated static origin; reload only the existing TLS edge.

Run with root over a verified SSH connection. No credentials are accepted or
stored. The matching server directory must accompany this script. No release
manifest is invented and no relay data/environment/secret is read.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path('/opt/agentatelier-updates')
PUBLIC = Path('/srv/agentatelier-updates/public')
EDGE = Path('/opt/agent-relay/config/nginx.conf')
EDGE_CONTAINER = 'agent-relay-edge-1'
HERE = Path(__file__).resolve().parent
MARKER = '# BEGIN agentatelier-updates'
PROBE = (b'AgentAtelierR self-hosted update transport probe.\n' * 4)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def write(path, content, mode=0o644):
    # Keep the inode of edge/nginx.conf: it is a single-file Docker bind mount.
    with path.open('wb') as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(mode)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True)
    parser.add_argument('--network', required=True)
    parser.add_argument('--expected-edge-sha256', required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('root is required')
    if not re.fullmatch(r'nginx@sha256:[0-9a-f]{64}', args.image):
        raise ValueError('an immutable installed nginx digest is required')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', args.network):
        raise ValueError('invalid network')
    for path in (ROOT, PUBLIC, EDGE):
        if path.is_symlink():
            raise ValueError('managed path is a symlink')
    old_edge = EDGE.read_bytes()
    if hashlib.sha256(old_edge).hexdigest() != args.expected_edge_sha256:
        raise ValueError('edge config changed since inspection; inspect again')
    edge_info = json.loads(run('docker', 'inspect', EDGE_CONTAINER))[0]
    edge_id = edge_info['Id']
    if args.network not in edge_info['NetworkSettings']['Networks']:
        raise ValueError('edge is not on the specified network')
    run('docker', 'image', 'inspect', args.image)
    if ROOT.exists() and not (ROOT / 'deployment.json').exists():
        raise ValueError('unmanaged install directory already exists')
    if PUBLIC.exists() and not ROOT.exists():
        raise ValueError('unmanaged public directory already exists')
    if MARKER.encode() in old_edge:
        raise ValueError('already routed; inspect before upgrading an existing deployment')
    edge_text = old_edge.decode('utf-8')
    ssl_start = edge_text.index('listen 443 ssl;')
    at = edge_text.index('        location / {', ssl_start)
    snippet = (HERE / 'edge-location.conf').read_text(encoding='utf-8')
    candidate = (edge_text[:at] + snippet + '\n' + edge_text[at:]).encode()

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    ROOT.mkdir(mode=0o755, parents=True, exist_ok=True)
    backup = ROOT / 'backups' / stamp
    backup.mkdir(mode=0o700, parents=True, exist_ok=False)
    backup.parent.chmod(0o700)
    write(backup / 'edge-nginx.conf', old_edge, 0o600)
    write(backup / 'edge-candidate.conf', candidate, 0o600)
    for name in ('compose.yaml', 'nginx.conf', '.env', 'deployment.json'):
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, backup / name)
    for name in ('channels/android', 'releases', 'resources', 'artifacts', 'notes', 'diagnostics'):
        (PUBLIC / name).mkdir(mode=0o755, parents=True, exist_ok=True)
    write(PUBLIC / 'diagnostics/download-probe.txt', PROBE)
    immutable_probe = PUBLIC / ('artifacts/transport-probe-' + hashlib.sha256(PROBE).hexdigest() + '.txt')
    if immutable_probe.exists() and immutable_probe.read_bytes() != PROBE:
        raise ValueError('immutable probe identity conflict')
    write(immutable_probe, PROBE)
    for name in ('compose.yaml', 'nginx.conf'):
        write(ROOT / name, (HERE / name).read_bytes())
    write(ROOT / '.env', ('UPDATE_NGINX_IMAGE=' + args.image + '\nUPDATE_EDGE_NETWORK=' + args.network + '\n').encode(), 0o600)
    compose = ('docker', 'compose', '--project-name', 'agentatelier-updates', '--env-file', str(ROOT / '.env'), '-f', str(ROOT / 'compose.yaml'))
    started = False
    changed_edge = False
    try:
        run(*compose, 'config', '--quiet')
        # Offline deployment: image must have been inspected above, never pull/build.
        started = True
        run(*compose, 'up', '-d', '--wait', '--wait-timeout', '45', '--pull', 'never')
        static_id = run(*compose, 'ps', '-q', 'static').strip()
        run('docker', 'exec', static_id, 'nginx', '-t')
        run('docker', 'exec', EDGE_CONTAINER, 'wget', '-q', '-O', '/dev/null', 'http://agentatelier-updates:8080/updates/agentatelier/healthz')
        if EDGE.read_bytes() != old_edge:
            raise ValueError('edge config changed during static service startup')
        changed_edge = True
        write(EDGE, candidate)
        if run('docker', 'exec', EDGE_CONTAINER, 'cat', '/etc/nginx/nginx.conf').encode() != candidate:
            raise ValueError('edge bind mount does not see the candidate')
        run('docker', 'exec', EDGE_CONTAINER, 'nginx', '-t')
        run('docker', 'exec', EDGE_CONTAINER, 'nginx', '-s', 'reload')
        if json.loads(run('docker', 'inspect', EDGE_CONTAINER))[0]['Id'] != edge_id:
            raise ValueError('edge container unexpectedly changed')
        result = {'v': 1, 'installed_at': stamp, 'image': args.image, 'network': args.network,
                  'edge_backup': str(backup / 'edge-nginx.conf'), 'edge_container_unchanged': True,
                  'public_prefix': '/updates/agentatelier/', 'channel_published': False,
                  'probe_sha256': hashlib.sha256(PROBE).hexdigest()}
        write(ROOT / 'deployment.json', json.dumps(result, indent=2).encode())
        print(json.dumps(result))
    except Exception:
        if changed_edge:
            write(EDGE, old_edge)
            run('docker', 'exec', EDGE_CONTAINER, 'nginx', '-t')
            run('docker', 'exec', EDGE_CONTAINER, 'nginx', '-s', 'reload')
        if started:
            run(*compose, 'down')
        for name in ('compose.yaml', 'nginx.conf', '.env', 'deployment.json'):
            saved = backup / name
            if saved.exists():
                shutil.copy2(saved, ROOT / name)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Command output may contain host configuration; report only a stage/type.
        print('Deployment failed: ' + type(error).__name__ + '. Check the private SSH audit.', file=sys.stderr)
        sys.exit(1)
