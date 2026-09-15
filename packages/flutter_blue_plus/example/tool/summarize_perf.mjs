import { readFileSync, writeFileSync } from 'node:fs';

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: node summarize_perf.mjs INPUT.json OUTPUT.json');
const data = JSON.parse(readFileSync(input, 'utf8'));
if (data.failure) throw new Error(data.failure);
const groups = new Map();
let calls = 0;
let events = 0;
function stats(values) {
  if (!values.length) return null;
  values.sort((a, b) => a - b);
  const p = q => values[Math.max(0, Math.ceil(q * values.length) - 1)];
  return { count: values.length, mean: values.reduce((a, b) => a + b, 0) / values.length,
    p50: p(.5), p95: p(.95), p99: p(.99), max: values.at(-1) };
}
for (const row of data.results) {
  for (const field of ['errors', 'missing', 'validation_errors', 'unexpected', 'out_of_order']) {
    if (row[field]) throw new Error(`${field}=${row[field]} in ${JSON.stringify(row)}`);
  }
  if (row.kind === 'echo') {
    if (row.samples_us.length !== row.payload_verified) throw new Error('Echo count mismatch');
    calls += row.payload_verified;
  } else {
    if (row.expected !== row.received || row.expected !== row.replies || row.expected !== row.sent ||
        row.expected !== row.native_rtt_us.length) throw new Error('Event count mismatch');
    events += row.received;
  }
  const key = [row.kind, row.representation ?? '', row.size, row.concurrency ?? '',
    row.hz ?? '', row.listeners ?? '', row.log_level ?? ''].join('/');
  const rows = groups.get(key) ?? [];
  rows.push(row);
  groups.set(key, rows);
}
const summaries = [];
for (const [key, rows] of groups) {
  if (new Set(rows.map(r => r.repetition)).size !== data.repetitions || rows.length !== data.repetitions) {
    throw new Error(`Incomplete repetitions: ${key}`);
  }
  const first = rows[0];
  summaries.push({
    key, kind: first.kind, representation: first.representation, size: first.size,
    concurrency: first.concurrency, hz: first.hz, listeners: first.listeners, log_level: first.log_level,
    rtt_us: stats(rows.flatMap(r => r.samples_us ?? r.native_rtt_us)),
    observer_to_filtered_us: stats(rows.flatMap(r => r.observer_to_filtered_us ?? [])),
    actual_send_hz: rows.map(r => r.actual_send_hz).filter(v => v !== undefined),
    operations_per_second: rows.map(r => r.operations_per_second).filter(v => v !== undefined),
    per_round_rtt_us: rows.map(r => r.rtt_us ?? r.native_handler_rtt_us),
  });
}
const memories = data.results.flatMap(r => [r.memory_before, r.memory_after]);
const result = {
  started_utc: data.started_utc, finished_utc: data.finished_utc, mode: data.mode,
  total_cases: data.results.length, groups: groups.size,
  measured_echo_calls: calls, measured_events: events, validation_errors: 0,
  memory_kb: {
    first: memories[0], last: memories.at(-1),
    peak_sampled_pss: Math.max(...memories.map(r => r.pss_kb)),
    peak_sampled_rss: Math.max(...memories.map(r => r.rss_kb)),
  },
  summaries,
};
writeFileSync(output, JSON.stringify(result, null, 2));
console.log(JSON.stringify({ ...result, summaries: undefined }, null, 2));
for (const row of summaries) {
  console.log(`${row.key}: RTT P50/P95/P99=${row.rtt_us.p50.toFixed(1)}/${row.rtt_us.p95.toFixed(1)}/${row.rtt_us.p99.toFixed(1)} us` +
    (row.observer_to_filtered_us ? `; observer P50/P95=${row.observer_to_filtered_us.p50}/${row.observer_to_filtered_us.p95} us` : '') +
    (row.actual_send_hz.length ? `; Hz=${row.actual_send_hz.map(n => n.toFixed(1)).join(',')}` : ''));
}
