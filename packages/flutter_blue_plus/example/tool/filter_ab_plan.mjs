import assert from 'node:assert/strict';

export function filterPlan(suite = 'original') {
  assert.ok(['original', 'low-rate'].includes(suite), 'Unknown filter suite');
  const conditions = suite === 'low-rate'
    ? [50, 100].flatMap(hz => [
      [1, 'late_miss', hz, 'first'], [64, 'early_miss', hz, 'first'],
      [64, 'early_miss', hz, 'last'], [64, 'late_miss', hz, 'first'],
      [64, 'late_miss', hz, 'last']])
    : [[1, 'late_miss', 200, 'last'], [16, 'late_miss', 200, 'last'],
      [64, 'late_miss', 200, 'last'], [64, 'early_miss', 200, 'last']];
  return { suite, schema: suite === 'low-rate' ? 2 : 1, pairs: 4,
    count: suite === 'low-rate' ? 200 : 400, cases: conditions.length * 8, conditions };
}
