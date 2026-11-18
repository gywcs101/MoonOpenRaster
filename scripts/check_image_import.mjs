import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { request } from '../web/core.js';

const directory = '_build/image-import';
const command = q => JSON.parse(request(JSON.stringify(q)));
const run = q => {
  const result = command(q);
  assert.equal(result.ok, true, result.error);
  return result;
};
const file = (name, source = path.join(directory, name)) => fs.readFileSync(source).toString('base64');
const formats = [
  ['layer.png', 16, 12, 8],
  ['oriented.jpg', 12, 16, 8],
  ['layer.webp', 16, 12, 8],
  ['lossy.webp', 16, 12, 8],
  ['animated.gif', 16, 12, 8],
  ['layer.bmp', 16, 12, 8],
  ['multi.tiff', 16, 12, 16],
  ['layer.ico', 16, 16, 8],
];
let state = run({ action: 'open', data: file('', 'fixtures/gradient16.ora') });
const original = run({ action: 'export' }).data;
const originalTop = state.tree[0].children[0];
for (const [name, width, height, bitDepth] of formats) {
  const data = file(name);
  state = run({ action: 'insert', parent: [], index: 0, name, data });
  assert.deepEqual([state.tree[0].width, state.tree[0].height, state.tree[0].bitDepth], [width, height, bitDepth], name);
  const png = run({ action: 'layer-png', path: [0] }).data;
  if (['layer.webp', 'multi.tiff', 'animated.gif'].includes(name)) {
    fs.writeFileSync(path.join(directory, name + '.png'), Buffer.from(png, 'base64'));
  }
  state = run({ action: 'undo' });
  assert.equal(run({ action: 'export' }).data, original);
  state = run({ action: 'replace', path: [0, 0], data });
  assert.equal(state.tree[0].children[0].name, originalTop.name);
  assert.deepEqual([state.tree[0].children[0].width, state.tree[0].children[0].bitDepth], [width, bitDepth]);
  const archive = run({ action: 'export' }).data;
  state = run({ action: 'open', data: archive });
  assert.equal(state.editable, true);
  assert.equal(run({ action: 'layer-png', path: [0, 0] }).data, png);
  state = run({ action: 'open', data: file('', 'fixtures/gradient16.ora') });
}
for (const data of [file('animated.webp'), file('progressive-edge.jpg'), Buffer.from('unknown image').toString('base64')]) {
  assert.equal(command({ action: 'insert', parent: [], index: 0, name: 'rejected', data }).ok, false);
  assert.equal(run({ action: 'export' }).data, original);
}
console.log('PASS: image insert, replace, undo, ORA reopen, EXIF rotation and atomic format rejection');
