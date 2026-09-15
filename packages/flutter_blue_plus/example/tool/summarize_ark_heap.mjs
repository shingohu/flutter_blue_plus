import { readFileSync, writeFileSync } from 'node:fs';

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: node summarize_ark_heap.mjs HEAPSNAPSHOT OUTPUT_JSON');
const heap = JSON.parse(readFileSync(input, 'utf8'));
const meta = heap.snapshot.meta;
const nf = meta.node_fields, ef = meta.edge_fields;
const ni = Object.fromEntries(nf.map((field, index) => [field, index]));
const ei = Object.fromEntries(ef.map((field, index) => [field, index]));
for (const field of ['name', 'id', 'edge_count', 'self_size', 'native_size']) {
  if (ni[field] === undefined) throw new Error(`Missing node field ${field}`);
}
if (heap.nodes.length !== heap.snapshot.node_count * nf.length || heap.edges.length !== heap.snapshot.edge_count * ef.length) {
  throw new Error('Heap array size mismatch');
}
const starts = new Uint32Array(heap.snapshot.node_count);
const node = offset => ({ offset, id: heap.nodes[offset + ni.id], name: heap.strings[heap.nodes[offset + ni.name]],
  self_bytes: heap.nodes[offset + ni.self_size], native_bytes: heap.nodes[offset + ni.native_size] });
let edge = 0;
const localRoots = [], allBuffers = [];
for (let offset = 0; offset < heap.nodes.length; offset += nf.length) {
  starts[offset / nf.length] = edge;
  edge += heap.nodes[offset + ni.edge_count] * ef.length;
  const item = node(offset);
  if (item.name.startsWith('LocalHandleRoot[')) localRoots.push(item);
  if (item.name === 'ArrayBuffer') allBuffers.push(item);
}
if (edge !== heap.edges.length || localRoots.length !== 1) throw new Error('Invalid edge layout or local root');
const children = offset => {
  const result = [], start = starts[offset / nf.length];
  const end = start + heap.nodes[offset + ni.edge_count] * ef.length;
  for (let index = start; index < end; index += ef.length) {
    const type = meta.edge_types[ei.type][heap.edges[index + ei.type]];
    const key = heap.edges[index + ei.name_or_index];
    const target = heap.edges[index + ei.to_node];
    if (target % nf.length || target < 0 || target >= heap.nodes.length) throw new Error('Invalid edge target');
    result.push({ edge_type: type, edge_name: type === 'element' || type === 'hidden' ? key : heap.strings[key], node: node(target) });
  }
  return result;
};
const root = localRoots[0], refs = children(root.offset);
const buffers = [...new Map(refs.filter(ref => ref.node.name === 'ArrayBuffer').map(ref => [ref.node.offset, ref])).values()];
const groups = new Map();
for (const ref of buffers) {
  const pointers = children(ref.node.offset).filter(child => child.node.name === 'JSNativePointer');
  const size = pointers.reduce((sum, child) => sum + child.node.native_bytes, 0);
  if (!groups.has(size)) groups.set(size, { native_bytes_per_buffer: size, buffer_count: 0, examples: [] });
  const group = groups.get(size);
  group.buffer_count++;
  if (group.examples.length < 2) group.examples.push({ root, arraybuffer_edge: ref, native_pointer_edges: pointers });
}
const result = { source: input, node_count: heap.snapshot.node_count, edge_count: heap.snapshot.edge_count,
  local_handle_root: root.name, direct_local_handle_edges: refs.length,
  all_arraybuffer_nodes: allBuffers.length, unique_local_root_arraybuffers: buffers.length,
  local_root_buffer_groups: [...groups.values()].sort((a, b) => b.buffer_count - a.buffer_count) };
writeFileSync(output, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
