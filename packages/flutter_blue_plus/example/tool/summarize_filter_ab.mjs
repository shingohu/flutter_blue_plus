import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { filterPlan } from './filter_ab_plan.mjs';

function stats(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const quantile = p => sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)];
  return { count: sorted.length, mean: sorted.reduce((a, b) => a + b, 0) / sorted.length,
    p50: quantile(.5), p95: quantile(.95), p99: quantile(.99), max: sorted.at(-1) };
}
const median = values => {
  const sorted = [...values].sort((a, b) => a - b), middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};

export function summarizeRuns(runs) {
  assert.equal(runs.length, 3, 'Need three independent runs');
  assert.equal(new Set(runs.map(run => run.pid)).size, 3, 'Reused process');
  assert.ok(runs.every(run => typeof run.run_token === 'string' && run.run_token.length > 0));
  assert.equal(new Set(runs.map(run => run.run_token)).size, 3, 'Reused run token');
  const plan = filterPlan(runs[0].suite);
  const { conditions, count } = plan;
  const key = (listeners, scenario, hz, targetPosition) => `${listeners}/${scenario}/${hz}/${targetPosition}`;
  const groups = new Map(conditions.map(([listeners, scenario, hz, target_position]) =>
    [key(listeners, scenario, hz, target_position),
      { listeners, scenario, hz, target_position, pairs: [], baseline: [], fused: [] }]));
  for (let index = 0; index < runs.length; index++) {
    const run = runs[index];
    assert.ok(!run.failure && run.finished_utc, 'Incomplete/failed run');
    assert.equal(run.suite ?? 'original', plan.suite, 'Mixed suites');
    if (plan.suite === 'low-rate') assert.equal(run.schema, 2);
    assert.equal(run.mode, 'profile'); assert.equal(run.pairs, plan.pairs); assert.equal(run.count, count);
    assert.equal(run.reverse, index === 1);
    assert.equal(run.results.length, plan.cases);
    let position = 0;
    for (let pair = 0; pair < 4; pair++) {
      const reverse = (pair % 2 === 1) !== run.reverse;
      for (const [listeners, scenario, hz, targetPosition] of reverse ? [...conditions].reverse() : conditions) {
        const rows = {};
        for (const variant of reverse ? ['fused', 'baseline'] : ['baseline', 'fused']) {
          const row = run.results[position++];
          assert.equal(row.run_token, run.run_token, 'Wrong run token');
          assert.equal(row.listeners, listeners); assert.equal(row.scenario, scenario);
          assert.equal(row.variant, variant); assert.equal(row.pair, pair);
          assert.equal(row.target_position ?? (plan.suite === 'original' ? 'last' : undefined), targetPosition);
          if (plan.suite === 'low-rate') assert.equal(row.target_index, targetPosition === 'first' ? 0 : listeners - 1);
          for (const field of ['count', 'received', 'observed', 'sent', 'replies']) assert.equal(row[field], count, field);
          for (const field of ['validation_errors', 'unexpected', 'native_errors']) assert.equal(row[field], 0, field);
          assert.equal(row.size, 244); assert.equal(row.hz, hz);
          for (const field of ['observer_to_filtered_us', 'native_rtt_us', 'native_interval_us']) {
            assert.equal(row[field].length, field === 'native_interval_us' ? count - 1 : count, field);
            assert.ok(row[field].every(value => Number.isFinite(value) && value >= 0), field);
          }
          assert.ok(row.native_interval_us.reduce((a, b) => a + b) > 0, 'Invalid elapsed interval');
          rows[variant] = { delivery: stats(row.observer_to_filtered_us), rtt: stats(row.native_rtt_us),
            interval_us: stats(row.native_interval_us),
            actual_hz: (count - 1) * 1e6 / row.native_interval_us.reduce((a, b) => a + b) };
          assert.ok(rows[variant].delivery.p95 > 0 && rows[variant].rtt.p95 > 0, 'Invalid ratio denominator');
          groups.get(key(listeners, scenario, hz, targetPosition))[variant].push(row);
        }
        groups.get(key(listeners, scenario, hz, targetPosition)).pairs.push({ run: index + 1, pid: run.pid, pair,
          order: reverse ? 'BA' : 'AB', ...rows,
          actual_hz_difference_percent: (rows.fused.actual_hz / rows.baseline.actual_hz - 1) * 100,
          both_within_5_percent_target: ['baseline', 'fused'].every(v => Math.abs(rows[v].actual_hz / hz - 1) <= .05),
          delivery_p95_reduction_percent: (1 - rows.fused.delivery.p95 / rows.baseline.delivery.p95) * 100,
          rtt_p95_reduction_percent: (1 - rows.fused.rtt.p95 / rows.baseline.rtt.p95) * 100 });
      }
    }
  }
  return { schema: 2, suite: plan.suite, processes: runs.map(run => run.pid),
    cases: plan.cases * runs.length, validated_events: plan.cases * runs.length * count,
    accounting: 'Raw samples pooled per condition/variant; paired ratios use each run/pair, not independent events.',
    conditions: [...groups.values()].map(group => {
      const pooled = {};
      for (const variant of ['baseline', 'fused']) {
        pooled[variant] = { delivery_us: stats(group[variant].flatMap(row => row.observer_to_filtered_us)),
          rtt_us: stats(group[variant].flatMap(row => row.native_rtt_us)),
          interval_us: stats(group[variant].flatMap(row => row.native_interval_us)),
          actual_hz_range: [Math.min(...group.pairs.map(pair => pair[variant].actual_hz)),
            Math.max(...group.pairs.map(pair => pair[variant].actual_hz))] };
      }
      return { listeners: group.listeners, scenario: group.scenario, hz: group.hz,
        target_position: group.target_position, ...pooled,
        rate_comparable_pairs: group.pairs.filter(pair => Math.abs(pair.actual_hz_difference_percent) <= 2).length,
        both_near_target_pairs: group.pairs.filter(pair => pair.both_within_5_percent_target).length,
        paired_delivery_p95_reduction_median_percent: median(group.pairs.map(pair => pair.delivery_p95_reduction_percent)),
        paired_rtt_p95_reduction_median_percent: median(group.pairs.map(pair => pair.rtt_p95_reduction_percent)),
        delivery_improved_pairs: group.pairs.filter(pair => pair.delivery_p95_reduction_percent > 0).length,
        rtt_improved_pairs: group.pairs.filter(pair => pair.rtt_p95_reduction_percent > 0).length,
        pairs: group.pairs };
    }),
    memory_endpoints: runs.map(run => ({ pid: run.pid, before: run.memory_before, after: run.memory_after,
      note: 'Mixed A/B process with retained timing samples; not a per-variant memory comparison.' })) };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [directory] = process.argv.slice(2);
  if (!directory) throw new Error('Usage: node summarize_filter_ab.mjs RESULT_DIRECTORY');
  const manifest = JSON.parse(readFileSync(join(directory, 'manifest.json')));
  assert.ok(manifest.finished_utc && manifest.runs.length === 3 && manifest.runs.every(run => !run.failure));
  const runs = [1, 2, 3].map(index => JSON.parse(readFileSync(join(directory, `run${index}.json`))));
  for (let index = 0; index < 3; index++) {
    assert.equal(runs[index].pid, manifest.runs[index].completion.pid);
    assert.equal(runs[index].run_token, manifest.runs[index].run_token);
    assert.equal(runs[index].suite ?? 'original', manifest.suite ?? 'original');
  }
  const result = summarizeRuns(runs);
  writeFileSync(join(directory, 'summary.json'), JSON.stringify(result, null, 2));
  console.table(result.conditions.map(group => ({ hz: group.hz, listeners: group.listeners,
    scenario: group.scenario, position: group.target_position,
    delivery_p95_before: group.baseline.delivery_us.p95, delivery_p95_after: group.fused.delivery_us.p95,
    paired_delivery_gain_percent: group.paired_delivery_p95_reduction_median_percent.toFixed(2),
    delivery_wins: group.delivery_improved_pairs, rtt_p95_before: group.baseline.rtt_us.p95,
    rtt_p95_after: group.fused.rtt_us.p95, rtt_wins: group.rtt_improved_pairs,
    matched_rate_pairs: group.rate_comparable_pairs, near_target_pairs: group.both_near_target_pairs })));
}
