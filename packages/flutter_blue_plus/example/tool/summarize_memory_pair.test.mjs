import assert from 'node:assert/strict';
import test from 'node:test';
import { summarizePair } from './summarize_memory_pair.mjs';

// Synthetic fixtures test validation only; they are not benchmark results.
function run(sampling, pid) {
  const checkpoints = [];
  const add = (checkpoint, cycle, operations) => checkpoints.push({
    checkpoint, cycle, operations, case: 'echo_large_bytes', pid, errors: 0, failure: null,
    elapsed_us: (checkpoints.length + 1) * 1000000,
    native: { pss_kb: 1024 * (80 + checkpoints.length), native_allocated_bytes: 1048576 * 60,
      native_free_bytes: 1048576 * 4, ark_heap_used_kb: 4096, ark_heap_capacity_kb: 8192 },
  });
  add('baseline', 0, 0);
  for (let cycle = 1; cycle <= 2; cycle++) {
    add('load_end', cycle, cycle * 2);
    add('recovery_end', cycle, cycle * 2);
  }
  add('complete', 2, 4);
  return {
    case: 'echo_large_bytes', config: { sampling, cycles: 2, operations_per_cycle: 2, checkpoints: true },
    checkpoints, samples: [{ ...checkpoints.at(-1), finished: true, dart: { heapUsage: 6291456 } }],
  };
}

const pair = () => [run('endpoints', 1), run('periodic', 2)];
test('converts units and uses matched endpoints', () => {
  const summary = summarizePair(pair());
  assert.equal(summary.runs[0].baseline.pss_mib, 80);
  assert.equal(summary.runs[0].delta.pss_mib, 5);
  assert.equal(summary.runs[0].final.operations, 4);
  assert.equal(summary.runs[0].dart_final_mib, 6);
});
test('rejects mismatched workloads', () => {
  const records = pair(); records[1].config.operations_per_cycle = 3;
  assert.throws(() => summarizePair(records), /Unmatched/);
});
test('rejects reused processes', () => {
  assert.throws(() => summarizePair([run('endpoints', 1), run('periodic', 1)]), /Reused/);
});
test('rejects missing or out-of-order checkpoints', () => {
  const missing = pair(); missing[0].checkpoints.pop();
  assert.throws(() => summarizePair(missing), /Missing/);
  const wrong = pair(); wrong[0].checkpoints[2].operations++;
  assert.throws(() => summarizePair(wrong), /Invalid checkpoint/);
});
test('rejects incomplete runs and validation errors', () => {
  const incomplete = pair(); incomplete[1].samples[0].finished = false;
  assert.throws(() => summarizePair(incomplete), /Incomplete/);
  const error = pair(); error[0].checkpoints[1].errors = 1;
  assert.throws(() => summarizePair(error), /Invalid checkpoint/);
});
test('rejects periodic samples in endpoint-only mode', () => {
  const records = pair(); records[0].samples.push(records[0].samples[0]);
  assert.throws(() => summarizePair(records), /Unexpected periodic/);
});
