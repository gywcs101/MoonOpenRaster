import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../../', import.meta.url));
const catalog = JSON.parse(fs.readFileSync(path.join(root, 'web/assets/sample-catalog.json'), 'utf8'));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'moonora-guides-'));
const server = spawn(process.env.PYTHON || 'python', ['scripts/serve_web.py', '--no-build', '--port', '18766'], { cwd: root, stdio: 'pipe' });
let browser;
try {
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('Preview server timeout')), 15000);
    server.stdout.on('data', data => { if (String(data).includes('http://')) { clearTimeout(timer); resolve(); } });
    server.on('exit', code => { clearTimeout(timer); reject(Error('Preview server exited: ' + code)); });
  });
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1500, height: 1050 }, acceptDownloads: true });
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.goto('http://127.0.0.1:18766/');
  const idle = () => page.waitForFunction(() => !document.body.classList.contains('is-busy') && document.querySelector('#loading').hidden);
  await idle();
  await page.locator('#browse-samples').click();
  assert.equal(await page.locator('.sample-card').count(), 4);
  fs.mkdirSync(path.join(root, '_build/editor-test'), { recursive: true });
  await page.screenshot({ path: path.join(root, '_build/editor-test/sample-gallery.png') });
  await page.locator('[data-sample=capitole] [data-mode=practice]').click(); await idle();
  assert.equal(await page.locator('#practice-progress').innerText(), '0 / 4 已完成');
  await page.locator('#guide-locate').click();
  assert.equal(await page.locator('#name').inputValue(), '线稿');
  const position = catalog.samples[0].practice.steps[0].checks[0].expected;
  await page.locator('#x').fill(String(position.x)); await page.locator('#y').fill(String(position.y));
  await page.locator('.apply-button').click(); await idle();
  assert.equal(await page.locator('#practice-progress').innerText(), '1 / 4 已完成');
  await page.locator('#undo').click(); await idle(); assert.equal(await page.locator('#practice-progress').innerText(), '0 / 4 已完成');
  await page.locator('#redo').click(); await idle(); assert.equal(await page.locator('#practice-progress').innerText(), '1 / 4 已完成');
  await page.locator('.eye-button[aria-label="隐藏草稿"]').click(); await idle();
  assert.equal(await page.locator('#practice-progress').innerText(), '2 / 4 已完成');
  await page.locator('#guide-action').click(); await idle();
  assert.equal(await page.locator('#practice-progress').innerText(), '3 / 4 已完成');
  async function exportGoal(sample) {
    const downloaded = page.waitForEvent('download'); await page.locator('#guide-action').click();
    const target = path.join(temp, sample.id + '.png'); await (await downloaded).saveAs(target); await idle();
    assert.equal(await page.locator('#practice-progress').innerText(), '4 / 4 已完成');
    assert.deepEqual(fs.readFileSync(target), fs.readFileSync(path.join(root, 'web', sample.practice.goal)));
  }
  await exportGoal(catalog.samples[0]);
  await page.locator('#view-goal').click(); assert.equal(await page.locator('#goal-dialog').isVisible(), true);
  await page.locator('#goal-close').click();
  // Changing a completed task invalidates it and the export step. Undo restores both.
  await page.locator('#guide-steps button').first().click();
  await page.locator('.layer-select').filter({ hasText: /^线稿/ }).click();
  await page.locator('#x').fill(String(position.x + 12)); await page.locator('.apply-button').click(); await idle();
  assert.equal(await page.locator('#practice-progress').innerText(), '2 / 4 已完成');
  await page.locator('#undo').click(); await idle(); assert.equal(await page.locator('#practice-progress').innerText(), '4 / 4 已完成');
  await page.locator('#browse-samples').click();
  await page.keyboard.press('Control+z');
  assert.equal(await page.locator('#practice-progress').innerText(), '4 / 4 已完成');
  await page.locator('[data-sample=bloom] [data-mode=original]').click();
  await page.locator('#discard-dialog').waitFor({ state: 'visible' });
  await page.locator('#discard-dialog [value=cancel]').click(); await idle();
  assert.equal(await page.locator('#sample-gallery').isVisible(), true);
  assert.match(await page.locator('#practice-title').innerText(), /自由之都/);
  await page.locator('[data-sample=bloom] [data-mode=original]').click();
  await page.locator('#discard-dialog [value=discard]').click(); await idle();
  assert.equal(await page.locator('#practice-panel').isVisible(), false);
  assert.equal(await page.locator('#practice-invite').isVisible(), true);
  await page.locator('#start-practice').click(); await idle();
  for (const sample of catalog.samples.slice(1)) {
    if (sample.id !== 'bloom') {
      await page.locator('#browse-samples').click();
      await page.locator(`[data-sample=${sample.id}] [data-mode=practice]`).click();
      await page.locator('#discard-dialog [value=discard]').click(); await idle();
    }
    assert.equal(await page.locator('#practice-progress').innerText(), '0 / 4 已完成');
    for (let attempt = 0; attempt < 8 && await page.locator('#practice-progress').innerText() !== '3 / 4 已完成'; attempt++) {
      await page.locator('#guide-action').click(); await idle();
    }
    assert.equal(await page.locator('#practice-progress').innerText(), '3 / 4 已完成');
    await exportGoal(sample);
    console.log('PASS: guided browser practice and exact downloaded result:', sample.title);
  }
  await page.screenshot({ path: path.join(root, '_build/editor-test/guided-practice.png') });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.locator('#browse-samples').click();
  assert.equal(await page.locator('#sample-gallery').evaluate(el => el.scrollWidth <= el.clientWidth), true);
  await page.locator('#gallery-close').click();
  const save = page.waitForEvent('download'); await page.locator('#save').click();
  const ora = path.join(temp, 'practice.ora'); await (await save).saveAs(ora); await idle();
  const png = await page.locator('#canvas').getAttribute('src');
  await page.locator('#file').setInputFiles(ora); await idle();
  assert.equal(await page.locator('#canvas').getAttribute('src'), png);
  assert.equal(await page.locator('#practice-panel').isVisible(), false);
  assert.deepEqual(errors, []);
  console.log('PASS: gallery modes, real-state task checks, undo invalidation, replacement asset, export revision, cancel-safe sample switch, mobile layout and ORA reopen');
} finally {
  if (browser) await browser.close(); server.kill(); fs.rmSync(temp, { recursive: true, force: true });
}
