/**
 * Claude subscription bridge for Superlocal AI triage.
 *
 * Superlocal speaks the OpenAI Responses API. A Claude Pro/Max subscription has no API key,
 * so this loopback-only server accepts the app's Responses requests and answers them with
 * the Claude Code CLI (`claude -p`), which uses the subscription login of this macOS user.
 *
 *   bun --no-env-file run claude-bridge          # bridge only
 *   bun --no-env-file run start:claude           # bridge + the app
 *
 * On first start it writes ai-inference.json (mode 0600) beside superlocal.local.json,
 * with a random local token. The bridge rejects requests without that token.
 */
import { randomBytes } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { ROOT_DIR } from '../apps/local-host/src/config'

const PORT = Number(process.env.CLAUDE_BRIDGE_PORT ?? 8792)
const CLAUDE = process.env.CLAUDE_BRIDGE_BIN ?? 'claude'
const CONCURRENCY = Math.max(1, Math.min(4, Number(process.env.CLAUDE_BRIDGE_CONCURRENCY ?? 2)))
const CHILD_TIMEOUT_MS = 115_000
const configPath = resolve(process.env.SUPERLOCAL_AI_CONFIG ??
  join(dirname(resolve(process.env.SUPERLOCAL_CONFIG ?? join(ROOT_DIR, 'superlocal.local.json'))), 'ai-inference.json'))
// Empty working directory: no project CLAUDE.md, memory or settings leak into triage prompts.
const workDir = join(homedir(), '.superlocal-claude-bridge')
mkdirSync(workDir, { recursive: true, mode: 0o700 })

const MODELS = [
  { id: 'claude-haiku-5-5', label: 'Claude Haiku 5.5 (subscription)', pricing: null },
  { id: 'claude-sonnet-5-5', label: 'Claude Sonnet 5.5 (subscription)', pricing: null },
  { id: 'claude-opus-5-5', label: 'Claude Opus 5.5 (subscription)', pricing: null },
]

function ensureConfig(): string {
  if (existsSync(configPath)) {
    const existing = JSON.parse(readFileSync(configPath, 'utf8'))
    if (typeof existing.endpoint === 'string' && existing.endpoint.startsWith(`http://127.0.0.1:${PORT}/`)) return existing.apiKey
    throw new Error(`${configPath} exists but does not point at this bridge. Move it away to let the bridge create its own.`)
  }
  const apiKey = `slbridge_${randomBytes(24).toString('hex')}`
  writeFileSync(configPath, JSON.stringify({
    version: 1, protocol: 'openai-responses', name: 'Claude (subscription)',
    endpoint: `http://127.0.0.1:${PORT}/v1/responses`, apiKey,
    defaultModel: MODELS[0].id, models: MODELS, timeoutMs: 120_000, concurrency: CONCURRENCY, reasoningEffort: 'low',
  }, null, 2) + '\n', { mode: 0o600 })
  chmodSync(configPath, 0o600)
  console.log(`[claude-bridge] Wrote ${configPath}`)
  return apiKey
}

const token = ensureConfig()

let running = 0
const waiting: Array<() => void> = []
async function slot<T>(work: () => Promise<T>): Promise<T> {
  if (running >= CONCURRENCY) await new Promise<void>(release => waiting.push(release))
  running++
  try { return await work() } finally { running--; waiting.shift()?.() }
}

// The app's triage prompt was tuned for OpenAI models. Claude follows it well but often skips the
// evidence entry for `type`, which the app then rejects (AI_EVIDENCE_REQUIRED). This checklist
// restates the app's own validation rules; it does not loosen them.
const TRIAGE_CHECKLIST = `

EVIDENCE CHECKLIST (the answer is rejected if any item is missing). Before you output, add one evidence entry, with an exact quote from the source, for EACH of these that applies:
- type is anything other than "unknown" or "other" → an entry with field "type" (always required for notification, conversation, invitation, newsletter, marketing, etc.).
- response is "needed" → an entry with field "response".
- actions is not empty → an entry with field "action".
- task is "required" → an entry with field "task" that quotes an INCOMING message.
- urgency is "immediate" or "deadline" → an entry with field "urgency".
- risk is "unsolicited", "spam_suspected" or "phishing_suspected" → an entry with field "risk".
If you cannot quote evidence for a value, choose the value that needs none (for example type "other", empty actions).`

const effortFor =(value: unknown) => value === 'high' ? 'high' : value === 'medium' ? 'medium' : 'low'

function childEnv(): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(process.env)) if (value !== undefined) env[key] = value
  // Force the subscription login: no API key, no proxy, no nested-session markers.
  for (const key of ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[key]
  return env
}

type ClaudeResult = { status: number; body: unknown }

async function runClaude(request: Record<string, any>, signal: AbortSignal): Promise<ClaudeResult> {
  const schema = request.text?.format?.schema
  const prompt = Array.isArray(request.input)
    ? request.input.map((item: any) => typeof item?.content === 'string' ? item.content : '').join('\n\n')
    : String(request.input ?? '')
  if (!prompt) return { status: 400, body: { error: { message: 'empty input' } } }
  const args = [
    '-p', '--output-format', 'json', '--model', String(request.model),
    '--system-prompt', String(request.instructions ?? '') + (request.text?.format?.name === 'triage_result_v2' ? TRIAGE_CHECKLIST : ''),
    '--tools', '', '--setting-sources', '', '--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence',
    '--effort', effortFor(request.reasoning?.effort),
  ]
  if (schema) args.push('--json-schema', JSON.stringify(schema))
  const child = Bun.spawn([CLAUDE, ...args], { cwd: workDir, env: childEnv(), stdin: new Blob([prompt]), stdout: 'pipe', stderr: 'pipe' })
  const kill = () => { try { child.kill('SIGTERM') } catch { /* already gone */ } }
  signal.addEventListener('abort', kill, { once: true })
  const timer = setTimeout(kill, CHILD_TIMEOUT_MS)
  try {
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    if (signal.aborted) return { status: 499, body: { error: { message: 'aborted' } } }
    let data: any
    try { data = JSON.parse(stdout) } catch {
      console.error(`[claude-bridge] claude exited ${code}: ${stderr.slice(0, 300) || stdout.slice(0, 300)}`)
      return { status: 502, body: { error: { message: 'claude CLI failed' } } }
    }
    if (data.is_error) {
      const message = String(data.result ?? data.subtype ?? 'error')
      console.error(`[claude-bridge] ${message.slice(0, 300)}`)
      const status = /authenticat|login|oauth/i.test(message) ? 401 : /rate|limit|usage/i.test(message) ? 429 : 502
      return { status, body: { error: { message: status === 401 ? 'Claude login required: run `claude auth login`' : 'Claude request failed' } } }
    }
    const output = data.structured_output !== undefined ? JSON.stringify(data.structured_output) : String(data.result ?? '')
    // Opt-in only: the dump contains mail content.
    if (process.env.CLAUDE_BRIDGE_DEBUG_DIR) {
      mkdirSync(process.env.CLAUDE_BRIDGE_DEBUG_DIR, { recursive: true, mode: 0o700 })
      writeFileSync(join(process.env.CLAUDE_BRIDGE_DEBUG_DIR, `${Date.now()}.json`), JSON.stringify({ prompt, instructions: request.instructions, output, raw: data }, null, 2), { mode: 0o600 })
    }
    const u = data.usage ?? {}
    const cached = u.cache_read_input_tokens ?? 0, written = u.cache_creation_input_tokens ?? 0
    const input = (u.input_tokens ?? 0) + cached + written, out = u.output_tokens ?? 0
    return {
      status: 200,
      body: {
        id: `resp_${data.session_id ?? randomBytes(8).toString('hex')}`.replace(/[^a-zA-Z0-9_-]/g, ''),
        object: 'response', status: 'completed', model: request.model, error: null,
        output: [{ type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: output }] }],
        usage: { input_tokens: input, output_tokens: out, total_tokens: input + out,
          input_tokens_details: { cached_tokens: cached, cache_write_tokens: written }, output_tokens_details: { reasoning_tokens: 0 } },
      },
    }
  } finally {
    clearTimeout(timer)
    signal.removeEventListener('abort', kill)
  }
}

const server = Bun.serve({
  hostname: '127.0.0.1', port: PORT, idleTimeout: 255,
  async fetch(req) {
    const url = new URL(req.url)
    if (req.method === 'GET' && url.pathname === '/health') return Response.json({ ok: true })
    if (req.method !== 'POST' || url.pathname !== '/v1/responses') return new Response('not found', { status: 404 })
    if (req.headers.get('authorization') !== `Bearer ${token}`) return new Response('unauthorized', { status: 401 })
    const raw = await req.text()
    if (raw.length > 65_536) return new Response('too large', { status: 413 })
    let request: Record<string, any>
    try { request = JSON.parse(raw) } catch { return new Response('bad json', { status: 400 }) }
    if (!MODELS.some(model => model.id === request.model)) return Response.json({ error: { message: 'model not allowed' } }, { status: 400 })
    const started = Date.now()
    const result = await slot(() => runClaude(request, req.signal))
    console.log(`[claude-bridge] ${request.model} → ${result.status} in ${Date.now() - started} ms`)
    return Response.json(result.body, { status: result.status })
  },
})
console.log(`[claude-bridge] Listening on http://127.0.0.1:${server.port} (concurrency ${CONCURRENCY})`)

// --with-app: also run the Superlocal app and stop both together.
// Same steps as `bun run start`, but the launcher is a direct child, so stop signals reach it
// (a package-script shell does not forward a SIGINT that comes from outside a terminal).
if (process.argv.includes('--with-app')) {
  const bun = process.execPath
  const build = Bun.spawnSync([bun, '--no-env-file', 'run', '--cwd', join(ROOT_DIR, 'apps', 'web'), 'build'], { stdio: ['ignore', 'inherit', 'inherit'] })
  if (build.exitCode !== 0) { server.stop(true); process.exit(build.exitCode ?? 1) }
  const app = Bun.spawn([bun, '--no-env-file', join(ROOT_DIR, 'scripts', 'dev.ts'), '--built'], { cwd: ROOT_DIR, stdio: ['inherit', 'inherit', 'inherit'] })
  const stop = () => {
    try { app.kill('SIGINT') } catch { /* gone */ }
    setTimeout(() => { try { app.kill('SIGKILL') } catch { /* gone */ } process.exit(1) }, 10_000).unref()
  }
  process.on('SIGINT', stop)
  process.on('SIGTERM', stop)
  app.exited.then(code => { server.stop(true); process.exit(code ?? 0) })
}
