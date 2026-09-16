import { spawn, execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { promisify } from 'node:util';
import { filterPlan } from './filter_ab_plan.mjs';

const [flutter, hdc, device, output, suite = 'original'] = process.argv.slice(2);
if (!output || !device || !hdc || !flutter) throw new Error('Usage: node run_filter_ab.mjs FLUTTER HDC DEVICE NEW_OUTPUT [original|low-rate]');
const plan = filterPlan(suite);
if (existsSync(output)) throw new Error('Refusing to reuse output directory');
mkdirSync(output, { recursive: true });
const sources = ['lib/filter_ab_main.dart', 'lib/benchmark/legacy_characteristic.dart',
  '../lib/src/bluetooth_characteristic.dart', '../lib/src/flutter_blue_plus.dart',
  'ohos/entry/src/main/ets/benchmark/PerfBenchmarkPlugin.ets',
  'tool/run_filter_ab.mjs', 'tool/filter_ab_plan.mjs', 'tool/summarize_filter_ab.mjs'];
const fingerprints = () => Object.fromEntries(sources.map(file => [file,
  createHash('sha256').update(readFileSync(file)).digest('hex')]));
const manifest = { device, flutter, hdc, suite, plan, started_utc: new Date().toISOString(),
  sources: fingerprints(), runs: [] };
const save = () => writeFileSync(join(output, 'manifest.json'), JSON.stringify(manifest, null, 2));
save();
const exec = promisify(execFile);
const pids = new Set();
for (let run = 1; run <= 3; run++) {
  const record = { run, run_token: randomUUID(), reverse: run === 2, started_utc: new Date().toISOString() };
  manifest.runs.push(record); save();
  const log = createWriteStream(join(output, `run${run}.log`));
  let completion, closed = false, code, tail = '', lineTail = '', spawnError;
  const child = spawn(flutter, ['--suppress-analytics', 'run', '-d', device,
    '--profile', '--no-pub', '-t', 'lib/filter_ab_main.dart', `--dart-define=FILTER_REVERSE=${record.reverse}`,
    `--dart-define=FILTER_LOW_RATE=${suite === 'low-rate'}`,
    `--dart-define=FILTER_RUN_TOKEN=${record.run_token}`],
  { stdio: ['pipe', 'pipe', 'pipe'] });
  child.on('error', error => { spawnError = error; });
  const exited = new Promise(resolve => child.once('close', value => { code = value; closed = true; resolve(); }));
  const capture = chunk => {
    lineTail += chunk.toString();
    const lines = lineTail.split(/\r?\n/); lineTail = lines.pop();
    for (const line of lines) {
      if (/^\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}/.test(line) && !line.includes('flutter_blue_plus_example')) continue;
      log.write(`${line}\n`); tail = (tail + line + '\n').slice(-5000);
      const done = line.match(/FBP_FILTER_DONE (\{.*\})/);
      if (done) {
        const parsed = JSON.parse(done[1]);
        if (parsed.run_token === record.run_token) completion = parsed;
      }
      const result = line.match(/FBP_FILTER_CASE (\{.*\})/);
      if (result) {
        const row = JSON.parse(result[1]);
        if (row.run_token !== record.run_token) continue;
        console.log(`RUN ${run} pair=${row.pair} ${row.hz}Hz ${row.listeners}/${row.scenario}/${row.target_position} ${row.variant} actual_hz=${row.actual_hz.toFixed(2)} delivery_p95_us=${row.delivery_stats_us.p95} rtt_p95_us=${row.native_rtt_stats_us.p95}`);
      }
    }
  };
  child.stdout.on('data', capture); child.stderr.on('data', capture);
  try {
    console.log(`FILTER_RUN_START ${run} reverse=${record.reverse}`);
    const start = Date.now();
    while (!completion) {
      if (spawnError) throw spawnError;
      if (closed) throw new Error(`Flutter exited ${code}: ${tail}`);
      if (Date.now() - start > 600000) throw new Error(`Run timeout: ${tail}`);
      await setTimeout(1000);
    }
    record.completion = completion; save();
    const local = resolve(output, `run${run}.json`);
    const transfer = await exec(hdc, ['-t', device, 'file', 'recv', '-b',
      'com.jmx.flutter_blue_plus_example', completion.path, local], { timeout: 60000 });
    record.export_output = transfer.stdout + transfer.stderr;
    const data = JSON.parse(readFileSync(local));
    if (completion.failure || data.failure || data.mode !== 'profile' || data.results.length !== plan.cases ||
        data.suite !== suite || data.schema !== plan.schema || data.count !== plan.count ||
        data.pid !== completion.pid || pids.has(data.pid) || data.reverse !== record.reverse ||
        data.run_token !== record.run_token) {
      throw new Error(`Invalid run ${run}: ${data.failure ?? JSON.stringify(completion)}`);
    }
    pids.add(data.pid);
    if (JSON.stringify(fingerprints()) !== JSON.stringify(manifest.sources)) throw new Error('Benchmark sources changed during run');
    record.finished_utc = new Date().toISOString(); save();
    console.log(`FILTER_RUN_DONE ${run} pid=${data.pid} cases=${data.results.length}`);
  } catch (error) {
    record.failure = String(error); save(); throw error;
  } finally {
    if (!closed) {
      child.stdin.write('q');
      await Promise.race([exited, setTimeout(5000)]);
      if (!closed) child.kill('SIGTERM');
      await Promise.race([exited, setTimeout(5000)]);
      if (!closed) child.kill('SIGKILL');
      await exited;
    }
    log.end();
  }
}
manifest.finished_utc = new Date().toISOString(); save();
