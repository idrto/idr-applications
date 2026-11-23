// Read-only signed-in startup benchmark. Never starts or stops a Target agent.
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';

const args = process.argv.slice(2);
function option(name, fallback) {
  const at = args.indexOf(name);
  return at < 0 ? fallback : args[at + 1];
}
const cli = option('--cli');
const runs = Number(option('--runs', '3'));
const cwd = resolve(option('--cwd', process.cwd()));
const output = resolve(option('--out', 'startup-benchmark.json'));
if (!cli || !Number.isInteger(runs) || runs < 1 || runs > 20) {
  throw new Error('Usage: node benchmark-startup.mjs --cli <idr.exe> [--runs 3] [--cwd <apps directory>] [--out report.json]');
}
// Phase timings come from the CLI's idr.log/1 records (target.phase.completed,
// app.startup.completed, target.start.failed), written to a private log dir per run.
async function readRecords(dir) {
  const out = [];
  const walk = async d => {
    for (const e of await readdir(d, { withFileTypes: true }).catch(() => [])) {
      const p = join(d, e.name);
      if (e.isDirectory()) await walk(p);
      else if (e.name.endsWith('.jsonl')) {
        for (const line of (await readFile(p, 'utf8')).split('\n')) {
          try { if (line.trim()) out.push(JSON.parse(line)); } catch { /* partial last line */ }
        }
      }
    }
  };
  await walk(dir);
  return out;
}
const results = [];
for (let i = 0; i < runs; i++) {
  const started = performance.now();
  const row = { run: i + 1, reportReadyMs: null, processExitMs: null, phases: [] };
  const logDir = await mkdtemp(join(tmpdir(), 'idr-bench-'));
  await new Promise((resolveRun, reject) => {
    const child = spawn(resolve(cli), ['--flavor', 'prod', '--verbose', '--json', 'status'], {
      cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, IDR_LOG_DIR: logDir },
    });
    const buffers = { stdout: '', stderr: '' };
    const capture = (stream, chunk) => {
      buffers[stream] += chunk.toString();
      const lines = buffers[stream].split(/\r?\n/);
      buffers[stream] = lines.pop();
      for (const line of lines) {
        if (row.reportReadyMs === null && /"controlPlane"\s*:/.test(line)) {
          row.reportReadyMs = Math.round(performance.now() - started);
        }
        const agent = /"agentRunning"\s*:\s*(true|false)/.exec(line);
        if (agent) row.agentRunning = agent[1] === 'true';
      }
    };
    child.stdout.on('data', chunk => capture('stdout', chunk));
    child.stderr.on('data', chunk => capture('stderr', chunk));
    const timer = setTimeout(() => { row.timedOut = true; child.kill(); }, 90000);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('close', code => {
      clearTimeout(timer);
      row.processExitMs = Math.round(performance.now() - started);
      row.exitCode = code;
      readRecords(logDir).then(records => {
        for (const r of records) {
          const a = r.attrs ?? {};
          if (r.event === 'target.phase.completed') {
            row.phases.push({ phase: a.phase, elapsedMs: Number(a.duration_ms), detail: `outcome=${a.outcome}` });
          } else if (r.event === 'app.startup.completed') {
            row.phases.push({ phase: 'startup', elapsedMs: Number(a.duration_ms), detail: '' });
          } else if (r.event === 'target.start.failed') {
            row.startupFailed = true;
          }
        }
        row.logRecords = records.length;
      }).catch(() => {}).finally(() => rm(logDir, { recursive: true, force: true }).finally(resolveRun));
    });
  });
  results.push(row);
  console.log(JSON.stringify(row));
}
const valid = results.filter(row => row.exitCode === 0 && row.reportReadyMs !== null && !row.startupFailed);
const median = values => {
  const sorted = values.sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length ? sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2 : null;
};
const report = {
  createdAt: new Date().toISOString(), cli: resolve(cli), command: 'status',
  // This measures state restoration, not agent launch or successful tunnel readiness.
  successfulRuns: valid.length, runs: results,
  medianReportReadyMs: median(valid.map(row => row.reportReadyMs)),
  medianProcessExitMs: median(valid.map(row => row.processExitMs)),
};
await mkdir(dirname(output), { recursive: true });
await writeFile(output, JSON.stringify(report, null, 2));
console.log(`Saved ${output}`);
if (valid.length !== results.length) process.exitCode = 1;
