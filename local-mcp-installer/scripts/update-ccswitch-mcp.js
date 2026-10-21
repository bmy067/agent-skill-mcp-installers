const fs = require('fs');
const { DatabaseSync } = require('node:sqlite');

const [dbPath, name, configPath, agentsCsv = 'codex,claude', forceFlag = 'false', checkFlag = ''] = process.argv.slice(2);
if (!dbPath || !name || !configPath) {
  console.error('Usage: node update-ccswitch-mcp.js <db> <name> <server-config.json> [agents] [force] [check]');
  process.exit(1);
}

const force = forceFlag === 'true';
const checkOnly = checkFlag === 'check';
const agents = new Set((agentsCsv || '').split(',').map(v => v.trim().toLowerCase()).filter(Boolean));
const server = JSON.parse(fs.readFileSync(configPath, 'utf8'));
server.disabled = false;

const db = new DatabaseSync(dbPath);
try {
  const existing = db.prepare('select id, name from mcp_servers where name = ?').get(name);

  if (checkOnly) {
    console.log(`CC_SWITCH_EXISTS=${existing ? 'true' : 'false'}`);
    process.exit(0);
  }

  if (existing && !force) {
    console.error(`CC_SWITCH_CONFLICT=${name}`);
    process.exit(2);
  }

  const id = existing?.id || name;
  const flags = {
    enabled_claude: agents.has('claude') ? 1 : 0,
    enabled_codex: agents.has('codex') ? 1 : 0,
    enabled_gemini: 0,
    enabled_opencode: 0,
    enabled_hermes: agents.has('hermes') ? 1 : 0,
    enabled_grokbuild: 0,
    enabled_mcode: 0,
    enabled_pi: 0,
  };

  db.exec('BEGIN IMMEDIATE');
  try {
    if (existing) {
      db.prepare(`UPDATE mcp_servers SET server_config=?, enabled_claude=?, enabled_codex=?, enabled_gemini=?, enabled_opencode=?, enabled_hermes=?, enabled_grokbuild=?, enabled_mcode=?, enabled_pi=? WHERE id=?`).run(
        JSON.stringify(server), flags.enabled_claude, flags.enabled_codex, flags.enabled_gemini, flags.enabled_opencode, flags.enabled_hermes, flags.enabled_grokbuild, flags.enabled_mcode, flags.enabled_pi, id
      );
      console.log(`CC_SWITCH_MCP=UPDATED ${name}`);
    } else {
      db.prepare(`INSERT INTO mcp_servers
        (id,name,server_config,description,homepage,docs,tags,enabled_claude,enabled_codex,enabled_gemini,enabled_opencode,enabled_hermes,enabled_grokbuild,enabled_mcode,enabled_pi)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
        id, name, JSON.stringify(server), server.description || null, server.homepage || null, server.docs || null, JSON.stringify(server.tags || []),
        flags.enabled_claude, flags.enabled_codex, flags.enabled_gemini, flags.enabled_opencode, flags.enabled_hermes, flags.enabled_grokbuild, flags.enabled_mcode, flags.enabled_pi
      );
      console.log(`CC_SWITCH_MCP=INSERTED ${name}`);
    }
    db.exec('COMMIT');
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
} finally {
  db.close();
}
