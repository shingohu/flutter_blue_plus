import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { setTimeout } from 'node:timers/promises';

const [hdc, device, pid, output, count = '12'] = process.argv.slice(2);
if (!hdc || !device || !/^\d+$/.test(pid ?? '') || !output) {
  throw new Error('Usage: node collect_perf_cpu.mjs HDC DEVICE PID OUTPUT [COUNT]');
}
const samples = [];
for (let i = 0; i < Number(count); i++) {
  const raw = execFileSync(hdc, ['-t', device, 'shell', 'hidumper', '--cpuusage', pid],
    { encoding: 'utf8', timeout: 15000 });
  const row = raw.split('\n').find(line => line.trim().startsWith(`${pid} `));
  const window = raw.split('\n').find(line => line.startsWith('CPU usage from'));
  const columns = row?.trim().split(/\s+/);
  if (!columns || !columns[1]?.endsWith('%')) throw new Error(`Unexpected CPU output: ${raw}`);
  const sample = {
    host_utc: new Date().toISOString(), window,
    total_percent: Number.parseFloat(columns[1]),
    user_percent: Number.parseFloat(columns[2]),
    kernel_percent: Number.parseFloat(columns[3]), raw,
  };
  samples.push(sample);
  mkdirSync(dirname(output), { recursive: true });
  writeFileSync(output, JSON.stringify({ device, pid, source: 'hidumper --cpuusage PID', samples }, null, 2));
  console.log(JSON.stringify({ ...sample, raw: undefined }));
  if (i + 1 < Number(count)) await setTimeout(5000);
}
