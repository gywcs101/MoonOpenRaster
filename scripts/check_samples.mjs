import assert from 'node:assert/strict';
import fs from 'node:fs';
import { request } from '../web/core.js';
import { checkTask } from '../web/samples.js';
const catalog = JSON.parse(fs.readFileSync('web/assets/sample-catalog.json', 'utf8'));
const run = query => { const result = JSON.parse(request(JSON.stringify(query))); assert.equal(result.ok, true, result.error); assert.notEqual(result.editable, false, result.warning); return result; };
const flatten = nodes => nodes.flatMap(n => [n, ...flatten(n.children)]);
assert.equal(catalog.samples.length, 4);
assert.equal(new Set(catalog.samples.map(s => s.id)).size, 4);
for (const sample of catalog.samples) {
  for (const file of [sample.file, sample.cover, sample.practice.file, sample.practice.start, sample.practice.goal, sample.practice.goalFile]) assert.ok(fs.existsSync('web/' + file), file);
  let state = run({ action: 'open', data: fs.readFileSync('web/' + sample.file).toString('base64') });
  assert.equal(flatten(state.tree).filter(n => n.kind === 'layer').length, sample.layerCount);
  assert.equal(state.width, sample.width); assert.equal(state.height, sample.height);
  state = run({ action: 'open', data: fs.readFileSync('web/' + sample.practice.file).toString('base64') });
  const originalNames = flatten(state.tree).map(n => n.name).sort();
  assert.equal(state.png, fs.readFileSync('web/' + sample.practice.start).toString('base64'));
  const steps = sample.practice.steps.filter(s => s.type !== 'export');
  assert.equal(steps.length, 3);
  for (const step of steps) assert.equal(checkTask(step, flatten(state.tree)), false, sample.id + ': practice must start with unfinished tasks');
  const first = steps[0].checks[0];
  for (const step of steps) {
    for (const check of step.checks) {
      const target = flatten(state.tree).find(n => n.name === check.name);
      assert.ok(target, sample.id + ': ' + check.name);
      if (check.type === 'image') state = run({ action: 'replace', path: target.path, data: fs.readFileSync('web/' + check.asset).toString('base64') });
      else state = run({ action: 'edit', path: target.path, name: target.name, x: target.x, y: target.y, opacity: target.opacity, visible: target.visible, op: target.op, ...check.expected });
    }
    assert.equal(checkTask(step, flatten(state.tree)), true);
  }
  assert.equal(state.png, fs.readFileSync('web/' + sample.practice.goal).toString('base64'), sample.id + ': actual edit pipeline must produce the reference image');
  assert.deepEqual(flatten(state.tree).map(n => n.name).sort(), originalNames);
  const saved = run({ action: 'export' }).data;
  assert.equal(run({ action: 'open', data: saved }).png, state.png);
  // Successful load resets bridge history; failure must not replace the completed document.
  assert.equal(JSON.parse(request('{"action":"open","data":"broken"}')).ok, false);
  assert.equal(run({ action: 'export' }).data, saved);
  assert.equal(checkTask(steps[0], flatten(state.tree).filter(n => n.name !== first.name)), false);
  console.log(`PASS: ${sample.title}; ${sample.layerCount} source layers, real task replay -> exact reference PNG -> ORA reopen`);
}
assert.equal(checkTask({ checks: [{ name: '雨', type: 'properties', expected: { opacity: .28 }, ranges: { opacity: [.2, .35] } }] }, [{ name: '雨', opacity: .2 }]), true);
assert.equal(checkTask({ checks: [{ name: '雨', type: 'properties', expected: { opacity: .28 }, ranges: { opacity: [.2, .35] } }] }, [{ name: '雨', opacity: .36 }]), false);
