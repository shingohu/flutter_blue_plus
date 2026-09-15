import { execFile, spawn } from 'node:child_process';
import { copyFileSync, createWriteStream, existsSync, mkdirSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { promisify } from 'node:util';

const [flutter, device, output, ...requested] = process.argv.slice(2);
if (!flutter || !device || !output) throw new Error('Usage: node run_memory_suite.mjs FLUTTER DEVICE OUTPUT [CASES...]');
const cases = requested.length ? requested : ['idle', 'echo', 'raw', 'plugin'];
if (cases.some(name => !['idle', 'echo', 'raw', 'plugin', 'echo_large_bytes', 'echo_large_list'].includes(name))) throw new Error('Invalid case');
const sampling = process.env.FBP_MEMORY_SAMPLING ?? 'periodic';
const cycles = Number(process.env.FBP_MEMORY_CYCLES ?? 2);
const operations = Number(process.env.FBP_MEMORY_OPERATIONS ?? 0);
const checkpoints = process.env.FBP_MEMORY_CHECKPOINTS === 'true' || sampling === 'endpoints';
if (!['periodic', 'endpoints'].includes(sampling) || !Number.isInteger(cycles) || cycles < 1 || cycles > 20 ||
    !Number.isInteger(operations) || operations < 0 || operations > 100000 ||
    (operations > 0 && cases.some(name => !name.startsWith('echo')))) throw new Error('Invalid memory configuration');
const config = { sampling, cycles, operations_per_cycle: operations, checkpoints };
const nativeTrace = process.env.FBP_NATIVE_TRACE === 'true';
const arkHeapSnapshot = process.env.FBP_ARK_HEAP_SNAPSHOT === 'true';
const workloadTimeout = nativeTrace ? 300000 : operations ? 900000 : (cycles * 45 + 90) * 1000;
const hdc = process.env.FBP_HDC;
if ((nativeTrace || arkHeapSnapshot) && !hdc) throw new Error('FBP_HDC required for native tracing or heap export');
const execFileAsync = promisify(execFile);
const deviceCommand = async args => {
  const result = await execFileAsync(hdc, ['-t', device, ...args], { timeout: 60000, maxBuffer: 4 * 1024 * 1024 });
  return result.stdout + result.stderr;
};
mkdirSync(output, { recursive: true });
for (const name of cases) {
  if (existsSync(join(output, `${name}.json`)) || existsSync(join(output, `${name}.log`))) {
    throw new Error(`Results already exist for ${name}; choose a new directory or preserve the old run first`);
  }
}

async function rpc(base, method, params = {}) {
  const url = new URL(method, base);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, String(value));
  let response;
  try {
    response = await fetch(url, { signal: AbortSignal.timeout(30000) });
  } catch (error) {
    throw new Error(`${method}: ${error}`);
  }
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${method}`);
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error)}`);
  return body.result;
}

for (const name of cases) {
  const record = { case: name, config, host_started_utc: new Date().toISOString(), samples: [] };
  const resultFile = join(output, `${name}.json`);
  const save = () => writeFileSync(resultFile, JSON.stringify(record, null, 2));
  const log = createWriteStream(join(output, `${name}.log`));
  let exitCode;
  let base;
  let tail = '';
  let lineTail = '';
  let deviceFinished = false;
  let nativeStarted = false;
  let nativeProcess;
  let nativeExit;
  let nativeClosed = false;
  const stopNativeTrace = async () => {
    if (!nativeStarted) return;
    record.native_trace.stop_output = await deviceCommand(['shell', 'hiprofiler_cmd', 'stop']);
    record.native_trace.stopped_utc = new Date().toISOString();
    nativeStarted = false;
    if (nativeExit) {
      await Promise.race([nativeExit, setTimeout(5000)]);
      if (!nativeClosed) nativeProcess.kill('SIGTERM');
      await nativeExit;
    }
    save();
    const local = resolve(output, `${name}_native.htrace`);
    record.native_trace.export_output = await deviceCommand(['file', 'recv', record.native_trace.device_path, local]);
    record.native_trace.bytes = statSync(local).size;
    save();
    console.log(`NATIVE_TRACE_SAVED ${local} bytes=${record.native_trace.bytes}`);
    if (record.native_trace.bytes < 1024) throw new Error('Native trace is empty');
  };
  const child = spawn(flutter, ['--suppress-analytics', 'run', '-d', device,
    '--profile', '--no-pub', '-t', 'lib/memory_main.dart', `--dart-define=MEMORY_CASE=${name}`,
    `--dart-define=MEMORY_CYCLES=${cycles}`, `--dart-define=MEMORY_OPERATIONS=${operations}`,
    `--dart-define=MEMORY_CHECKPOINTS=${checkpoints}`],
    { cwd: process.cwd(), stdio: ['pipe', 'pipe', 'pipe'] });
  const exited = new Promise(resolve => child.once('exit', code => { exitCode = code; resolve(code); }));
  const outputChunk = chunk => {
    lineTail += chunk.toString();
    const lines = lineTail.split(/\r?\n/);
    lineTail = lines.pop();
    for (const line of lines) {
      if (/^\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}/.test(line) && !line.includes('flutter_blue_plus_example')) continue;
      log.write(`${line}\n`);
      tail = (tail + line + '\n').slice(-16000);
      const match = line.match(/A Dart VM Service[^\n]*available at:\s*(http:\/\/[^\s]+)/);
      if (match) base = match[1];
      if (line.includes(`FBP_MEMORY_FINISHED case=${name} `)) deviceFinished = true;
      const checkpoint = line.match(/FBP_MEMORY_CHECKPOINT (\{.*\})/);
      if (checkpoint) {
        const sample = JSON.parse(checkpoint[1]);
        console.log(`MEMORY_CHECKPOINT ${name} ${sample.checkpoint}/${sample.cycle} ops=${sample.operations} pss_kb=${sample.native.pss_kb} native_bytes=${sample.native.native_allocated_bytes}`);
      }
    }
  };
  child.stdout.on('data', outputChunk);
  child.stderr.on('data', outputChunk);
  try {
    console.log(`MEMORY_START ${name} ${JSON.stringify(config)}`);
    const launched = Date.now();
    while (!base) {
      if (exitCode !== undefined) throw new Error(`Flutter exited: ${exitCode}; ${tail.slice(-4000)}`);
      if (Date.now() - launched > 150000) throw new Error(`VM service timeout: ${tail.slice(-4000)}`);
      await setTimeout(1000);
    }
    record.vm_service = base;
    let isolateId;
    for (let attempt = 0; attempt < 30; attempt++) {
      const vm = await rpc(base, 'getVM');
      const main = vm.isolates.find(isolate => isolate.name === 'main');
      if (main) {
        const isolate = await rpc(base, 'getIsolate', { isolateId: main.id });
        if (isolate.extensionRPCs?.includes('ext.fbp.memoryStart')) { isolateId = main.id; break; }
      }
      await setTimeout(1000);
    }
    if (!isolateId) throw new Error('Memory test extension unavailable');
    const snapshot = async () => {
      const started = Date.now();
      const app = await rpc(base, 'ext.fbp.memorySnapshot', { isolateId });
      const dart = await rpc(base, 'getMemoryUsage', { isolateId });
      return { host_utc: new Date().toISOString(), sample_rpc_ms: Date.now() - started, ...app, dart };
    };
    record.before_start = await snapshot();
    const appConfig = record.before_start.config;
    if (appConfig.cycles !== cycles || appConfig.operations_per_cycle !== operations || appConfig.checkpoints !== checkpoints) {
      throw new Error('Device configuration mismatch');
    }
    save();
    if (nativeTrace) {
      await rpc(base, 'ext.fbp.memoryPrepare', { isolateId });
      const prefix = `/data/local/tmp/fbp_native_${record.before_start.pid}_${Date.now()}`;
      const localConfig = resolve(output, `${name}_native.pbtxt`);
      copyFileSync(new URL('./native_hook.pbtxt', import.meta.url), localConfig);
      record.native_trace = { device_path: `${prefix}.htrace`, config_path: `${prefix}.pbtxt` };
      record.native_trace.upload_output = await deviceCommand(['file', 'send', localConfig, record.native_trace.config_path]);
      save();
      nativeStarted = true;
      record.native_trace.start_output = '';
      nativeProcess = spawn(hdc, ['-t', device, 'shell', 'hiprofiler_cmd', 'start', '-s',
        '-c', record.native_trace.config_path, '-o', record.native_trace.device_path],
      { stdio: ['ignore', 'pipe', 'pipe'] });
      nativeExit = new Promise(resolve => nativeProcess.once('close', code => {
        nativeClosed = true;
        record.native_trace.command_exit_code = code;
        resolve();
      }));
      // On this device, even --nonblock keeps the hdc connection open until stop.
      const ready = new Promise((resolve, reject) => {
        nativeProcess.once('error', reject);
        nativeProcess.once('close', code => reject(new Error(`Native command exited before ready: ${code}`)));
        const onOutput = chunk => {
          record.native_trace.start_output += chunk.toString();
          const match = record.native_trace.start_output.match(/Profiling started with session ID:\s*(\d+)/);
          if (match) {
            record.native_trace.session_id = Number(match[1]);
            resolve();
          }
        };
        nativeProcess.stdout.on('data', onOutput);
        nativeProcess.stderr.on('data', onOutput);
      });
      await Promise.race([ready, setTimeout(30000).then(() => { throw new Error('Native trace ready timeout'); })]);
      record.native_trace.started_utc = new Date().toISOString();
      console.log(`NATIVE_TRACE_START ${record.native_trace.start_output.trim()}`);
      save();
      if (/failed|error|unrecognized/i.test(record.native_trace.start_output)) throw new Error('Native trace start failed');
    }
    await rpc(base, 'ext.fbp.memoryStart', { isolateId });
    let phase;
    const started = Date.now();
    if (sampling === 'endpoints') {
      // No VM RPC polling during baseline, load, recovery, or cooldown.
      while (!deviceFinished && Date.now() - started < workloadTimeout) {
        if (exitCode !== undefined) throw new Error(`Flutter exited during workload: ${exitCode}`);
        await setTimeout(1000);
      }
      if (!deviceFinished) throw new Error('Device completion timeout');
    }
    while (Date.now() - started < workloadTimeout) {
      const sample = await snapshot();
      record.samples.push(sample);
      save();
      const current = `${sample.phase}/${sample.cycle}`;
      if (current !== phase) {
        phase = current;
        console.log(`MEMORY_PHASE ${name} ${phase} ops=${sample.operations} pss_kb=${sample.native.pss_kb} ark_kb=${sample.native.ark_heap_used_kb} dart_bytes=${sample.dart.heapUsage}`);
      }
      if (sample.finished) {
        if (sample.failure || sample.errors) throw new Error(sample.failure ?? 'Validation failed');
        break;
      }
      await setTimeout(2000);
    }
    if (!record.samples.at(-1)?.finished) throw new Error('Workload timeout');
    record.checkpoints = record.samples.at(-1).checkpoints ?? [];
    if (checkpoints && (record.checkpoints.length !== 2 * cycles + 2 ||
        record.checkpoints.some(sample => sample.errors || sample.failure))) throw new Error('Invalid checkpoints');
    if (operations && record.samples.at(-1).operations !== cycles * operations) throw new Error('Operation count mismatch');
    if (arkHeapSnapshot) {
      record.ark_gc_probe = { started_utc: new Date().toISOString() };
      save();
      try {
        const heap = await rpc(base, 'ext.fbp.arkHeapSnapshot', { isolateId });
        record.ark_gc_probe.device_path = heap.path;
        await setTimeout(12000);
        record.post_ark_gc = await snapshot();
        const local = resolve(output, `${name}_ark_after_gc.rawheap`);
        record.ark_gc_probe.export_output = await deviceCommand(['file', 'recv', '-b',
          'com.jmx.flutter_blue_plus_example', heap.path, local]);
        record.ark_gc_probe.bytes = statSync(local).size;
        console.log(`ARK_HEAP_SAVED ${local} bytes=${record.ark_gc_probe.bytes}`);
      } catch (error) {
        record.ark_gc_probe.error = String(error);
        console.error(`ARK_HEAP_PROBE_FAILED ${error}`);
      }
      record.ark_gc_probe.finished_utc = new Date().toISOString();
      save();
    }
    await stopNativeTrace();
    // Explicit probe after natural recovery, never mixed into normal samples.
    try {
      const allocation = await rpc(base, 'getAllocationProfile', { isolateId, gc: true });
      writeFileSync(join(output, `${name}_dart_after_gc.json`), JSON.stringify(allocation));
      await setTimeout(2000);
      record.post_dart_gc = await snapshot();
    } catch (error) {
      record.gc_probe_error = String(error);
    }
    record.host_finished_utc = new Date().toISOString();
    save();
    console.log(`MEMORY_DONE ${name} samples=${record.samples.length} pid=${record.samples.at(-1).pid}`);
  } catch (error) {
    record.failure = String(error);
    record.flutter_exited_before_cleanup = exitCode !== undefined;
    record.host_failed_utc = new Date().toISOString();
    save();
    throw error;
  } finally {
    try {
      await stopNativeTrace();
    } catch (error) {
      record.native_cleanup_error = String(error);
      save();
      console.error(`NATIVE_TRACE_CLEANUP_FAILED ${error}`);
    }
    if (exitCode === undefined) {
      child.stdin.write('q');
      await Promise.race([exited, setTimeout(5000)]);
      if (exitCode === undefined) child.kill('SIGTERM');
      await exited;
    }
    log.end();
  }
}
