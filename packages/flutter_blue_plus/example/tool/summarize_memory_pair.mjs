import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

function metrics(sample) {
  const n = sample.native;
  const result = {
    elapsed_s: sample.elapsed_us / 1e6, operations: sample.operations,
    pss_mib: n.pss_kb / 1024,
    native_allocated_mib: n.native_allocated_bytes / 1048576,
    native_free_mib: n.native_free_bytes / 1048576,
    ark_used_mib: n.ark_heap_used_kb / 1024,
    ark_capacity_mib: n.ark_heap_capacity_kb / 1024,
  };
  if (Object.values(result).some(value => !Number.isFinite(value))) throw new Error('Missing or invalid metrics');
  return result;
}

export function summarizePair(records) {
  if (records.length !== 2) throw new Error('Exactly two runs required');
  if (records.map(r => r.config.sampling).sort().join(',') !== 'endpoints,periodic') {
    throw new Error('One run per sampling mode required');
  }
  const reference = records[0];
  const pids = new Set();
  const runs = records.map(record => {
    const { cycles, operations_per_cycle: count } = record.config;
    if (!Number.isInteger(cycles) || cycles < 1 || !Number.isInteger(count) || count < 1 ||
        record.case !== reference.case || cycles !== reference.config.cycles ||
        count !== reference.config.operations_per_cycle || !record.config.checkpoints) {
      throw new Error('Unmatched workload configurations');
    }
    const last = record.samples.at(-1);
    if (record.failure || !last?.finished || last.errors || last.failure || last.operations !== cycles * count) {
      throw new Error('Incomplete or invalid workload');
    }
    if (record.config.sampling === 'endpoints' && record.samples.length !== 1) {
      throw new Error('Unexpected periodic samples in endpoint mode');
    }
    if (record.samples.some(sample => sample.pid !== last.pid || sample.errors || sample.failure)) {
      throw new Error('Invalid VM sample');
    }
    if (pids.has(last.pid)) throw new Error('Reused process');
    pids.add(last.pid);
    const expected = [{ checkpoint: 'baseline', cycle: 0, operations: 0 }];
    for (let cycle = 1; cycle <= cycles; cycle++) {
      expected.push({ checkpoint: 'load_end', cycle, operations: cycle * count });
      expected.push({ checkpoint: 'recovery_end', cycle, operations: cycle * count });
    }
    expected.push({ checkpoint: 'complete', cycle: cycles, operations: cycles * count });
    if (record.checkpoints.length !== expected.length) throw new Error('Missing checkpoints');
    const checkpoints = record.checkpoints.map((sample, index) => {
      const e = expected[index];
      if (sample.checkpoint !== e.checkpoint || sample.cycle !== e.cycle || sample.operations !== e.operations ||
          sample.pid !== last.pid || sample.case !== record.case || sample.errors || sample.failure ||
          (index && sample.elapsed_us <= record.checkpoints[index - 1].elapsed_us)) {
        throw new Error(`Invalid checkpoint ${index}`);
      }
      return { checkpoint: sample.checkpoint, cycle: sample.cycle, ...metrics(sample) };
    });
    const baseline = checkpoints[0], final = checkpoints.at(-1);
    return {
      sampling: record.config.sampling, pid: last.pid, case: record.case, cycles, operations_per_cycle: count,
      host_started_utc: record.host_started_utc, host_finished_utc: record.host_finished_utc,
      vm_samples_including_completion: record.samples.length, baseline, final,
      delta: Object.fromEntries(Object.keys(metrics(record.checkpoints[0])).map(key => [key, final[key] - baseline[key]])),
      dart_final_mib: last.dart.heapUsage / 1048576,
      dart_post_gc_mib: record.post_dart_gc ? record.post_dart_gc.dart.heapUsage / 1048576 : null,
      post_dart_gc: record.post_dart_gc ? metrics(record.post_dart_gc) : null, checkpoints,
    };
  });
  return { runs };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [first, second, output] = process.argv.slice(2);
  if (!first || !second || !output) throw new Error('Usage: node summarize_memory_pair.mjs ENDPOINTS_JSON PERIODIC_JSON OUTPUT_JSON');
  const summary = summarizePair([first, second].map(path => JSON.parse(readFileSync(path, 'utf8'))));
  writeFileSync(output, JSON.stringify(summary, null, 2));
  console.table(summary.runs.flatMap(run => run.checkpoints.filter(c => c.checkpoint !== 'load_end').map(c => ({
    mode: run.sampling, checkpoint: c.checkpoint, cycle: c.cycle, ops: c.operations,
    pss_mib: c.pss_mib.toFixed(2), native_allocated_mib: c.native_allocated_mib.toFixed(2),
    ark_mib: c.ark_used_mib.toFixed(2),
  }))));
  console.log(output);
}
