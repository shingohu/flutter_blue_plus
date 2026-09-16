import assert from 'node:assert/strict';
import test from 'node:test';
import { summarizeRuns } from './summarize_filter_ab.mjs';

// Synthetic inputs validate the summarizer only; never used as device results.
function fixture(lowRate = false) {
  return [0, 1, 2].map(index => {
    const reverseRun = index === 1;
    const results = [];
    for (let pair = 0; pair < 4; pair++) {
      const reverse = (pair % 2 === 1) !== reverseRun;
      const conditions = lowRate ? [50, 100].flatMap(hz => [
        [1, 'late_miss', hz, 'first'], [64, 'early_miss', hz, 'first'],
        [64, 'early_miss', hz, 'last'], [64, 'late_miss', hz, 'first'], [64, 'late_miss', hz, 'last']])
        : [[1, 'late_miss', 200, 'last'], [16, 'late_miss', 200, 'last'],
          [64, 'late_miss', 200, 'last'], [64, 'early_miss', 200, 'last']];
      const count = lowRate ? 200 : 400;
      for (const [listeners, scenario, hz, position] of reverse ? conditions.reverse() : conditions) {
        for (const variant of reverse ? ['fused', 'baseline'] : ['baseline', 'fused']) {
          results.push({ run_token: `fixture-${index}`, listeners, scenario, pair, variant, size: 244, hz,
            ...(lowRate ? { target_position: position, target_index: position === 'first' ? 0 : listeners - 1 } : {}),
            count, received: count, observed: count, sent: count, replies: count,
            validation_errors: 0, unexpected: 0, native_errors: 0,
            observer_to_filtered_us: Array(count).fill(variant === 'fused' ? 80 : 100),
            native_rtt_us: Array(count).fill(1000), native_interval_us: Array(count - 1).fill(1e6 / hz) });
        }
      }
    }
    return { ...(lowRate ? { suite: 'low-rate', schema: 2 } : {}),
      run_token: `fixture-${index}`, pid: index + 1, mode: 'profile', pairs: 4, count: lowRate ? 200 : 400, reverse: reverseRun,
      finished_utc: '2026-09-15T00:00:00Z', results };
  });
}

test('pools raw samples and preserves paired reductions', () => {
  const summary = summarizeRuns(fixture());
  assert.equal(summary.validated_events, 38400);
  for (const condition of summary.conditions) {
    assert.equal(condition.baseline.delivery_us.count, 4800);
    assert.equal(condition.fused.delivery_us.p95, 80);
    assert.ok(Math.abs(condition.paired_delivery_p95_reduction_median_percent - 20) < 1e-8);
    assert.equal(condition.delivery_improved_pairs, 12);
    assert.equal(condition.rtt_improved_pairs, 0);
    assert.deepEqual(condition.baseline.actual_hz_range, [200, 200]);
  }
});

test('keeps low-rate frequencies and registration positions separate', () => {
  const summary = summarizeRuns(fixture(true));
  assert.equal(summary.cases, 240);
  assert.equal(summary.validated_events, 48000);
  assert.equal(summary.conditions.length, 10);
  for (const condition of summary.conditions) {
    assert.equal(condition.baseline.delivery_us.count, 2400);
    assert.equal(condition.rate_comparable_pairs, 12);
    assert.equal(condition.both_near_target_pairs, 12);
  }
  for (const mutation of [row => { row.hz = 200; }, row => { row.target_position = 'last'; },
    row => { row.target_index = 1; }, row => { delete row.target_position; }]) {
    const runs = fixture(true); mutation(runs[0].results[0]);
    assert.throws(() => summarizeRuns(runs));
  }
  const mixed = fixture(true); delete mixed[1].suite;
  assert.throws(() => summarizeRuns(mixed), /Mixed suites/);
});

test('reports rate mismatch without dropping slow or adverse pairs', () => {
  const runs = fixture(true);
  runs[0].results[1].native_interval_us.fill(25000);
  runs[0].results[1].observer_to_filtered_us.fill(150);
  const condition = summarizeRuns(runs).conditions[0];
  assert.equal(condition.pairs.length, 12);
  assert.equal(condition.rate_comparable_pairs, 11);
  assert.equal(condition.both_near_target_pairs, 11);
  assert.equal(condition.delivery_improved_pairs, 11);
  assert.equal(condition.pairs[0].delivery_p95_reduction_percent, -50);
  assert.ok(Math.abs(condition.pairs[0].actual_hz_difference_percent + 20) < 1e-8);
});

test('rejects failed runs and reused processes', () => {
  const failed = fixture(); failed[0].failure = 'timeout';
  assert.throws(() => summarizeRuns(failed));
  const reused = fixture(); reused[1].pid = reused[0].pid;
  assert.throws(() => summarizeRuns(reused), /Reused process/);
});

test('rejects unmatched order or workload', () => {
  const order = fixture(); order[0].results.reverse();
  assert.throws(() => summarizeRuns(order));
  const workload = fixture(); workload[0].results[0].count = 399;
  assert.throws(() => summarizeRuns(workload));
  const stale = fixture(); stale[0].results[0].run_token = 'previous-run';
  assert.throws(() => summarizeRuns(stale), /Wrong run token/);
});

test('rejects bad event counters and invalid samples', () => {
  for (const mutation of [row => { row.unexpected = 1; }, row => { row.native_interval_us.pop(); },
    row => { row.native_rtt_us[0] = NaN; }, row => { row.observer_to_filtered_us[0] = -1; }]) {
    const runs = fixture(); mutation(runs[0].results[0]);
    assert.throws(() => summarizeRuns(runs));
  }
});
