import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../../', import.meta.url));
const port = Number(process.env.TEST_PORT || 18765);
const server = spawn(process.env.PYTHON || 'python', ['scripts/serve_web.py', '--no-build', '--port', String(port)], { cwd: root, stdio: 'pipe' });
let browser;
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonora-browser-'));
const errors = [];
try {
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('Preview server did not start')), 15000);
    server.stdout.on('data', data => { if (String(data).includes('http://')) { clearTimeout(timer); resolve(); } });
    server.on('exit', code => { clearTimeout(timer); reject(Error('Preview server exited: ' + code)); });
  });
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1500, height: 1000 }, acceptDownloads: true });
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto(`http://127.0.0.1:${port}/`);
  const idle = () => page.waitForFunction(() => !document.body.classList.contains('is-busy') && document.querySelector('#loading').hidden, { timeout: 30000 });
  await idle();
  assert.equal(await page.locator('#count').innerText(), '7 层');
  assert.equal(await page.locator('#name').inputValue(), '线稿');
  assert.equal(await page.locator('#undo').isDisabled(), true);
  const originalImage = await page.locator('#canvas').getAttribute('src');
  await page.getByRole('button', { name: '隐藏线稿', exact: true }).click(); await idle();
  assert.notEqual(await page.locator('#canvas').getAttribute('src'), originalImage);
  assert.equal(await page.locator('#visible').isChecked(), false);
  await page.locator('#undo').click(); await idle();
  assert.equal(await page.locator('#canvas').getAttribute('src'), originalImage);
  const originalX = Number(await page.locator('#x').inputValue());
  const selection = await page.locator('#selection').boundingBox();
  const area = await page.locator('#canvas-area').boundingBox();
  const cx = Math.max(area.x + 10, Math.min(area.x + area.width - 10, selection.x + selection.width / 2));
  const cy = Math.max(area.y + 10, Math.min(area.y + area.height - 10, selection.y + selection.height / 2));
  const t0 = Date.now();
  await page.mouse.move(cx, cy); await page.mouse.down(); await page.mouse.move(cx + 32, cy + 12, { steps: 6 });
  await page.locator('#live-preview').waitFor({ state: 'visible' });
  const latency = Date.now() - t0;
  // Pixels change before pointerup, while the full-resolution committed image remains untouched.
  assert.equal(await page.locator('#canvas').getAttribute('src'), originalImage);
  assert.equal(await page.locator('#undo').isDisabled(), true);
  const live = await page.locator('#live-preview').evaluate(canvas => ({ width: canvas.width, height: canvas.height, nonempty: canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data.some(v => v !== 0) }));
  assert.equal(live.width, 384); assert.equal(live.nonempty, true);
  await page.mouse.up(); await idle();
  const movedX = Number(await page.locator('#x').inputValue()); assert.notEqual(movedX, originalX);
  const movedImage = await page.locator('#canvas').getAttribute('src'); assert.notEqual(movedImage, originalImage);
  await page.locator('#undo').click(); await idle();
  assert.equal(await page.locator('#canvas').getAttribute('src'), originalImage);
  assert.equal(await page.locator('#undo').isDisabled(), true);
  await page.locator('#redo').click(); await idle(); assert.equal(Number(await page.locator('#x').inputValue()), movedX);
  // Escape abandons a live gesture without adding an undo step.
  const beforeCancelX = await page.locator('#x').inputValue();
  const box = await page.locator('#selection').boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2); await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 10, box.y + box.height / 2);
  await page.keyboard.press('Escape'); await page.mouse.up();
  assert.equal(await page.locator('#x').inputValue(), beforeCancelX);
  assert.equal(await page.locator('#live-preview').isVisible(), false);
  await page.locator('#hand').click();
  const left = await page.locator('#artboard').evaluate(el => el.style.left);
  await page.mouse.move(area.x + 20, area.y + 30); await page.mouse.down();
  await page.mouse.move(area.x + 45, area.y + 50); await page.mouse.up();
  assert.notEqual(await page.locator('#artboard').evaluate(el => el.style.left), left);
  await page.locator('#hand').click();
  await page.locator('#original').check(); assert.equal(await page.locator('#selection').isVisible(), false);
  await page.locator('#original').uncheck(); assert.equal(await page.locator('#selection').isVisible(), true);
  await page.locator('#zoom-in').click(); const zoom = await page.locator('#zoom').innerText();
  await page.locator('#name').fill('线稿 · 中文测试'); await page.locator('.apply-button').click(); await idle();
  assert.equal(await page.locator('#zoom').innerText(), zoom);
  // Local native input undo remains available; document history is only handled outside inputs.
  await page.locator('#dimensions').click(); await page.keyboard.press('Control+z'); await idle();
  assert.equal(await page.locator('#name').inputValue(), '线稿');
  await page.locator('#fit').click();
  await page.locator('#lock').click(); assert.equal(await page.locator('#x').isDisabled(), true);
  assert.equal(await page.locator('#selection').isVisible(), false); await page.locator('#lock').click();
  await page.locator('#duplicate').click(); await idle(); assert.equal(await page.locator('#count').innerText(), '8 层');
  assert.match(await page.locator('#name').inputValue(), /副本/);
  await page.locator('#move-target').selectOption('[]'); await page.locator('#move-layer').click(); await idle();
  assert.match(await page.locator('#name').inputValue(), /副本/);
  await page.locator('#remove').click(); await idle(); assert.equal(await page.locator('#count').innerText(), '7 层');
  const png = path.join(root, 'fixtures/krita-5.3.4.png');
  await page.locator('#layer-file').setInputFiles(png); await idle(); assert.equal(await page.locator('#count').innerText(), '8 层');
  assert.equal(await page.locator('#selected-size').innerText(), '480 × 360 像素');
  await page.locator('#replace-layer').click();
  await page.locator('#layer-file').setInputFiles(path.join(root, 'web/assets/capitole-preview.png')); await idle();
  assert.equal(await page.locator('#selected-size').innerText(), '1000 × 1000 像素');
  const countBeforeBad = await page.locator('#count').innerText();
  await page.locator('#layer-file').setInputFiles({ name: 'broken.png', mimeType: 'image/png', buffer: Buffer.from('not a png') }); await idle();
  assert.equal(await page.locator('#count').innerText(), countBeforeBad);
  assert.ok((await page.locator('#status').innerText()).length > 0);
  const layerDownload = page.waitForEvent('download'); await page.locator('#layer-png').click();
  const layerFile = await layerDownload; await layerFile.saveAs(path.join(temp, 'layer.png')); await idle();
  assert.ok(fs.statSync(path.join(temp, 'layer.png')).size > 1000);
  try {
    const [zipDownload] = await Promise.all([
      page.waitForEvent('download', { timeout: 90000 }),
      page.locator('#all-layers').click(),
    ]);
    await zipDownload.saveAs(path.join(temp, 'layers.zip')); await idle();
  } catch (error) {
    throw new Error('Batch layer export failed. Workbench status: ' + await page.locator('#status').innerText(), { cause: error });
  }
  try {
    const [save] = await Promise.all([
      page.waitForEvent('download', { timeout: 90000 }),
      page.locator('#save').click(),
    ]);
    await save.saveAs(path.join(temp, 'edited.ora')); await idle();
  } catch (error) {
    throw new Error('ORA save failed. Workbench status: ' + await page.locator('#status').innerText(), { cause: error });
  }
  const savedImage = await page.locator('#canvas').getAttribute('src');
  await page.locator('#file').setInputFiles(path.join(temp, 'edited.ora')); await idle();
  assert.equal(await page.locator('#canvas').getAttribute('src'), savedImage);
  assert.equal(await page.locator('#undo').isDisabled(), true);
  await page.locator('#file').setInputFiles({ name: 'broken.ora', mimeType: 'image/openraster', buffer: Buffer.from('broken') }); await idle();
  assert.equal(await page.locator('#canvas').getAttribute('src'), savedImage);
  // The same file and edit must agree with the public library and CLI.
  await page.locator('#file').setInputFiles(path.join(root, 'fixtures/krita-5.3.4.ora')); await idle();
  await page.locator('#name').fill('接口一致性 · 中文');
  await page.locator('#x').fill('-3'); await page.locator('#y').fill('7');
  await page.locator('#visible').check();
  await page.locator('#opacity').evaluate(el => { el.value = '0.5'; el.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.locator('#op').selectOption('svg:multiply');
  await page.locator('.apply-button').click(); await idle();
  const parityDownload = page.waitForEvent('download'); await page.locator('#png').click();
  await (await parityDownload).saveAs(path.join(temp, 'parity.png')); await idle();
  assert.deepEqual(fs.readFileSync(path.join(temp, 'parity.png')), fs.readFileSync(path.join(root, '_build/consistency/edited.png')));
  await page.locator('#sample').click();
  await page.locator('#discard-dialog button[value=discard]').click(); await idle();
  // Compatibility feedback remains visible after an edit and undo/redo.
  await page.locator('#op').selectOption('svg:plus');
  await page.locator('.apply-button').click(); await idle();
  assert.match(await page.locator('#status').innerText(), /相加模式.*W3C.*Krita/);
  await page.locator('#undo').click(); await idle();
  assert.equal((await page.locator('#status').innerText()).includes('Krita'), false);
  await page.locator('#redo').click(); await idle();
  assert.match(await page.locator('#status').innerText(), /Krita/);
  await page.locator('#undo').click(); await idle();
  await page.locator('#file').setInputFiles(path.join(root, 'fixtures/gradient16.ora'));
  await idle();
  assert.equal(await page.locator('#bit-depth').innerText(), '16 位 sRGB');
  assert.equal(await page.locator('#name').inputValue(), 'Light');
  assert.match(await page.locator('#selected-size').innerText(), /16 位/);
  await page.locator('#x').fill('9');
  await page.locator('#y').fill('6');
  await page.locator('#opacity').evaluate(el => { el.value = '0.5'; el.dispatchEvent(new Event('input', { bubbles: true })); });
  await page.locator('.apply-button').click(); await idle();
  const save16 = page.waitForEvent('download');
  await page.locator('#save').click();
  const browserOra = path.join(temp, 'edited16.ora');
  await (await save16).saveAs(browserOra); await idle();
  execFileSync(process.env.PYTHON || 'python', ['scripts/check_rgba16.py', '--browser-output', browserOra], {cwd: root, stdio: 'inherit'});
  const png16 = page.waitForEvent('download');
  await page.locator('#png').click();
  const browserPng = path.join(temp, 'edited16.png');
  await (await png16).saveAs(browserPng); await idle();
  assert.deepEqual(fs.readFileSync(browserPng), fs.readFileSync(path.join(root, '_build/rgba16/edited.png')));
  await page.locator('#file').setInputFiles(browserOra); await idle();
  assert.equal(await page.locator('#x').inputValue(), '9');
  assert.equal(await page.locator('#bit-depth').innerText(), '16 位 sRGB');
  // Standalone formats use the same editor, including a true 16-bit replacement.
  await page.locator('#add-layer').click();
  await page.locator('#layer-file').setInputFiles(path.join(root, '_build/image-import/oriented.jpg'));
  await idle();
  assert.equal(await page.locator('#name').inputValue(), 'oriented');
  assert.match(await page.locator('#selected-size').innerText(), /12 × 16/);
  await page.locator('#replace-layer').click();
  await page.locator('#layer-file').setInputFiles(path.join(root, '_build/image-import/multi.tiff'));
  await idle();
  assert.equal(await page.locator('#name').inputValue(), 'oriented');
  assert.match(await page.locator('#selected-size').innerText(), /16 × 12.*16 位/);
  await page.locator('#undo').click(); await idle();
  assert.match(await page.locator('#selected-size').innerText(), /12 × 16/);
  const mixedFixture = path.join(root, '_build/svg-roundtrip/input.ora');
  await page.locator('#file').setInputFiles(mixedFixture);
  await page.locator('#discard-dialog button[value=discard]').click(); await idle();
  assert.equal(await page.locator('#name').inputValue(), 'Vector');
  await page.locator('#x').fill('2');
  await page.locator('#opacity').evaluate(el => {
    el.value = '0.5';
    el.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await page.locator('.apply-button').click(); await idle();
  const mixedDownload = page.waitForEvent('download');
  await page.locator('#save').click();
  const mixedOutput = path.join(temp, 'mixed.ora');
  await (await mixedDownload).saveAs(mixedOutput); await idle();
  assert.deepEqual(fs.readFileSync(mixedOutput), fs.readFileSync(path.join(root, '_build/svg-roundtrip/edited.ora')));
  await page.locator('#file').setInputFiles(mixedOutput); await idle();
  assert.equal(await page.locator('#x').inputValue(), '2');
  assert.equal(await page.locator('#bit-depth').innerText(), '16 位 sRGB');
  const fontBytes = fs.readFileSync(path.join(root, 'fixtures/ora-test.ttf')).toString('base64');
  const referenceMask = await page.evaluate(async fontBytes => {
    const face = new FontFace('OraTestReference', 'url(data:font/ttf;base64,' + fontBytes + ')');
    document.fonts.add(await face.load());
    const canvas = document.createElement('canvas');
    canvas.width = 16;
    canvas.height = 8;
    const ctx = canvas.getContext('2d');
    ctx.font = '8px OraTestReference';
    ctx.fillText('A中', 0, 8);
    return Array.from(ctx.getImageData(0, 0, 16, 8).data).filter((_, i) => i % 4 === 3);
  }, fontBytes);
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 16; x++) {
      const painted = (x < 4 && y >= 4) || (x >= 8 && x < 14 && y >= 2);
      assert.equal(referenceMask[y * 16 + x] >= 128, painted, "Chromium glyph coverage at " + x + "," + y);
    }
  }
  for (const variant of [
    'font', 'font-spans', 'font-stylesheet', 'font-stylesheet-pi',
    'font-css-cascade', 'font-svg-resource', 'font-path', 'font-path-resource', 'font-position-list', 'font-position-spans', 'font-position-cluster',
    'font-centered-spans', 'font-length-spacing', 'font-length-glyphs', 'font-letter-spacing',
    'font-weight', 'font-style', 'font-alternate-sources', 'font-relative-size', 'font-percentage-position', 'font-svg-outline',
    'font-svg-outline-resource', 'font-rtl', 'font-tref', 'font-tref-resource',
    'font-vertical', 'font-vertical-centered', 'font-vertical-mixed', 'font-vertical-spans', 'font-vertical-substitution', 'font-rtl-spans', 'font-rtl-embed', 'font-rtl-chunks', 'font-rtl-offsets', 'font-bidi-override', 'font-glyph-fallback', 'font-glyph-fallback-all', 'font-unavailable-primary',
    'sans-serif-generic', 'serif-generic', 'nested-image', 'nested-image-views', 'nested-image-transform', 'nested-image-viewport',
  ]) {
    const fixtureDir = path.join(root, '_build/svg-roundtrip');
    const layerName = variant.startsWith('nested-image') ? 'Vector' : 'Text';
    await page.locator('#file').setInputFiles(path.join(fixtureDir, variant + '-input.ora'));
    await idle();
    assert.equal(await page.locator('#name').inputValue(), layerName);
    await page.getByText('Raster', { exact: true }).click();
    await page.locator('#x').fill('1');
    await page.locator('.apply-button').click(); await idle();
    const fontDownload = page.waitForEvent('download');
    await page.locator('#save').click();
    const fontOutput = path.join(temp, variant + '.ora');
    await (await fontDownload).saveAs(fontOutput); await idle();
    assert.deepEqual(fs.readFileSync(fontOutput), fs.readFileSync(path.join(fixtureDir, variant + '-edited.ora')));
    await page.locator('#file').setInputFiles(fontOutput); await idle();
    assert.equal(await page.locator('#name').inputValue(), layerName);
  }
  // Open the SVG resource as its own document so Chromium independently loads
  // its stylesheet, font and PNG, which image embeds restrict.
  const reference = await browser.newPage({ viewport: { width: 30, height: 15 } });
  const referenceArchive = path.join(root, '_build/svg-roundtrip/nested-image-transform-edited.ora');
  const mimeTypes = { svg: 'image/svg+xml', css: 'text/css', png: 'image/png', ttf: 'font/ttf' };
  const requested = new Set();
  await reference.route('http://ora-reference.test/**', async route => {
    const name = new URL(route.request().url()).pathname.slice(1);
    const contentType = mimeTypes[name.split('.').at(-1)];
    if (!contentType || !name.startsWith('data/')) return route.abort();
    const body = execFileSync(process.env.PYTHON || 'python', [
      '-c', 'import sys, zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]))',
      referenceArchive, name,
    ]);
    requested.add(name);
    await route.fulfill({ contentType, body });
  });
  for (const [fragment, rgb, opaque] of [
    ['left', [255, 0, 0], false],
    ['svgView(viewBox(1,0,1,1))', [0, 255, 0], true],
    ['svgView(viewBox(0,0,1,1);transform(translate(-1,0)))', [0, 255, 0], true],
  ]) {
    await reference.goto('http://ora-reference.test/data/icons/sub.svg#' + fragment, { waitUntil: 'networkidle' });
    const screenshot = await reference.screenshot({ clip: { x: 0, y: 0, width: 1, height: 1 }, omitBackground: true });
    const actual = JSON.parse(execFileSync(process.env.PYTHON || 'python', [
      '-c', 'from PIL import Image; import io, sys, json; print(json.dumps(Image.open(io.BytesIO(sys.stdin.buffer.read())).convert("RGBA").getpixel((0, 0))))',
    ], { input: screenshot, encoding: 'utf8' }));
    assert.deepEqual(actual.slice(0, 3), rgb, fragment);
    // Chromium hints the tiny font to a pixel grid. Check significant coverage
    // for the glyph and exact opacity for the full-size PNG pixel.
    if (opaque) assert.equal(actual[3], 255, fragment);
    else assert.ok(actual[3] >= 128, fragment);
  }
  for (const name of ['data/icons/styles/paint.css', 'data/font/press.ttf', 'data/icons/pixel.png']) {
    assert.ok(requested.has(name), name);
  }
  await reference.close();
  const nestedViews = path.join(root, '_build/svg-roundtrip');
  for (const variant of ['nested-image-views', 'nested-image-viewport']) {
    await page.locator('#file').setInputFiles(path.join(nestedViews, variant + '-input.ora'));
    await idle();
    assert.equal(await page.locator('#name').inputValue(), 'Vector');
    await page.locator('#x').fill('1');
    await page.locator('#opacity').evaluate(el => {
      el.value = '0.5';
      el.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.locator('.apply-button').click();
    await idle();
    const viewDownload = page.waitForEvent('download');
    await page.locator('#save').click();
    const viewOutput = path.join(temp, variant + '-vector.ora');
    await (await viewDownload).saveAs(viewOutput);
    assert.deepEqual(fs.readFileSync(viewOutput), fs.readFileSync(path.join(nestedViews, variant + '-vector-edited.ora')));
    await page.locator('#file').setInputFiles(viewOutput);
    await idle();
    assert.equal(await page.locator('#name').inputValue(), 'Vector');
    assert.equal(await page.locator('#x').inputValue(), '1');
  }
  for (const variant of ['icc-parametric', 'mab-xyz', 'mpet-curves', 'mpet-fallback', 'mpet-rgba16', 'cicp-p3', 'chrm-p3']) {
    const fixtures = path.join(root, '_build/rgba16');
    await page.locator('#file').setInputFiles(path.join(fixtures, variant + '.ora')); await idle();
    assert.equal(await page.locator('#name').inputValue(), 'Profiled');
    await page.locator('#x').fill('1');
    await page.locator('.apply-button').click(); await idle();
    const download = page.waitForEvent('download');
    await page.locator('#save').click();
    const output = path.join(temp, variant + '.ora');
    await (await download).saveAs(output); await idle();
    assert.deepEqual(fs.readFileSync(output), fs.readFileSync(path.join(fixtures, variant + '-edited.ora')));
    await page.locator('#file').setInputFiles(output); await idle();
    assert.equal(await page.locator('#x').inputValue(), '1');
  }
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.setViewportSize({ width: 1500, height: 1000 });
  fs.mkdirSync(path.join(root, '_build/editor-test'), { recursive: true });
  await page.screenshot({ path: path.join(root, '_build/editor-test/workbench.png') });
  assert.deepEqual(errors, []);
  console.log(`PASS: real browser; pixels update before pointerup (${latency} ms initial response), one-step undo, redo/keyboard, zoom persistence, locks, duplicate/move, PNG import/replace/extract, ORA save/reopen, error recovery and mobile width`);
} finally {
  if (browser) await browser.close();
  server.kill();
  fs.rmSync(temp, { recursive: true, force: true });
}
