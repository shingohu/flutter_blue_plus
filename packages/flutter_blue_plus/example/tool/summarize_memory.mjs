import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [directory, ...requested] = process.argv.slice(2);
if (!directory) throw new Error('Usage: node summarize_memory.mjs DIRECTORY [CASES...]');
const names = requested.length ? requested : ['idle', 'echo', 'raw', 'plugin'];
const mib = bytes => bytes / 1048576;
function metrics(sample) {
  return {
    elapsed_s: sample.elapsed_us / 1e6,
    operations: sample.operations,
    pss_mib: sample.native.pss_kb / 1024,
    rss_mib: sample.native.rss_kb / 1024,
    native_allocated_mib: mib(sample.native.native_allocated_bytes),
    native_free_mib: mib(sample.native.native_free_bytes),
    ark_used_mib: sample.native.ark_heap_used_kb / 1024,
    ark_capacity_mib: sample.native.ark_heap_capacity_kb / 1024,
    ark_arrays_mib: sample.native.ark_arrays_kb / 1024,
    ark_gc_count: sample.native.ark_gc['ark.gc.gc-count'],
    ark_allocated_mib: mib(sample.native.ark_gc['ark.gc.gc-bytes-allocated']),
    ark_freed_mib: mib(sample.native.ark_gc['ark.gc.gc-bytes-freed']),
    dart_used_mib: mib(sample.dart.heapUsage),
    dart_capacity_mib: mib(sample.dart.heapCapacity),
    dart_external_mib: mib(sample.dart.externalUsage),
  };
}
const pids = new Set();
const results = names.map(name => {
  const record = JSON.parse(readFileSync(join(directory, `${name}.json`), 'utf8'));
  const samples = record.samples;
  if (record.failure || !samples.at(-1)?.finished) throw new Error(`${name}: incomplete`);
  const pid = samples[0].pid;
  if (pids.has(pid)) throw new Error(`${name}: reused process`);
  pids.add(pid);
  samples.forEach((sample, i) => {
    if (sample.failure || sample.errors || sample.pid !== pid || sample.case !== name) {
      throw new Error(`${name}: invalid sample ${i}`);
    }
    if (i && (sample.elapsed_us <= samples[i - 1].elapsed_us ||
        sample.operations < samples[i - 1].operations)) throw new Error(`${name}: sample order`);
  });
  const phases = [];
  for (const sample of samples) {
    const key = `${sample.phase}/${sample.cycle}`;
    let phase = phases.at(-1);
    if (phase?.key !== key) {
      phase = { key, sample_count: 0, first: metrics(sample), last: null, peak_pss_mib: 0 };
      phases.push(phase);
    }
    phase.sample_count++;
    phase.last = metrics(sample);
    phase.peak_pss_mib = Math.max(phase.peak_pss_mib, sample.native.pss_kb / 1024);
  }
  for (const phase of phases) {
    const seconds = phase.last.elapsed_s - phase.first.elapsed_s;
    phase.observed_ops_per_s = seconds > 0 ?
      (phase.last.operations - phase.first.operations) / seconds : null;
  }
  const baseline = phases.find(phase => phase.key === 'baseline/0').last;
  const final = metrics(samples.at(-1));
  const delta = Object.fromEntries(Object.keys(final).map(key => [key, final[key] - baseline[key]]));
  return {
    case: name, pid, started_utc: record.host_started_utc, finished_utc: record.host_finished_utc,
    sample_count: samples.length, baseline, final, delta,
    peak_pss_mib: Math.max(...samples.map(sample => sample.native.pss_kb / 1024)),
    post_dart_gc: record.post_dart_gc ? metrics(record.post_dart_gc) : null,
    gc_probe_error: record.gc_probe_error ?? null, phases,
  };
});
const output = join(directory, 'summary_memory.json');
writeFileSync(output, JSON.stringify({ results }, null, 2));
console.table(results.map(r => ({ case: r.case, pid: r.pid, ops: r.final.operations,
  baseline_pss: r.baseline.pss_mib.toFixed(2), peak_pss: r.peak_pss_mib.toFixed(2),
  final_pss: r.final.pss_mib.toFixed(2), delta_pss: r.delta.pss_mib.toFixed(2),
  delta_native: r.delta.native_allocated_mib.toFixed(2), delta_ark: r.delta.ark_used_mib.toFixed(2),
  delta_dart: r.delta.dart_used_mib.toFixed(2), dart_after_gc: r.post_dart_gc?.dart_used_mib.toFixed(2),
})));
console.log(output);
