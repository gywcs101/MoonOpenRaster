import assert from 'node:assert/strict';
import { request } from '../../_build/js/debug/build/bridge/bridge.js';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const transparent = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAAtJREFUeNpjYAACAAAFAAHp+tzYAAAAAElFTkSuQmCC';
const width = 16;
const height = 12;
const wrap = body => `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">${body}</svg>`;
const filter = (body, space = 'sRGB') => `<filter id="f" filterUnits="userSpaceOnUse" x="0" y="0" width="${width}" height="${height}"${space ? ' color-interpolation-filters="' + space + '"' : ''}>${body}</filter>`;
const cases = {
  'marker with user space units': wrap(
    '<defs><marker id="m" markerUnits="userSpaceOnUse" markerWidth="3" markerHeight="3" refX="0" refY="1"><rect width="3" height="2" fill="red"/></marker></defs>' +
    '<path d="M2 5H10" stroke="blue" stroke-width="2" marker-end="url(#m)"/>'),
  'gradient inside a repeating pattern': wrap(
    '<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x2="4" y2="0"><stop stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient>' +
    '<pattern id="p" width="8" height="6" patternUnits="userSpaceOnUse"><rect width="4" height="6" fill="url(#g)"/></pattern></defs>' +
    '<rect width="16" height="12" fill="url(#p)"/>'),
  'clipped mask and offset filter': wrap(
    '<defs><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="16" height="12"><rect width="8" height="8" fill="white"/></mask>' +
    '<clipPath id="c"><rect x="3" y="2" width="9" height="8"/></clipPath>' +
    filter('<feOffset dx="2" dy="1"/>') + '</defs>' +
    '<g mask="url(#m)" clip-path="url(#c)"><rect width="8" height="6" fill="lime" filter="url(#f)"/></g>'),
  'filter matrix and component transfer': wrap(
    '<defs>' + filter('<feColorMatrix type="matrix" values="0 0 1 0 0  0 1 0 0 0  1 0 0 0 0  0 0 0 1 0"/>' +
      '<feComponentTransfer><feFuncB type="linear" slope=".5"/></feComponentTransfer>') + '</defs>' +
    '<rect x="2" y="2" width="10" height="8" fill="red" filter="url(#f)"/>'),
  'filter composite and merge': wrap(
    '<defs>' + filter('<feFlood flood-color="blue" result="solid"/>' +
      '<feComposite in="solid" in2="SourceAlpha" operator="in" result="cut"/>' +
      '<feOffset in="cut" dx="2" result="shadow"/>' +
      '<feMerge><feMergeNode in="shadow"/><feMergeNode in="SourceGraphic"/></feMerge>') + '</defs>' +
    '<rect x="2" y="2" width="10" height="8" fill="red" filter="url(#f)"/>'),
  'filter morphology': wrap(
    '<defs>' + filter('<feMorphology operator="dilate" radius="1"/>') + '</defs>' +
    '<rect x="3" y="3" width="6" height="4" fill="red" filter="url(#f)"/>'),
  'transparent blur': wrap(
    '<defs>' + filter('<feGaussianBlur stdDeviation="1"/>') + '</defs>' +
    '<rect x="5" y="4" width="6" height="4" fill="red" filter="url(#f)"/>'),
  'filter primitive clipping in a named intermediate result': wrap(
    '<defs>' + filter('<feFlood x="25%" y="2" width="6" height="4" flood-color="red" result="patch"/>' +
      '<feOffset in="patch" dx="1" dy="2"/>') + '</defs>' +
    '<rect width="16" height="12" fill="blue" filter="url(#f)"/>'),
  'filter primitive object bounding box': wrap(
    '<defs><filter id="f" filterUnits="userSpaceOnUse" x="0" y="0" width="16" height="12" primitiveUnits="objectBoundingBox">' +
      '<feFlood x=".25" y=".25" width=".5" height=".5" flood-color="red"/></filter></defs>' +
    '<rect x="2" y="2" width="12" height="8" fill="blue" filter="url(#f)"/>'),
  'saturation mode': wrap(
    '<defs>' + filter('<feColorMatrix type="saturate" values="0"/>') + '</defs>' +
    '<rect x="2" y="2" width="10" height="8" fill="red" filter="url(#f)"/>'),
  'hue rotation mode': wrap(
    '<defs>' + filter('<feColorMatrix type="hueRotate" values="120"/>') + '</defs>' +
    '<rect x="2" y="2" width="10" height="8" fill="red" filter="url(#f)"/>'),
  'luminance to alpha mode': wrap(
    '<defs>' + filter('<feColorMatrix type="luminanceToAlpha"/>') + '</defs>' +
    '<rect x="2" y="2" width="10" height="8" fill="lime" filter="url(#f)"/>'),
  'default linear RGB color transfer': wrap(
    '<defs>' + filter('<feComponentTransfer><feFuncR type="linear" slope=".5"/></feComponentTransfer>', '') + '</defs>' +
    '<rect x="2" y="2" width="10" height="8" fill="red" filter="url(#f)"/>'),
  'per-primitive linear RGB override': wrap(
    '<defs>' + filter('<feComponentTransfer style="color-interpolation-filters: linearRGB"><feFuncR type="linear" slope=".5"/></feComponentTransfer>') + '</defs>' +
    '<rect x="2" y="2" width="10" height="8" fill="red" filter="url(#f)"/>'),
  'seeded fractal noise': wrap(
    '<defs>' + filter('<feTurbulence type="fractalNoise" baseFrequency=".125 .25" numOctaves="2" seed="17"/>') + '</defs>' +
    '<rect width="16" height="12" filter="url(#f)"/>'),
  'stitched fractal noise': wrap(
    '<defs>' + filter('<feTurbulence type="fractalNoise" baseFrequency=".16 .2" numOctaves="2" seed="17" stitchTiles="stitch"/>') + '</defs>' +
    '<rect width="16" height="12" filter="url(#f)"/>'),
  'alpha-aware convolution': wrap(
    '<defs>' + filter('<feConvolveMatrix order="3 1" kernelMatrix="1 1 1" edgeMode="none"/>') + '</defs>' +
    '<rect x="5" y="3" width="6" height="6" fill="red" filter="url(#f)"/>'),
  'linear RGB convolution preserving alpha': wrap(
    '<defs>' + filter('<feConvolveMatrix color-interpolation-filters="linearRGB" order="3 1" kernelMatrix="1 1 1" preserveAlpha="true" edgeMode="none"/>') + '</defs>' +
    '<g filter="url(#f)"><rect x="2" y="2" width="6" height="8" fill="red"/><rect x="8" y="2" width="6" height="8" fill="lime"/></g>'),
  'linear RGB screen blend': wrap(
    '<defs>' + filter('<feFlood flood-color="#805020" result="under"/>' +
      '<feBlend in="SourceGraphic" in2="under" mode="screen"/>', 'linearRGB') + '</defs>' +
    '<rect width="16" height="12" fill="#3060a0" filter="url(#f)"/>'),
  'linear RGB source-over composite': wrap(
    '<defs>' + filter('<feFlood flood-color="blue" result="under"/>' +
      '<feComposite in="SourceGraphic" in2="under" operator="over"/>', 'linearRGB') + '</defs>' +
    '<rect width="16" height="12" fill="red" fill-opacity=".5" filter="url(#f)"/>'),
  'linear RGB merge': wrap(
    '<defs>' + filter('<feFlood flood-color="blue" result="under"/>' +
      '<feMerge><feMergeNode in="under"/><feMergeNode in="SourceGraphic"/></feMerge>', 'linearRGB') + '</defs>' +
    '<rect width="16" height="12" fill="red" fill-opacity=".5" filter="url(#f)"/>'),
};

function run(query) {
  const result = JSON.parse(request(JSON.stringify(query)));
  assert.equal(result.ok, true, result.error);
  return result;
}

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  for (const [name, svg] of Object.entries(cases)) {
    const data = Buffer.from(svg).toString('base64');
    run({ action: 'compose', width, height, layers: [0, 1].map(i => ({
      name: 'Layer ' + i, data: transparent, x: 0, y: 0,
    })) });
    run({ action: 'replace', path: [0, 0], data });
    const rendered = run({ action: 'layer-png', path: [0, 0] }).data;
    const [actual, reference] = await page.evaluate(async ({ data, rendered, width, height }) => {
      async function pixels(mime, bytes) {
        const img = new Image();
        img.src = 'data:' + mime + ';base64,' + bytes;
        await img.decode();
        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0);
        return Array.from(ctx.getImageData(0, 0, width, height).data);
      }
      return Promise.all([pixels('image/png', rendered), pixels('image/svg+xml', data)]);
    }, { data, rendered, width, height });
    let delta = 0;
    let worst = 0;
    for (const [i, value] of actual.entries()) {
      const alpha = i - i % 4 + 3;
      const difference = i === alpha ? Math.abs(value - reference[i]) :
        Math.abs(value * actual[alpha] - reference[i] * reference[alpha]) / 255;
      if (difference > delta) [delta, worst] = [difference, i];
    }
    assert.ok(reference.some((value, i) => i % 4 === 3 && value >= 128), name);
    if (name === 'transparent blur') {
      const weights = [-3, -2, -1, 0, 1, 2, 3].map(i => Math.exp(-i * i / 2));
      const total = weights.reduce((sum, value) => sum + value, 0);
      const coverage = (coordinate, start, end) => weights.reduce((sum, value, i) =>
        coordinate + i - 3 >= start && coordinate + i - 3 < end ? sum + value : sum, 0) / total;
      for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
          const opacity = Math.round(255 * coverage(x, 5, 11) * coverage(y, 4, 8));
          assert.ok(Math.abs(actual[(y * width + x) * 4 + 3] - opacity) <= 1,
            `centered Gaussian opacity at ${x},${y}`);
        }
      }
    }
    const tolerance = name === 'transparent blur' ? 13 : name.endsWith('fractal noise') ? 2 : 1;
    assert.ok(delta <= tolerance, `${name}: channel ${worst} differs by ${delta}, ${actual[worst]} vs ${reference[worst]}`);
    console.log(`PASS: ${name}, Chromium reference, maximum channel difference ${delta}`);
  }
} finally {
  await browser.close();
}
