import fs from 'node:fs';
import { request } from '../web/core.js';
const invoke = query => {
  const result = JSON.parse(request(JSON.stringify(query)));
  if (!result.ok || result.editable === false) throw Error(result.error || result.warning);
  return result;
};
const rss = () => Math.max(process.memoryUsage().rss, process.resourceUsage().maxRSS * 1024);
const measure = fn => { const start = performance.now(); const value = fn(); return { value, ms: performance.now() - start }; };
const cases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const results = [];
for (const item of cases) {
  global.gc?.();
  const loaded = measure(() => invoke({ action: 'open', data: fs.readFileSync(item.file).toString('base64') }));
  let state = loaded.value;
  let layer = state.tree[0];
  while (layer.kind === "group") layer = layer.children[0];
  const commits = [];
  for (let x = 1; x <= 3; x++) {
    const result = measure(() => invoke({ action: 'edit', path: layer.path, name: layer.name, x, y: 0, opacity: layer.opacity, visible: true, op: layer.op }));
    state = result.value; commits.push(result.ms);
  }
  const warm = measure(() => invoke({ action: 'warm-preview' }));
  const previews = [];
  for (let x = 4; x <= 10; x++) previews.push(measure(() => invoke({ action: 'preview', path: layer.path, x, y: 0 })).ms);
  const exported = measure(() => invoke({ action: 'export' }));
  const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
  results.push({ name: item.name, width: state.width, height: state.height, layers: item.layers, import_ms: loaded.ms, commit_median_ms: median(commits), preview_cache_ms: warm.ms, preview_median_ms: median(previews), export_ms: exported.ms, peak_process_rss_mib: rss() / 1048576, archive_bytes: Buffer.from(exported.value.data, 'base64').length });
}
fs.writeFileSync(process.argv[3], JSON.stringify({ node: process.version, platform: process.platform, generated_at: new Date().toISOString(), results }, null, 2));
console.log('Benchmark saved:', process.argv[3]);
