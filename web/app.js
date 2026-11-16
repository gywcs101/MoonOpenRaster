import { request } from './core.js?v=studio-20261117-2';

const $ = id => document.getElementById(id);
const modes = {
  'src-over': '正常', multiply: '正片叠底', screen: '滤色', overlay: '叠加',
  darken: '变暗', lighten: '变亮', 'color-dodge': '颜色减淡', 'color-burn': '颜色加深',
  'hard-light': '强光', 'soft-light': '柔光', difference: '差值', color: '颜色',
  luminosity: '明度', hue: '色相', saturation: '饱和度', plus: '相加',
  'dst-in': '保留底图重合部分', 'dst-out': '用上层擦除底图',
  'src-atop': '将上层限制在底图内', 'dst-atop': '将底图限制在上层内'
};
let state;
let selected;
let original;
let posterRequest;
let dirty = false;
let isPosterSample = false;
const collapsed = new Set();

function invoke(query) {
  const result = JSON.parse(request(JSON.stringify(query)));
  if (!result.ok) throw Error(result.error);
  return result;
}

function status(message = '') {
  let text = message || state?.warning || '';
  const translations = {
    'Invalid document: ': '文档无法处理：',
    'Unsupported feature: ': '暂不支持：',
    'Only 8-bit PNG input is currently supported': '此文档的位深超出编辑范围，已显示原始预览。可保存原文件。',
    'ICC-profiled PNG requires color management': '此文档包含 ICC 色彩配置，已显示原始预览。可保存原文件。',
    'Unknown composite operation: ': '暂不支持的混合方式：',
    'Unknown layer element: ': '暂不支持的图层类型：',
    'Expected an integer coordinate or layer index': '位置和图层编号必须是范围内的整数。',
    'Open a document first': '请先打开一个文档。',
    'Rendering buffer budget exceeded': '合成所需内存超出限制。',
    'Decoded layer pixels exceed 128 MiB budget': '图层像素数据超过 128 MiB 限制。'
  };
  for (const [source, target] of Object.entries(translations)) text = text.replace(source, target);
  $('status').textContent = text;
}

function guard(action) {
  try { action(); status(); } catch (error) { status(error.message); }
}

function findNodes() {
  const all = [];
  function walk(nodes) {
    for (const node of nodes) { all.push(node); walk(node.children); }
  }
  walk(state.tree);
  return all;
}

function samePath(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

for (const [value, label] of Object.entries(modes)) {
  const option = document.createElement('option');
  option.value = 'svg:' + value;
  option.textContent = label;
  $('op').append(option);
}

function eyeIcon(visible) {
  return visible
    ? '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12Z" stroke="currentColor" stroke-width="1.5"/><circle cx="12" cy="12" r="2.5" stroke="currentColor" stroke-width="1.5"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="m3 3 18 18M9 6.4A13 13 0 0 1 12 6c6.5 0 10 6 10 6a18 18 0 0 1-3 3.5M6.5 7.5A18 18 0 0 0 2 12s3.5 6 10 6c1.5 0 2.8-.3 4-.8" stroke="currentColor" stroke-width="1.5"/></svg>';
}

function drawTree() {
  const tree = $('tree');
  tree.replaceChildren();
  const total = findNodes().filter(node => node.kind === 'layer').length;
  $('count').textContent = total + ' 层';
  function visit(nodes, depth) {
    for (const node of nodes) {
      const row = document.createElement('div');
      row.className = 'layer-row' + (node.kind === 'group' ? ' group-row' : '')
        + (selected && samePath(selected.path, node.path) ? ' active' : '')
        + (!node.visible ? ' is-hidden' : '');
      row.style.paddingLeft = (8 + depth * 16) + 'px';
      const select = document.createElement('button');
      select.type = 'button';
      select.className = 'layer-select';
      select.setAttribute('aria-pressed', String(selected && samePath(selected.path, node.path)));
      if (node.thumbnail) {
        const image = document.createElement('img');
        image.src = 'data:image/png;base64,' + node.thumbnail;
        image.alt = '';
        image.className = 'layer-thumbnail';
        select.append(image);
      } else {
        const symbol = document.createElement('span');
        symbol.className = 'group-symbol';
        select.append(symbol);
      }
      const label = document.createElement('span');
      label.className = 'layer-label';
      const name = document.createElement('strong');
      name.textContent = node.name || '未命名图层';
      const detail = document.createElement('small');
      detail.textContent = node.kind === 'group' ? '图层组' : (node.width ? `${node.width} × ${node.height} 像素` : '像素图层');
      label.append(name, detail);
      select.append(label);
      select.onclick = () => choose(node);
      row.append(select);
      if (node.kind === 'group') {
        const fold = document.createElement('button');
        const folded = collapsed.has(JSON.stringify(node.path));
        fold.type = 'button';
        fold.className = 'fold-button';
        fold.textContent = folded ? '›' : '⌄';
        fold.setAttribute('aria-label', (folded ? '展开' : '收起') + node.name);
        fold.onclick = () => {
          const key = JSON.stringify(node.path);
          if (collapsed.has(key)) collapsed.delete(key); else collapsed.add(key);
          drawTree();
        };
        row.append(fold);
      }
      const eye = document.createElement('button');
      eye.type = 'button';
      eye.className = 'eye-button';
      eye.innerHTML = eyeIcon(node.visible);
      eye.setAttribute('aria-label', (node.visible ? '隐藏' : '显示') + node.name);
      eye.disabled = state.editable === false;
      eye.onclick = () => guard(() => editNode(node, { visible: !node.visible }));
      row.append(eye);
      tree.append(row);
      if (!collapsed.has(JSON.stringify(node.path))) visit(node.children, depth + 1);
    }
  }
  visit(state.tree, 0);
}

function choose(node) {
  selected = node;
  for (const id of ['name', 'x', 'y', 'opacity', 'op']) $(id).value = node[id];
  $('visible').checked = node.visible;
  $('opacityValue').value = Math.round(node.opacity * 100) + '%';
  $('selected-title').textContent = node.name || '未命名图层';
  $('selected-size').textContent = node.kind === 'group' ? `${node.children.length} 个子图层` : `${node.width || '—'} × ${node.height || '—'} 像素`;
  $('position-help').textContent = node.kind === 'group'
    ? '图层组的位置由各个子图层决定。请选择组内图层移动。'
    : '移动整个选中图层，层内的内容会一起移动。';
  for (const control of $('properties').elements) control.disabled = state.editable === false;
  $('x').disabled = $('y').disabled = node.kind === 'group' || state.editable === false;
  const siblings = getSiblings(node.path);
  const index = node.path.at(-1);
  $('up').disabled = state.editable === false || index === 0;
  $('down').disabled = state.editable === false || index >= siblings.length - 1;
  $('remove').disabled = state.editable === false;
  drawTree();
  drawSelection();
}

function getSiblings(path) {
  let nodes = state.tree;
  for (const index of path.slice(0, -1)) nodes = nodes[index].children;
  return nodes;
}

function fitCanvas() {
  if (!state) return;
  const area = $('canvas-area');
  const scale = Math.max(0.05, Math.min((area.clientWidth - 80) / state.width, (area.clientHeight - 64) / state.height));
  $('artboard').style.width = state.width * scale + 'px';
  $('artboard').style.height = state.height * scale + 'px';
  $('zoom').textContent = Math.round(scale * 100) + '%';
  drawSelection();
}
new ResizeObserver(fitCanvas).observe($('canvas-area'));

function drawSelection() {
  const box = $('selection');
  box.hidden = !selected || selected.kind === 'group' || !selected.width || $('original').checked || state.editable === false;
  if (box.hidden) return;
  box.style.left = selected.x / state.width * 100 + '%';
  box.style.top = selected.y / state.height * 100 + '%';
  box.style.width = selected.width / state.width * 100 + '%';
  box.style.height = selected.height / state.height * 100 + '%';
  $('selection-label').textContent = selected.name + ' · 整层';
}

function show(result, reset = false) {
  const previous = selected?.path;
  state = result;
  if (reset) {
    original = result.original || result.png;
    $('original').checked = false;
    collapsed.clear();
    dirty = false;
  }
  const nodes = findNodes();
  selected = (!reset && nodes.find(node => samePath(node.path, previous))) || nodes.find(node => node.kind === 'layer') || nodes[0];
  const name = result.name === 'Untitled' ? '未命名文档' : result.name;
  $('document-name').textContent = name + '.ora';
  document.querySelector('.document-preview img').src = 'data:image/png;base64,' + result.png;
  document.querySelector('.document-preview strong').textContent = isPosterSample ? '星际漫游' : name;
  document.querySelector('.document-preview span').textContent = isPosterSample ? 'NASA 海报再编排示例' : '本地导入的分层文档';
  document.querySelector('.document-preview small').textContent = nodes.filter(node => node.kind === 'layer').length + ' 个独立像素图层';
  document.querySelector('.source-section').hidden = !isPosterSample;
  $('document-meta').textContent = dirty ? '已修改' : '文档已载入';
  $('dimensions').textContent = result.width + ' × ' + result.height + ' 像素';
  $('canvas').src = 'data:image/png;base64,' + ($('original').checked ? original : result.png);
  $('loading').hidden = true;
  $('canvas-hint').textContent = state.editable === false ? '原始预览模式 · 可保存原文件' : '蓝色框标出选中图层的范围';
  if (selected) choose(selected);
  else {
    drawTree();
    $('selection').hidden = true;
    $('selected-title').textContent = '未选择图层';
    $('selected-size').textContent = '此文档没有可选图层';
    for (const control of $('properties').elements) control.disabled = true;
    for (const id of ['up', 'down', 'remove']) $(id).disabled = true;
  }
  fitCanvas();
  status();
}

function editNode(node, changes) {
  const query = {
    action: 'edit', path: node.path, name: node.name, x: node.x, y: node.y,
    opacity: node.opacity, visible: node.visible, op: node.op, ...changes
  };
  const result = invoke(query);
  dirty = true;
  show(result);
}

$('properties').onsubmit = event => {
  event.preventDefault();
  guard(() => {
    if (!selected) return;
    editNode(selected, {
      name: $('name').value, x: Number($('x').value), y: Number($('y').value),
      opacity: Number($('opacity').value), visible: $('visible').checked, op: $('op').value
    });
  });
};
$('opacity').oninput = () => $('opacityValue').value = Math.round(Number($('opacity').value) * 100) + '%';
$('original').onchange = () => {
  $('canvas').src = 'data:image/png;base64,' + ($('original').checked ? original : state.png);
  drawSelection();
};
for (const [id, offset] of [['up', -1], ['down', 1]]) {
  $(id).onclick = () => guard(() => {
    if (!selected) return;
    const result = invoke({ action: 'reorder', path: selected.path, index: selected.path.at(-1) + offset });
    selected.path = [...selected.path.slice(0, -1), selected.path.at(-1) + offset];
    dirty = true;
    show(result);
  });
}
$('remove').onclick = () => guard(() => {
  if (!selected) return;
  const result = invoke({ action: 'remove', path: selected.path });
  dirty = true;
  show(result);
});

let drag;
$('selection').onpointerdown = event => {
  if (!selected || state.editable === false) return;
  event.preventDefault();
  drag = { startX: event.clientX, startY: event.clientY, x: selected.x, y: selected.y };
  $('selection').setPointerCapture(event.pointerId);
};
$('selection').onpointermove = event => {
  if (!drag) return;
  const scale = $('artboard').clientWidth / state.width;
  $('x').value = drag.x + Math.round((event.clientX - drag.startX) / scale);
  $('y').value = drag.y + Math.round((event.clientY - drag.startY) / scale);
  $('selection').style.left = Number($('x').value) / state.width * 100 + '%';
  $('selection').style.top = Number($('y').value) / state.height * 100 + '%';
};
$('selection').onpointerup = () => {
  if (!drag) return;
  drag = null;
  guard(() => editNode(selected, { x: Number($('x').value), y: Number($('y').value) }));
};
$('selection').onpointercancel = () => { drag = null; drawSelection(); };

function download(data, filename, type) {
  const bytes = Uint8Array.from(atob(data), char => char.charCodeAt(0));
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
$('png').onclick = () => guard(() => download(state.png, '海报合成.png', 'image/png'));
$('save').onclick = () => guard(() => {
  download(invoke({ action: 'export' }).data, '海报编辑.ora', 'image/openraster');
  dirty = false;
  $('document-meta').textContent = '文档已导出';
});
$('open').onclick = () => $('file').click();
$('file').onchange = async () => {
  const file = $('file').files[0];
  if (!file) return;
  try {
    if (file.size > 32 * 1024 * 1024) throw Error('网页最多可打开 32 MiB 的文件。');
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = '';
    for (let i = 0; i < bytes.length; i += 16384) binary += String.fromCharCode(...bytes.subarray(i, i + 16384));
    const result = invoke({ action: 'open', data: btoa(binary) });
    isPosterSample = false;
    show(result, true);
    $('document-name').textContent = file.name;
  } catch (error) { status(error.message); }
  finally { $('file').value = ''; }
};

function raster(width, height, paint) {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  paint(canvas.getContext('2d'));
  return canvas.toDataURL('image/png').split(',')[1];
}
async function loadPoster() {
  $('loading').hidden = false;
  try {
    if (!posterRequest) {
      const image = new Image();
      image.src = 'assets/grand-tour.jpg';
      await image.decode();
      posterRequest = {
        action: 'compose', width: 600, height: 894,
        layers: [
          { name: '中文主标题', x: 32, y: 28, data: raster(430, 78, ctx => {
            ctx.fillStyle = '#192e30'; ctx.font = '600 62px "Microsoft YaHei", sans-serif'; ctx.textBaseline = 'top'; ctx.fillText('星际漫游', 0, 0);
          }) },
          { name: '主题说明', x: 34, y: 109, data: raster(440, 32, ctx => {
            ctx.fillStyle = '#476b69'; ctx.font = '16px "Microsoft YaHei", sans-serif'; ctx.textBaseline = 'top'; ctx.fillText('旅行者的下一站，是更远的世界', 0, 0);
          }) },
          { name: '强调线', x: 34, y: 148, data: raster(210, 3, ctx => { ctx.fillStyle = '#e34e2b'; ctx.fillRect(0, 0, 210, 3); }) },
          { name: '素材署名', x: 32, y: 875, data: raster(540, 18, ctx => {
            ctx.fillStyle = '#365759'; ctx.font = '11px sans-serif'; ctx.textBaseline = 'top'; ctx.fillText('Courtesy NASA/JPL-Caltech.  中文再编排 · MoonOpenRaster 图层示例', 0, 0);
          }) },
          { name: 'NASA 海报原图', x: 0, y: 0, data: raster(600, 894, ctx => ctx.drawImage(image, 0, 0, 600, 894)) }
        ]
      };
    }
    await new Promise(resolve => requestAnimationFrame(resolve));
    const result = invoke(posterRequest);
    isPosterSample = true;
    show(result, true);
  } catch (error) { $('loading').hidden = true; status('海报载入失败，请重载示例。' + error.message); }
}
$('sample').onclick = loadPoster;
loadPoster();

