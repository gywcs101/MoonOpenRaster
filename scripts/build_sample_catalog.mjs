// Build practice files through the same MoonBit bridge used by the workbench.
import fs from 'node:fs';
import path from 'node:path';
import { request } from '../web/core.js';
const out = 'web/assets/samples';
const run = query => { const r = JSON.parse(request(JSON.stringify(query))); if (!r.ok || r.editable === false) throw Error(r.error || r.warning); return r; };
const flatten = tree => tree.flatMap(n => [n, ...flatten(n.children)]);
let current;
const node = name => { const n = flatten(current.tree).find(n => n.name === name); if (!n) throw Error('Missing source layer ' + name); return n; };
function edit(name, changes) {
  const n = node(name);
  current = run({ action: 'edit', path: n.path, name: n.name, x: n.x, y: n.y, opacity: n.opacity, visible: n.visible, op: n.op, ...changes });
}
function save(id, suffix) {
  fs.writeFileSync(`${out}/${id}${suffix}.ora`, Buffer.from(run({ action: 'export' }).data, 'base64'));
  fs.writeFileSync(`${out}/${id}${suffix}.png`, Buffer.from(current.png, 'base64'));
}
const definitions = [
  {
    id: 'capitole', title: '自由之都', subtitle: '把一张错位的插画整理干净',
    file: 'assets/capitole.ora', cover: 'assets/capitole-preview.png',
    source: 'https://www.peppercarrot.com/zh/viewer/misc__2023-06-30_Poster-for-Capitole-du-libre-2023_by-David-Revoy.html',
    sourceTitle: 'Poster for Capitole du libre 2023',
    note: '7 个原始绘画图层。练习起点故意移动线稿、显示草稿，并把背景染成浅绿；参考图恢复原稿的干净状态。',
  },
  {
    id: 'bloom', title: '花间少女', subtitle: '从完成稿里找回铅笔与明暗',
    sourceTitle: 'In Bloom', source: 'https://www.peppercarrot.com/en/viewer/artworks__2022-03-02_In-Bloom_by-David-Revoy.html',
    note: '保留原稿的补绘、线稿、预色与明暗层。练习通过隐藏完成稿层，制作保留明暗的素描版本。',
  },
  {
    id: 'house', title: '林间小屋', subtitle: '去掉参考线，修复前景与气氛',
    sourceTitle: 'Spooky Cute House', source: 'https://www.peppercarrot.com/en/viewer/artworks__2021-05-19_Spooky-Cute-House_by-David-Revoy.html',
    note: '保留原稿的透视辅助组和绘画组。练习起点显示辅助线、移动前景并减弱后期层，参考图恢复原稿气氛。',
  },
  {
    id: 'rain', title: '雨城', subtitle: '把大雨改成更清楚的小雨场景',
    sourceTitle: 'Rain City', source: 'https://www.peppercarrot.com/en/viewer/artworks__2022-12-06_Rain-City_by-David-Revoy.html',
    note: '9 个栅格层与后期组。原 KRA 的两项调整效果由 Krita 烘焙后导出；练习保留这些结果，调节雨幕与辅助层。',
  },
];
for (const sample of definitions) {
  const raw = sample.file || `../_build/sample-build/${sample.id}.ora`;
  const disk = sample.file ? path.join('web', raw) : `_build/sample-build/${sample.id}.ora`;
  current = run({ action: 'open', data: fs.readFileSync(disk).toString('base64') });
  if (!sample.file) { save(sample.id, ''); sample.file = `assets/samples/${sample.id}.ora`; sample.cover = `assets/samples/${sample.id}.png`; }
  sample.width = current.width; sample.height = current.height;
  sample.layerCount = flatten(current.tree).filter(n => n.kind === 'layer').length;
  sample.author = 'David Revoy'; sample.license = 'CC BY 4.0 · 禁止 AI 衍生（作者标注）';
  const check = (name, type, properties) => ({ name, type, ...properties });
  const hidden = name => check(name, 'properties', { expected: { visible: false } });
  const step = (title, text, checks, suggestion) => ({ title, text, checks, suggestion });
  let steps;
  if (sample.id === 'capitole') {
    const ink = node('线稿');
    const background = node('背景');
    const backgroundPNG = run({ action: 'layer-png', path: background.path }).data;
    fs.writeFileSync(`${out}/capitole-original-background.png`, Buffer.from(backgroundPNG, 'base64'));
    // The replacement asset is the original author's background layer, not a newly painted asset.
    steps = [
      step('对齐线稿', `选择“线稿”，把线条移回底色上。参考位置：X ${ink.x}，Y ${ink.y}。`, [check('线稿', 'properties', { expected: { x: ink.x, y: ink.y }, tolerance: 3 })], '应用参考位置'),
      step('隐藏草稿', '关闭“草稿”旁的眼睛，让未完成的线条不再干扰画面。', [hidden('草稿')], '隐藏草稿'),
      step('换回干净背景', '将“背景”替换成原稿的白底 PNG。也可下载素材后用右侧“替换 PNG”导入。', [check('背景', 'image', { thumbnail: background.thumbnail, width: background.width, height: background.height, asset: 'assets/samples/capitole-original-background.png' })], '使用原稿白底'),
    ];
    edit('线稿', { x: ink.x + 40, y: ink.y - 24 });
    edit('草稿', { visible: true, opacity: .38 });
    const tinted = fs.readFileSync('_build/sample-build/capitole-tinted-background.png').toString('base64');
    current = run({ action: 'replace', path: node('背景').path, data: tinted });
  } else if (sample.id === 'bloom') {
    steps = [
      step('收起完成稿补绘', '依次隐藏“细节补绘”和“轮廓补绘”，露出下面的铅笔绘制。署名保持显示。', [hidden('细节补绘'), hidden('轮廓补绘')], '隐藏当前补绘层'),
      step('去掉预设色彩', '隐藏“预设色彩”，保留“明暗底稿”，得到有体积感的素描。', [hidden('预设色彩')], '隐藏预设色彩'),
      step('让线条清楚一些', '选择“铅笔线稿”，把不透明度调到 80% 左右，再应用。', [check('铅笔线稿', 'properties', { expected: { opacity: .8 }, tolerance: .08 })], '使用 80% 线稿'),
    ];
    for (const name of ['细节补绘', '轮廓补绘', '预设色彩']) edit(name, { visible: false });
    edit('铅笔线稿', { opacity: .8 }); save(sample.id, '-goal');
    current = run({ action: 'open', data: fs.readFileSync(path.join('web', sample.file)).toString('base64') });
    edit('铅笔线稿', { opacity: .3 });
  } else if (sample.id === 'house') {
    const front = node('前景绘制');
    steps = [
      step('关掉透视参考组', '隐藏整个“透视参考组”，一次收起所有彩色辅助线。不要逐个删除子层。', [hidden('透视参考组')], '隐藏参考组'),
      step('把前景移回去', `选择“前景绘制”，让道路与房屋重新衔接。参考位置：X ${front.x}，Y ${front.y}。`, [check('前景绘制', 'properties', { expected: { x: front.x, y: front.y }, tolerance: 3 })], '应用参考位置'),
      step('恢复后期气氛', '选择“后期修饰”，将不透明度提高到 90%–100%，让光影与整体色调更完整。', [check('后期修饰', 'properties', { expected: { opacity: 1 }, tolerance: .1 })], '恢复后期修饰'),
    ];
    edit('透视参考组', { visible: true, opacity: .65 });
    edit('前景绘制', { x: front.x + 30, y: front.y + 14 });
    edit('后期修饰', { opacity: .2 });
  } else {
    steps = [
      step('退出构图检查', '隐藏“构图检查”，从黑白检查图切回彩色画面。这个辅助层保留下来即可。', [hidden('构图检查')], '隐藏构图检查'),
      step('收起透视线', '隐藏“透视参考线”，让建筑上的辅助线退出最终画面。', [hidden('透视参考线')], '隐藏透视参考线'),
      step('把大雨调成小雨', '展开“后期效果”，选择“雨幕”，将不透明度调到 20%–35%，让人物和建筑更清楚。', [check('雨幕', 'properties', { expected: { opacity: .28 }, ranges: { opacity: [.2, .35] } })], '使用 28% 雨幕'),
    ];
    edit('雨幕', { opacity: .28 }); save(sample.id, '-goal');
    current = run({ action: 'open', data: fs.readFileSync(path.join('web', sample.file)).toString('base64') });
    edit('构图检查', { visible: true }); edit('透视参考线', { visible: true });
  }
  save(sample.id, '-practice');
  sample.practice = {
    file: `assets/samples/${sample.id}-practice.ora`, start: `assets/samples/${sample.id}-practice.png`,
    goal: ['capitole', 'house'].includes(sample.id) ? sample.cover : `assets/samples/${sample.id}-goal.png`,
    goalFile: ['capitole', 'house'].includes(sample.id) ? sample.file : `assets/samples/${sample.id}-goal.ora`,
    steps: [...steps, { title: '导出你的作品', text: '前三项完成后，导出 PNG 与朋友分享；也可以保存 ORA，保留图层继续修改。', type: 'export' }],
  };
  console.log(`${sample.id}: ${sample.layerCount} authentic raster layers, ${sample.practice.steps.length} guided steps`);
}
fs.writeFileSync('web/assets/sample-catalog.json', JSON.stringify({ version: 1, samples: definitions }, null, 2));
