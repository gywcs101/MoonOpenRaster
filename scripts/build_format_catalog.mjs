import fs from 'node:fs';
import path from 'node:path';
import { request } from '../web/core.js';

const assetDir = 'assets/import-samples';
const tasks = [
  {
    id: 'postcard', title: '海岸明信片', subtitle: '换上 JPEG 海岸画面，再叠加两种透明素材。',
    formats: ['JPEG', 'WebP', 'PNG'],
    steps: [
      ['image', '照片窗口', 'tide.jpg', '替换照片', '用 JPEG 替换照片窗口，保留原位置。'],
      ['insert', 'stamp', 'stamp.webp', '加上透明邮戳', '导入透明 WebP，观察邮戳边缘与底图的叠加。'],
      ['properties', 'stamp', { x: 345, y: 85, opacity: .85 }, '安排邮戳位置', '把邮戳移到右侧，再将不透明度调为 85%。'],
      ['insert', 'tide-mark', 'tide-mark.png', '加入波形标记', '导入透明 PNG 标记，观察底图如何透过空白处显示。'],
      ['properties', 'tide-mark', { x: 366, y: 173 }, '对齐标记', '把波形移到邮戳下方。'],
    ],
  },
  {
    id: 'atlas', title: '地形测绘图', subtitle: '保留 16 位等高渐变，配上独立的图例。',
    formats: ['16 位 TIFF', 'BMP'],
    steps: [
      ['image', '高程窗口', 'elevation.tiff', '换入 16 位地形', '用 TIFF 替换高程窗口，检查图层和画布的位深。'],
      ['insert', 'legend', 'legend.bmp', '导入图例', '添加 BMP 图例，底板与高程层保持独立。'],
      ['properties', 'legend', { x: 389, y: 62 }, '靠右对齐', '把图例摆到高程图右侧。'],
      ['properties', '高程窗口', { opacity: .82 }, '调整高程层', '将高程层的不透明度调为 82%，再导出 16 位画面。'],
    ],
  },
  {
    id: 'signal', title: '夜间车站', subtitle: '用 GIF 的第一帧制作灯牌，再添加 ICO 站标。',
    formats: ['GIF', 'ICO'],
    steps: [
      ['image', '灯牌', 'departures.gif', '换上发车灯牌', '用 GIF 替换灯牌，工作台会导入动画第一帧。'],
      ['insert', 'station', 'station.ico', '加入车站标志', '导入 ICO，使用其中最大的图标。'],
      ['properties', 'station', { x: 360, y: 151 }, '移动站标', '把站标移动到右下位置。'],
      ['properties', '灯牌', { visible: false }, '切换灯牌显隐', '隐藏灯牌，保留它的像素数据以便稍后恢复。'],
    ],
  },
];
const invoke = query => {
  const result = JSON.parse(request(JSON.stringify(query)));
  if (!result.ok || result.editable === false) throw Error(result.error || result.warning);
  return result;
};
const read = asset => fs.readFileSync(path.join('web', asset)).toString('base64');
const write = (asset, data) => fs.writeFileSync(path.join('web', asset), Buffer.from(data, 'base64'));

const samples = tasks.map(({ id, title, subtitle, formats, steps }) => {
  const file = assetDir + '/' + id + '.ora';
  const start = assetDir + '/' + id + '-start.png';
  const goal = assetDir + '/' + id + '-goal.png';
  const goalFile = assetDir + '/' + id + '-goal.ora';
  let state = invoke({ action: 'open', data: read(file) });
  write(start, state.png);
  const { width, height } = state;
  const layerCount = state.tree.length;
  const guides = [];
  for (const [type, name, value, heading, text] of steps) {
    const node = state.tree.find(layer => layer.name === name);
    let check;
    if (type === 'properties') {
      state = invoke({ action: 'edit', ...node, ...value });
      check = { name, type, expected: value };
    } else {
      const asset = assetDir + '/' + value;
      const data = read(asset);
      state = type === 'insert'
        ? invoke({ action: 'insert', parent: [], index: 0, name, data })
        : invoke({ action: 'replace', path: node.path, data });
      const { thumbnail, width, height, bitDepth } = state.tree.find(layer => layer.name === name);
      check = { name, type: 'image', insert: type === 'insert', asset, thumbnail, width, height, bitDepth };
    }
    guides.push({ title: heading, text, checks: [check], suggestion: heading });
  }
  guides.push({ title: '导出成图', text: '导出 PNG，或保存 ORA 后重开检查图层。', type: 'export' });
  write(goal, state.png);
  write(goalFile, invoke({ action: 'export' }).data);
  return {
    id, file, cover: goal, title, subtitle, formats, width, height, layerCount,
    author: 'MoonOpenRaster',
    source: 'https://github.com/gywcs101/MoonOpenRaster/blob/main/LICENSE',
    sourceTitle: '原创格式练习',
    note: '用于展示图片导入与图层编辑。', license: 'MIT',
    practice: { file, start, goal, goalFile, steps: guides },
  };
});
fs.writeFileSync('web/assets/format-catalog.json', JSON.stringify({ version: 1, samples }, null, 2) + '\n');
