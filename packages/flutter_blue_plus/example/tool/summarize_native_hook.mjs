import { DatabaseSync } from 'node:sqlite';
import { writeFileSync } from 'node:fs';

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: node summarize_native_hook.mjs TRACE_DB OUTPUT_JSON');
const db = new DatabaseSync(input, { readOnly: true });
const latestSql = `WITH ranked AS (
  SELECT *, row_number() OVER (
    PARTITION BY ipid, callchain_id, type, sub_type_id ORDER BY ts DESC, id DESC
  ) AS rank FROM native_hook_statistic
) SELECT * FROM ranked WHERE rank = 1`;
const latest = db.prepare(latestSql).all();
if (!latest.length) throw new Error('No native allocation statistics');
const dictionary = new Map(db.prepare('SELECT id,data FROM data_dict').all().map(row => [row.id, row.data]));
const frames = db.prepare(`SELECT depth, symbol_id, file_id, printf('0x%x',ip) AS ip, vaddr
  FROM native_hook_frame WHERE callchain_id=? ORDER BY depth`);
const byType = new Map();
const stacks = latest.map(row => {
  const summary = {
    callchain_id: row.callchain_id, ipid: row.ipid, type: row.type, sub_type_id: row.sub_type_id,
    last_update_ts: row.ts, allocated_bytes: row.apply_size, released_bytes: row.release_size,
    outstanding_bytes: row.apply_size - row.release_size,
    outstanding_count: row.apply_count - row.release_count,
    last_library: dictionary.get(row.last_lib_id), last_symbol: dictionary.get(row.last_symbol_id),
  };
  const key = `${row.ipid}/${row.type}/${row.sub_type_id}`;
  if (!byType.has(key)) byType.set(key, { ipid: row.ipid, type: row.type, sub_type_id: row.sub_type_id,
    allocated_bytes: 0, released_bytes: 0, outstanding_bytes: 0, outstanding_count: 0 });
  const totals = byType.get(key);
  for (const field of ['allocated_bytes', 'released_bytes', 'outstanding_bytes', 'outstanding_count']) totals[field] += summary[field];
  return summary;
}).sort((a, b) => b.outstanding_bytes - a.outstanding_bytes);
const top = stacks.slice(0, 40).map(stack => ({ ...stack, frames: frames.all(stack.callchain_id).map(frame => ({
  depth: frame.depth, ip: frame.ip, vaddr: frame.vaddr,
  symbol: dictionary.get(frame.symbol_id), library: dictionary.get(frame.file_id),
})) }));
const result = {
  source: input,
  accounting: 'Latest cumulative record per process/callchain/type/subtype; no summing across time windows.',
  processes: db.prepare('SELECT * FROM process').all(),
  trace_range: db.prepare('SELECT * FROM trace_range').all(),
  parser_stats: db.prepare('SELECT * FROM stat WHERE count > 0').all(),
  statistics_rows: db.prepare('SELECT count(*) AS count FROM native_hook_statistic').get().count,
  frame_rows: db.prepare('SELECT count(*) AS count FROM native_hook_frame').get().count,
  totals_by_type: [...byType.values()],
  negative_stacks: stacks.filter(stack => stack.outstanding_bytes < 0 || stack.outstanding_count < 0),
  top_outstanding: top,
  stacks,
};
writeFileSync(output, JSON.stringify(result, null, 2));
console.log(JSON.stringify({ processes: result.processes, totals: result.totals_by_type, parser_stats: result.parser_stats }, null, 2));
console.table(top.slice(0, 15).map(stack => ({ chain: stack.callchain_id, type: stack.type,
  outstanding_mib: (stack.outstanding_bytes / 1048576).toFixed(3), count: stack.outstanding_count,
  symbol: stack.last_symbol,
})));
db.close();
