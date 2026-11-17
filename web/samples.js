const $ = id => document.getElementById(id);

// Completion comes from the document, not from a permanent "done" checkbox.
export function checkTask(step, nodes) {
  return (step.checks || []).every(check => {
    const matches = nodes.filter(node => node.name === check.name);
    if (matches.length !== 1) return false;
    const node = matches[0];
    if (check.type === 'image') return node.thumbnail === check.thumbnail && node.width === check.width && node.height === check.height;
    return Object.entries(check.expected).every(([property, value]) => {
      if (typeof value === 'number') {
        const range = check.ranges?.[property];
        return range ? node[property] >= range[0] - 1e-9 && node[property] <= range[1] + 1e-9 : Math.abs(node[property] - value) <= (check.tolerance || 0) + 1e-9;
      }
      return node[property] === value;
    });
  });
}

export class SampleStudio {
  constructor(callbacks) {
    this.callbacks = callbacks;
    this.samples = [];
    this.active = null;
    this.focusIndex = null;
    this.exportRevision = null;
    $('browse-samples').onclick = () => this.openGallery();
    $('gallery-close').onclick = () => $('sample-gallery').close();
    $('goal-close').onclick = () => $('goal-dialog').close();
    $('start-practice').onclick = () => callbacks.run(() => this.switchTo(this.active.sample, 'practice'));
    $('restart-practice').onclick = () => callbacks.run(() => this.reload());
    $('view-goal').onclick = () => {
      $('goal-start').src = this.active.sample.practice.start;
      $('goal-result').src = this.active.sample.practice.goal;
      $('goal-heading').textContent = this.active.sample.title + ' · 练习前后';
      $('goal-dialog').showModal();
    };
    $('guide-locate').onclick = () => {
      const step = this.currentStep();
      const check = this.pendingCheck(step) || step.checks?.[0];
      const node = check && callbacks.getNodes().find(n => n.name === check.name);
      if (node) callbacks.select(node);
    };
    $('guide-action').onclick = () => {
      const step = this.currentStep();
      if (step.type === 'export' || this.completion().every(Boolean)) return callbacks.exportPNG();
      const check = this.pendingCheck(step);
      if (!check) { this.focusIndex = null; this.refresh(); return; }
      const node = callbacks.getNodes().find(n => n.name === check.name);
      if (!node) return;
      callbacks.run(async () => {
        callbacks.select(node);
        if (check.type === 'image') {
          const response = await fetch(check.asset);
          if (!response.ok) throw Error('练习素材读取失败，请重新启动服务。');
          await callbacks.replace(node, new File([await response.blob()], '原稿背景.png', { type: 'image/png' }));
        } else await callbacks.edit(node, check.expected);
      });
    };
  }

  async init() {
    const response = await fetch('assets/sample-catalog.json');
    if (!response.ok) throw Error('样例目录读取失败，请重新启动服务。');
    this.samples = (await response.json()).samples;
    this.buildGallery();
  }

  openGallery() {
    if (!this.callbacks.isBusy() && this.samples.length && !$('sample-gallery').open) $('sample-gallery').showModal();
  }

  buildGallery() {
    const grid = $('sample-grid'); grid.replaceChildren();
    for (const sample of this.samples) {
      const card = document.createElement('article'); card.className = 'sample-card'; card.dataset.sample = sample.id;
      const image = document.createElement('img'); image.src = sample.cover; image.alt = sample.title + '的原稿预览'; image.loading = 'lazy';
      const info = document.createElement('div'); info.className = 'sample-card-info';
      const meta = document.createElement('span'); meta.className = 'sample-meta'; meta.textContent = `${sample.layerCount} 个绘画层 · ${sample.width} × ${sample.height}`;
      const title = document.createElement('h3'); title.textContent = sample.title;
      const text = document.createElement('p'); text.textContent = sample.subtitle;
      const actions = document.createElement('div'); actions.className = 'sample-card-actions';
      for (const [label, mode] of [['查看原稿', 'original'], ['开始练习', 'practice']]) {
        const button = document.createElement('button'); button.type = 'button'; button.textContent = label; button.dataset.mode = mode;
        if (mode === 'practice') button.className = 'primary';
        button.onclick = () => this.callbacks.run(async () => {
          if (await this.switchTo(sample, mode)) $('sample-gallery').close();
        });
        actions.append(button);
      }
      const source = document.createElement('a'); source.href = sample.source; source.target = '_blank'; source.rel = 'noopener'; source.textContent = 'David Revoy · 来源与授权'; source.className = 'sample-credit';
      info.append(meta, title, text, actions, source); card.append(image, info); grid.append(card);
    }
  }

  async allowSwitch() {
    if (!this.callbacks.isDirty()) return true;
    const dialog = $('discard-dialog'); dialog.returnValue = 'cancel';
    return new Promise(resolve => {
      dialog.addEventListener('close', () => resolve(dialog.returnValue === 'discard'), { once: true });
      dialog.showModal();
    });
  }

  async switchTo(sample, mode, initial = false) {
    if (!initial && !await this.allowSwitch()) return false;
    await this.callbacks.load(sample, mode);
    return true;
  }

  async reload() {
    return this.switchTo(this.active?.sample || this.samples[0], this.active?.mode || 'original');
  }

  activate(sample, mode) {
    this.active = { sample, mode }; this.focusIndex = null; this.exportRevision = null;
  }

  clear() { this.active = null; this.focusIndex = null; this.exportRevision = null; }

  recordExport(revision) { this.exportRevision = revision; this.refresh(); }

  completion() {
    const steps = this.active.sample.practice.steps;
    const nodes = this.callbacks.getNodes();
    const editsDone = steps.filter(s => s.type !== 'export').every(s => checkTask(s, nodes));
    return steps.map(step => step.type === 'export'
      ? editsDone && this.exportRevision === this.callbacks.getState()?.revision
      : checkTask(step, nodes));
  }

  currentIndex() {
    const done = this.completion();
    return this.focusIndex ?? Math.max(0, done.findIndex(value => !value) === -1 ? done.length - 1 : done.findIndex(value => !value));
  }

  currentStep() { return this.active.sample.practice.steps[this.currentIndex()]; }

  pendingCheck(step) {
    return step.checks?.find(check => !checkTask({ checks: [check] }, this.callbacks.getNodes()));
  }

  refresh() {
    const busy = this.callbacks.isBusy();
    $('browse-samples').disabled = busy || !this.samples.length;
    for (const button of $('sample-grid').querySelectorAll('button')) button.disabled = busy;
    $('practice-invite').hidden = !this.active || this.active.mode !== 'original';
    $('practice-panel').hidden = !this.active || this.active.mode !== 'practice';
    $('start-practice').disabled = busy;
    if (!this.active) return;
    const { sample, mode } = this.active;
    $('invite-text').textContent = sample.subtitle + '，用 4 步做一次小改稿。';
    if (mode !== 'practice') return;
    const done = this.completion(), index = this.currentIndex(), step = sample.practice.steps[index];
    $('practice-title').textContent = sample.title + ' · 动手练习';
    $('practice-progress').textContent = `${done.filter(Boolean).length} / ${done.length} 已完成`;
    const nav = $('guide-steps'); nav.replaceChildren();
    sample.practice.steps.forEach((task, i) => {
      const button = document.createElement('button'); button.type = 'button';
      button.textContent = (done[i] ? '✓ ' : `${i + 1} `) + task.title;
      button.className = done[i] ? 'is-complete' : '';
      button.setAttribute('aria-current', String(i === index));
      button.onclick = () => { this.focusIndex = i; this.refresh(); };
      nav.append(button);
    });
    const check = this.pendingCheck(step);
    const missing = check && !this.callbacks.getNodes().some(n => n.name === check.name);
    const allDone = done.every(Boolean);
    $('guide-title').textContent = allDone ? '已完成，作品已导出' : step.title;
    $('guide-text').textContent = allDone ? '可以继续自由调整；改动后再导出，即可得到新的版本。也可以从样例库开始下一幅。' : missing ? `找不到“${check.name}”：它可能被删除或改名了。可撤销修改，或点击“重新练习”。` : step.text;
    const locateCheck = check || step.checks?.[0];
    $('guide-locate').hidden = !locateCheck || missing;
    $('guide-locate').textContent = locateCheck ? '定位“' + locateCheck.name + '”' : '定位图层';
    $('guide-locate').disabled = busy;
    $('guide-action').textContent = allDone ? '再次导出 PNG' : step.type === 'export' ? '导出 PNG' : !check ? '继续下一步' : step.suggestion || '应用参考值';
    $('guide-action').disabled = busy || missing || (step.type === 'export' && !done.slice(0, -1).every(Boolean));
    const download = $('guide-asset'); download.hidden = !check?.asset;
    if (check?.asset) { download.href = check.asset; download.download = '原稿白底.png'; }
    $('restart-practice').disabled = busy;
  }
}
