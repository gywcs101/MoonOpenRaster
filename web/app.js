import { SampleStudio } from './samples.js?v=rgba16-20261118-1';
const $ = id => document.getElementById(id);
const modes = {
  'src-over': '正常', multiply: '正片叠底', screen: '滤色', overlay: '叠加',
  darken: '变暗', lighten: '变亮', 'color-dodge': '颜色减淡', 'color-burn': '颜色加深',
  'hard-light': '强光', 'soft-light': '柔光', difference: '差值', color: '颜色',
  luminosity: '明度', hue: '色相', saturation: '饱和度', plus: '相加',
  'dst-in': '保留底图重合部分', 'dst-out': '用上层擦除底图',
  'src-atop': '将上层限制在底图内', 'dst-atop': '将底图限制在上层内'
};
const worker = new Worker('./worker.js?v=rgba16-20261118-1', { type: 'module' });
const pending = new Map();
let requestId = 0;
worker.onmessage = ({ data: { id, result } }) => {
  const entry = pending.get(id);
  if (!entry) return;
  pending.delete(id);
  if (result.ok) entry.resolve(result); else entry.reject(Error(result.error));
};
worker.onerror = () => {
  for (const entry of pending.values()) entry.reject(Error('图像处理器载入失败，请重新启动服务并刷新页面。'));
  pending.clear();
  status('图像处理器载入失败，请重新启动服务并刷新页面。');
  $('loading').hidden = true;
};
function invoke(query) {
  return new Promise((resolve, reject) => {
    const id = ++requestId;
    pending.set(id, { resolve, reject });
    worker.postMessage({ id, query });
  });
}
let state, selected, original, savedRevision;
let busy = false;
let sampleStudio;
let drag = null, previewRunning = false, previewFrame = 0;
let gestureId = 0;
let scale = 1, fitMode = true, panX = 0, panY = 0, pan = null, space = false;
let fileMode = 'insert';
const collapsed = new Set();
const locks = new Set();
const samePath = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const key = path => JSON.stringify(path);
const dirty = () => state && state.revision !== savedRevision;
function status(message = '') {
  let text = message || state?.warning || '';
  for (const [source, target] of Object.entries({
    'Invalid document: ': '文档无法处理：', 'Unsupported feature: ': '暂不支持：',
    'Non-sRGB PNG gamma requires color management': '此 PNG 使用未支持的色调曲线，已显示原始预览。',
    'Non-sRGB PNG chromaticities require color management': '此 PNG 的色度与 sRGB 不同，已显示原始预览。',
    'SVG layer cannot be recomposited: ': '无法重新合成 SVG 图层：',
    'ICC-profiled PNG requires color management': '此文档包含 ICC 色彩配置，已显示原始预览。可保存原文件。',
    'Unknown composite operation: ': '暂不支持的混合方式：', 'Unknown layer element: ': '暂不支持的图层类型：',
    'Expected an integer coordinate or layer index': '位置和图层编号必须是范围内的整数。',
    'Rendering buffer budget exceeded': '合成所需内存超出限制。',
    'Decoded layer pixels exceed 128 MiB budget': '图层像素数据超过 128 MiB 限制。',
    'Cannot move a group into itself': '不能把图层组移入它自己或它的子组。',
    'svg:plus uses W3C compositing; Krita Addition may display different pixels.': '相加模式采用 W3C 合成规则；在 Krita 中打开时，部分像素可能有差异。',
    'No history available': '没有可撤销或重做的操作。'
  })) text = text.replace(source, target);
  $('status').textContent = text;
}
async function guard(action) {
  if (busy || drag) return;
  busy = true;
  document.body.classList.add('is-busy');
  updateActions();
  try { await action(); status(); } catch (error) { status(error.message); }
  finally { busy = false; document.body.classList.remove('is-busy'); updateActions(); }
}
function findNodes() {
  const all = [];
  function walk(nodes) { for (const node of nodes) { all.push(node); walk(node.children); } }
  walk(state?.tree || []);
  return all;
}
function getSiblings(path) {
  let nodes = state.tree;
  for (const index of path.slice(0, -1)) nodes = nodes[index].children;
  return nodes;
}
function locked(node) {
  return node && node.path.some((_, index) => locks.has(key(node.path.slice(0, index + 1))));
}
function updateActions() {
  const editable = !!state && state.editable !== false && !busy;
  const usable = editable && !!selected && !locked(selected);
  $('undo').disabled = !editable || !state.canUndo;
  $('redo').disabled = !editable || !state.canRedo;
  for (const id of ['open', 'sample']) $(id).disabled = busy;
  $('save').disabled = !state || busy;
  $('png').disabled = !state?.png || busy;
  for (const id of ['add-layer', 'add-group']) $(id).disabled = !editable || locked(selected);
  $('all-layers').disabled = !editable;
  for (const id of ['remove', 'duplicate', 'move-layer', 'move-target']) $(id).disabled = !usable;
  $('replace-layer').disabled = !usable || selected.kind !== 'layer';
  $('layer-png').disabled = !state || busy || !selected || selected.kind !== 'layer' || state.editable === false;
  for (const control of $('properties').elements) control.disabled = !usable;
  $('x').disabled = $('y').disabled = !usable || selected.kind === 'group';
  const siblings = selected ? getSiblings(selected.path) : [];
  $('up').disabled = !usable || selected.path.at(-1) === 0;
  $('down').disabled = !usable || selected.path.at(-1) >= siblings.length - 1;
  $('lock').disabled = !editable || !selected;
  $('lock').textContent = selected && locks.has(key(selected.path)) ? '解锁图层' : '锁定图层';
  if (state) {
    $('document-meta').textContent = dirty() ? '已修改 · 尚未保存' : '文档已载入';
    drawTree();
  }
  sampleStudio?.refresh();
}
for (const [value, label] of Object.entries(modes)) {
  const option = document.createElement('option');
  option.value = 'svg:' + value; option.textContent = label; $('op').append(option);
}
function eyeIcon(visible) {
  return visible
    ? '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12Z" stroke="currentColor" stroke-width="1.5"/><circle cx="12" cy="12" r="2.5" stroke="currentColor" stroke-width="1.5"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m3 3 18 18M9 6.4A13 13 0 0 1 12 6c6.5 0 10 6 10 6a18 18 0 0 1-3 3.5M6.5 7.5A18 18 0 0 0 2 12s3.5 6 10 6c1.5 0 2.8-.3 4-.8" stroke="currentColor" stroke-width="1.5"/></svg>';
}
function drawTree() {
  const tree = $('tree'); tree.replaceChildren();
  $('count').textContent = findNodes().filter(node => node.kind === 'layer').length + ' 层';
  function visit(nodes, depth) {
    for (const node of nodes) {
      const row = document.createElement('div');
      row.className = 'layer-row' + (node.kind === 'group' ? ' group-row' : '') + (selected && samePath(selected.path, node.path) ? ' active' : '') + (!node.visible ? ' is-hidden' : '');
      row.style.paddingLeft = (8 + depth * 16) + 'px';
      const select = document.createElement('button'); select.type = 'button'; select.className = 'layer-select';
      select.setAttribute('aria-pressed', String(!!selected && samePath(selected.path, node.path)));
      if (node.thumbnail) {
        const image = document.createElement('img'); image.src = 'data:image/png;base64,' + node.thumbnail;
        image.alt = ''; image.className = 'layer-thumbnail'; select.append(image);
      } else { const symbol = document.createElement('span'); symbol.className = 'group-symbol'; select.append(symbol); }
      const label = document.createElement('span'); label.className = 'layer-label';
      const name = document.createElement('strong'); name.textContent = node.name || '未命名图层';
      const detail = document.createElement('small');
      detail.textContent = (locked(node) ? '已锁定 · ' : '') + (node.kind === 'group' ? '图层组' : `${node.width || '—'} × ${node.height || '—'} 像素${node.bitDepth === 16 ? ' · 16 位' : ''}`);
      label.append(name, detail); select.append(label); select.onclick = () => { if (!busy && !drag) choose(node); }; row.append(select);
      if (node.kind === 'group') {
        const fold = document.createElement('button'); const folded = collapsed.has(key(node.path));
        fold.type = 'button'; fold.className = 'fold-button'; fold.textContent = folded ? '›' : '⌄';
        fold.setAttribute('aria-label', (folded ? '展开' : '收起') + node.name);
        fold.onclick = () => { if (collapsed.has(key(node.path))) collapsed.delete(key(node.path)); else collapsed.add(key(node.path)); drawTree(); };
        row.append(fold);
      }
      const eye = document.createElement('button'); eye.type = 'button'; eye.className = 'eye-button'; eye.innerHTML = eyeIcon(node.visible);
      eye.setAttribute('aria-label', (node.visible ? '隐藏' : '显示') + node.name);
      eye.disabled = state.editable === false || locked(node) || busy;
      eye.onclick = () => guard(() => editNode(node, { visible: !node.visible })); row.append(eye); tree.append(row);
      if (!collapsed.has(key(node.path))) visit(node.children, depth + 1);
    }
  }
  visit(state.tree, 0);
}
function choose(node) {
  selected = node;
  for (const id of ['name', 'x', 'y', 'opacity', 'op']) $(id).value = node[id];
  $('visible').checked = node.visible; $('opacityValue').value = Math.round(node.opacity * 100) + '%';
  $('selected-title').textContent = node.name || '未命名图层';
  $('selected-size').textContent = node.kind === 'group' ? `${node.children.length} 个子图层` : `${node.width || '—'} × ${node.height || '—'} 像素${node.bitDepth === 16 ? ' · 16 位' : ''}`;
  $('position-help').textContent = locked(node) ? '此图层或上级组已锁定，解锁后可编辑。' : node.kind === 'group' ? '请选择组内图层移动；组可整体调整透明度、复制或移入其他组。' : '拖动画面中的蓝色框，整层内容实时移动。';
  const targets = $('move-target'); targets.replaceChildren(new Option('文档最外层', '[]'));
  for (const group of findNodes().filter(n => n.kind === 'group')) {
    if (node.kind === 'group' && node.path.every((v, i) => group.path[i] === v)) continue;
    targets.add(new Option('　'.repeat(group.path.length - 1) + group.name, key(group.path)));
  }
  targets.value = key(node.path.slice(0, -1));
  drawSelection(); updateActions();
}
function fitCanvas() {
  if (!state) return;
  if (fitMode) {
    const area = $('canvas-area');
    scale = Math.max(0.02, Math.min(8, (area.clientWidth - 80) / state.width, (area.clientHeight - 64) / state.height));
    panX = panY = 0;
  }
  $('artboard').style.width = state.width * scale + 'px'; $('artboard').style.height = state.height * scale + 'px';
  $('artboard').style.left = `calc(50% + ${panX}px)`; $('artboard').style.top = `calc(50% + ${panY}px)`;
  $('zoom').textContent = Math.round(scale * 100) + '%'; drawSelection();
}
new ResizeObserver(fitCanvas).observe($('canvas-area'));
function zoomTo(value, anchorX = 0, anchorY = 0) {
  const next = Math.max(0.02, Math.min(8, value));
  panX = anchorX - (anchorX - panX) * next / scale; panY = anchorY - (anchorY - panY) * next / scale;
  scale = next; fitMode = false; fitCanvas();
}
$('zoom-in').onclick = () => zoomTo(scale * 1.25);
$('zoom-out').onclick = () => zoomTo(scale / 1.25);
$('actual-size').onclick = () => { panX = panY = 0; zoomTo(1); };
$('fit').onclick = () => { fitMode = true; fitCanvas(); };
$('hand').onclick = () => { $('hand').setAttribute('aria-pressed', String($('hand').getAttribute('aria-pressed') !== 'true')); };
$('canvas-area').addEventListener('wheel', event => {
  if (!state || drag) return;
  event.preventDefault(); const rect = $('canvas-area').getBoundingClientRect();
  zoomTo(scale * Math.exp(-event.deltaY * 0.0015), event.clientX - rect.left - rect.width / 2, event.clientY - rect.top - rect.height / 2);
}, { passive: false });
$('canvas-area').addEventListener('pointerdown', event => {
  if (event.button !== 1 && !(event.button === 0 && (space || $('hand').getAttribute('aria-pressed') === 'true'))) return;
  event.preventDefault(); event.stopPropagation();
  pan = { startX: event.clientX, startY: event.clientY, x: panX, y: panY };
  $('canvas-area').setPointerCapture(event.pointerId);
}, true);
$('canvas-area').addEventListener('pointermove', event => {
  if (!pan) return;
  fitMode = false; panX = pan.x + event.clientX - pan.startX; panY = pan.y + event.clientY - pan.startY; fitCanvas();
});
for (const event of ['pointerup', 'pointercancel', 'lostpointercapture']) $('canvas-area').addEventListener(event, () => { pan = null; });
function drawSelection() {
  const box = $('selection');
  box.hidden = !selected || selected.kind === 'group' || !selected.width || $('original').checked || state.editable === false || locked(selected);
  if (box.hidden) return;
  const position = drag || selected;
  box.style.left = position.x / state.width * 100 + '%'; box.style.top = position.y / state.height * 100 + '%';
  box.style.width = selected.width / state.width * 100 + '%'; box.style.height = selected.height / state.height * 100 + '%';
  $('selection-label').textContent = selected.name + ' · 整层';
}
function show(result, reset = false, selectionPath = selected?.path) {
  state = result;
  $('live-preview').hidden = true;
  if (reset) {
    original = result.original || result.png; savedRevision = result.revision;
    $('original').checked = false; collapsed.clear(); locks.clear(); fitMode = true; panX = panY = 0;
  }
  const nodes = findNodes();
  selected = (!reset && nodes.find(node => samePath(node.path, selectionPath))) || nodes.find(node => node.kind === 'layer' && node.visible) || nodes.find(node => node.kind === 'layer') || nodes[0];
  const name = result.name === 'Untitled' ? '未命名文档' : result.name;
  $('document-name').textContent = name + '.ora';
  document.querySelector('.document-preview img').src = 'data:image/png;base64,' + result.png;
  document.querySelector('.document-preview strong').textContent = sampleStudio?.active?.sample.title || name;
  document.querySelector('.document-preview span').textContent = sampleStudio?.active ? (sampleStudio.active.mode === 'practice' ? '动手练习 · 可随时查看参考成图' : 'David Revoy · 原稿图层') : '本地导入的分层文档';
  document.querySelector('.document-preview small').textContent = nodes.filter(node => node.kind === 'layer').length + ' 个独立像素图层';
  document.querySelector('.source-section').hidden = !sampleStudio?.active;
  if (sampleStudio?.active) {
    const sample = sampleStudio.active.sample;
    document.querySelector('.source-section a').href = sample.source;
    document.querySelector('.source-section a').textContent = sample.author + ' · ' + sample.sourceTitle;
    document.querySelector('.source-section p').textContent = sample.note + ' ' + sample.license;
  }
  $('bit-depth').textContent = result.bitDepth ? result.bitDepth + ' 位 sRGB' : '原始预览';
  $('dimensions').textContent = result.width + ' × ' + result.height + ' 像素';
  $('canvas').src = 'data:image/png;base64,' + ($('original').checked ? original : result.png);
  $('compare-label').textContent = sampleStudio?.active?.mode === 'practice' ? '对照练习起点' : '对照导入时画面';
  $('loading').hidden = true;
  $('canvas-hint').textContent = state.editable === false ? '原始预览模式 · 可保存原文件' : '滚轮缩放 · 空格拖动画布 · 蓝框内拖动整层';
  if (selected) choose(selected);
  else {
    drawTree(); $('selection').hidden = true; $('selected-title').textContent = '未选择图层'; $('selected-size').textContent = '可导入 PNG 或新建图层组';
    updateActions();
  }
  fitCanvas(); status();
}
async function mutate(query, path = selected?.path) {
  const result = await invoke(query);
  if (['remove', 'reorder', 'insert', 'duplicate', 'group', 'move', 'undo', 'redo'].includes(query.action)) { locks.clear(); collapsed.clear(); }
  show(result, false, path);
}
async function editNode(node, changes) {
  await mutate({ action: 'edit', path: node.path, name: node.name, x: node.x, y: node.y, opacity: node.opacity, visible: node.visible, op: node.op, ...changes });
}
$('properties').onsubmit = event => {
  event.preventDefault();
  guard(async () => {
    if (!selected || locked(selected)) return;
    await editNode(selected, { name: $('name').value, x: Number($('x').value), y: Number($('y').value), opacity: Number($('opacity').value), visible: $('visible').checked, op: $('op').value });
  });
};
$('opacity').oninput = () => { $('opacityValue').value = Math.round(Number($('opacity').value) * 100) + '%'; };
$('original').onchange = () => {
  if (drag) cancelDrag();
  $('live-preview').hidden = true; $('canvas').src = 'data:image/png;base64,' + ($('original').checked ? original : state.png); drawSelection();
};
for (const [id, offset] of [['up', -1], ['down', 1]]) $(id).onclick = () => guard(async () => {
  const index = selected.path.at(-1) + offset;
  await mutate({ action: 'reorder', path: selected.path, index }, [...selected.path.slice(0, -1), index]);
});
$('remove').onclick = () => guard(() => mutate({ action: 'remove', path: selected.path }));
$('duplicate').onclick = () => guard(() => mutate({ action: 'duplicate', path: selected.path }));
$('move-layer').onclick = () => guard(async () => {
  const from = selected.path, parent = JSON.parse($('move-target').value);
  const adjusted = [...parent], depth = from.length - 1;
  if (parent.length > depth && from.slice(0, -1).every((v, i) => v === parent[i]) && parent[depth] > from[depth]) adjusted[depth]--;
  await mutate({ action: 'move', path: from, parent }, [...adjusted, 0]);
});
$('lock').onclick = () => {
  const path = key(selected.path);
  if (locks.has(path)) locks.delete(path); else locks.add(path);
  choose(selected); status('锁定仅用于本次编辑；结构操作后会清除锁定。');
};
$('undo').onclick = () => guard(() => mutate({ action: 'undo' }));
$('redo').onclick = () => guard(() => mutate({ action: 'redo' }));
function cancelDrag() {
  drag = null; gestureId++; cancelAnimationFrame(previewFrame); $('live-preview').hidden = true;
  if (selected) { $('x').value = selected.x; $('y').value = selected.y; }
  $('canvas-hint').textContent = '滚轮缩放 · 空格拖动画布 · 蓝框内拖动整层'; drawSelection();
}
async function previewLatest() {
  if (!drag || previewRunning || !drag.changed) return;
  const active = drag, x = active.x, y = active.y;
  active.changed = false; previewRunning = true;
  try {
    const result = await invoke({ action: 'preview', path: active.path, x, y });
    if (drag === active && active.id === gestureId && !$('original').checked) {
      const canvas = $('live-preview'); canvas.width = result.width; canvas.height = result.height;
      canvas.getContext('2d').putImageData(new ImageData(result.pixels, result.width, result.height), 0, 0);
      canvas.hidden = false;
    }
  } catch (error) { if (drag === active) { status(error.message); cancelDrag(); } }
  finally { previewRunning = false; if (drag?.changed) previewFrame = requestAnimationFrame(previewLatest); }
}
$('selection').onpointerdown = event => {
  if (event.button !== 0 || !selected || busy || locked(selected) || state.editable === false) return;
  event.preventDefault();
  drag = { startX: event.clientX, startY: event.clientY, startLayerX: selected.x, startLayerY: selected.y, x: selected.x, y: selected.y, path: [...selected.path], id: ++gestureId, changed: true };
  $('selection').setPointerCapture(event.pointerId);
  $('canvas-hint').textContent = '实时拖动预览 · 松手恢复完整清晰度 · Esc 取消';
  previewFrame = requestAnimationFrame(previewLatest);
};
$('selection').onpointermove = event => {
  if (!drag) return;
  drag.x = drag.startLayerX + Math.round((event.clientX - drag.startX) / scale);
  drag.y = drag.startLayerY + Math.round((event.clientY - drag.startY) / scale);
  drag.x = Math.max(-1000000, Math.min(1000000, drag.x)); drag.y = Math.max(-1000000, Math.min(1000000, drag.y));
  drag.changed = true; $('x').value = drag.x; $('y').value = drag.y; drawSelection();
  if (!previewRunning) { cancelAnimationFrame(previewFrame); previewFrame = requestAnimationFrame(previewLatest); }
};
$('selection').onpointerup = () => {
  if (!drag) return;
  const { x, y } = drag; const node = selected;
  drag = null; gestureId++; cancelAnimationFrame(previewFrame);
  if (x === node.x && y === node.y) { $('live-preview').hidden = true; drawSelection(); return; }
  guard(async () => {
    try { await editNode(node, { x, y }); }
    finally { $('live-preview').hidden = true; drawSelection(); }
  });
};
$('selection').onpointercancel = cancelDrag;
$('selection').addEventListener('lostpointercapture', () => { if (drag) cancelDrag(); });
function download(data, filename, type) {
  const bytes = Uint8Array.from(atob(data), char => char.charCodeAt(0));
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const link = document.createElement('a'); link.href = url; link.download = filename; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
const fileBase = () => (state?.name || '分层图像').replace(/[\\/:*?"<>|]/g, '_');
$('png').onclick = () => guard(() => {
  download(state.png, fileBase() + '.png', 'image/png');
  sampleStudio?.recordExport(state.revision);
});
$('save').onclick = () => guard(async () => {
  download((await invoke({ action: 'export' })).data, fileBase() + '.ora', 'image/openraster'); savedRevision = state.revision;
  sampleStudio?.recordExport(state.revision);
});
$('layer-png').onclick = () => guard(async () => download((await invoke({ action: 'layer-png', path: selected.path })).data, '图层-' + fileBase() + '.png', 'image/png'));
$('all-layers').onclick = () => guard(async () => download((await invoke({ action: 'layers-zip' })).data, fileBase() + '-各图层.zip', 'application/zip'));
async function encodedFile(file) {
  if (file.size > 32 * 1024 * 1024) throw Error('网页最多可打开 32 MiB 的文件。');
  const bytes = new Uint8Array(await file.arrayBuffer());
  let binary = '';
  for (let i = 0; i < bytes.length; i += 16384) binary += String.fromCharCode(...bytes.subarray(i, i + 16384));
  return btoa(binary);
}
$('open').onclick = () => $('file').click();
$('file').onchange = () => {
  const file = $('file').files[0]; if (!file) return;
  guard(async () => {
    try {
      if (!await sampleStudio.allowSwitch()) return;
      const result = await invoke({ action: 'open', data: await encodedFile(file) });
      sampleStudio.clear(); show(result, true); $('document-name').textContent = file.name;
    } finally { $('file').value = ''; }
  });
};
$('add-layer').onclick = () => { fileMode = 'insert'; $('layer-file').click(); };
$('replace-layer').onclick = () => { fileMode = 'replace'; $('layer-file').click(); };
$('layer-file').onchange = () => {
  const file = $('layer-file').files[0]; if (!file) return;
  const mode = fileMode, node = selected;
  guard(async () => {
    try {
      const data = await encodedFile(file);
      if (mode === 'replace') await mutate({ action: 'replace', path: node.path, data });
      else {
        const parent = node?.kind === 'group' ? node.path : node?.path.slice(0, -1) || [];
        await mutate({ action: 'insert', parent, index: 0, name: file.name.replace(/\.png$/i, ''), data }, [...parent, 0]);
      }
    } finally { $('layer-file').value = ''; }
  });
};
$('add-group').onclick = () => guard(async () => {
  const parent = selected?.kind === 'group' ? selected.path : selected?.path.slice(0, -1) || [];
  await mutate({ action: 'group', parent, index: 0, name: '新建图层组' }, [...parent, 0]);
});
async function loadSample(sample, mode) {
  $('loading').hidden = false;
  try {
    const url = mode === 'practice' ? sample.practice.file : sample.file;
    const response = await fetch(url);
    if (!response.ok) throw Error('示例文件读取失败');
    const file = new File([await response.blob()], sample.id + '.ora');
    const result = await invoke({ action: 'open', data: await encodedFile(file) });
    sampleStudio.activate(sample, mode);
    show(result, true);
  } finally { $('loading').hidden = true; }
}
sampleStudio = new SampleStudio({
  run: guard, load: loadSample, select: node => {
    for (let i = 1; i < node.path.length; i++) collapsed.delete(key(node.path.slice(0, i)));
    choose(node);
    document.querySelector('.layer-row.active')?.scrollIntoView({ block: 'nearest' });
  },
  getNodes: findNodes, getState: () => state, isBusy: () => busy || !!drag, isDirty: dirty,
  edit: editNode,
  replace: async (node, file) => mutate({ action: 'replace', path: node.path, data: await encodedFile(file) }),
  exportPNG: () => $('png').click(),
});
$('sample').onclick = () => guard(() => sampleStudio.reload());
document.addEventListener('keydown', event => {
  const typing = event.target.closest('input, textarea, select, [contenteditable=true]');
  if (event.key === 'Escape' && drag) { event.preventDefault(); cancelDrag(); return; }
  if (typing || document.querySelector('dialog[open]')) return;
  if (event.code === 'Space') { event.preventDefault(); space = true; }
  if ((event.ctrlKey || event.metaKey) && ['z', 'y'].includes(event.key.toLowerCase())) {
    event.preventDefault(); const action = event.key.toLowerCase() === 'y' || event.shiftKey ? 'redo' : 'undo';
    if (!$(action).disabled) $(action).click();
  }
});
document.addEventListener('keyup', event => { if (event.code === 'Space') space = false; });
window.addEventListener('blur', () => { space = false; if (drag) cancelDrag(); pan = null; });
window.addEventListener('beforeunload', event => { if (dirty()) { event.preventDefault(); event.returnValue = ''; } });
void guard(async () => {
  await sampleStudio.init();
  await sampleStudio.switchTo(sampleStudio.samples[0], 'original', true);
});
