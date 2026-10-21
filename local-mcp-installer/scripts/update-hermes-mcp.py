import json
import sys
from pathlib import Path

from ruamel.yaml import YAML

if len(sys.argv) < 4:
    print('Usage: python update-hermes-mcp.py <config.yaml> <name> <server-config.json> [check]', file=sys.stderr)
    sys.exit(1)

config_path = Path(sys.argv[1])
name = sys.argv[2]
server_path = Path(sys.argv[3])
check_only = len(sys.argv) > 4 and sys.argv[4] == 'check'
server = json.loads(server_path.read_text(encoding='utf-8'))

yaml = YAML(typ='rt')
yaml.preserve_quotes = True
data = yaml.load(config_path.read_text(encoding='utf-8')) or {}
servers = data.get('mcp_servers')
if servers is None:
    servers = {}
    data['mcp_servers'] = servers

if check_only:
    print(f"HERMES_MCP_EXISTS={str(name in servers).lower()}")
    sys.exit(0)

allowed_keys = ('command', 'args', 'env', 'url', 'headers', 'timeout')
entry = {key: server[key] for key in allowed_keys if key in server and server[key] is not None}
servers[name] = entry

with config_path.open('w', encoding='utf-8', newline='') as handle:
    yaml.dump(data, handle)

print(f'HERMES_MCP_UPDATED={name}')
