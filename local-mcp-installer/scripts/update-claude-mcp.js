const fs = require('fs');

const [claudePath, name, configPath, mode = 'upsert'] = process.argv.slice(2);
if (!claudePath || !name || !configPath) {
  console.error('Usage: node update-claude-mcp.js <claude.json> <name> <server-config.json> [upsert|remove]');
  process.exit(1);
}

const data = fs.existsSync(claudePath) ? JSON.parse(fs.readFileSync(claudePath, 'utf8')) : {};
data.mcpServers = data.mcpServers || {};

if (mode === 'remove') {
  delete data.mcpServers[name];
} else {
  const server = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  data.mcpServers[name] = server;
}

fs.writeFileSync(claudePath, JSON.stringify(data, null, 2) + '\n', 'utf8');
console.log(`CLAUDE_MCP_${mode.toUpperCase()}=${name}`);
