// F06 自验证：ExerciseVM 纯逻辑状态机测试
// 对 ExerciseVM 的有限状态转移、笔迹栈操作（appendStroke/undo/redo/clear）、
// canSubmit、confirm 状态机、persistDrafts 脏会话过滤做全覆盖断言。
// Mock HandwritingService + ExerciseRepository（不依赖 DB/SDK）。
// 运行：node .ralph/f06-test/test.mjs

let pass = 0, fail = 0;
const ok = (cond, msg) => { if (cond) { pass++; } else { fail++; console.error('  ✗ ' + msg); } };
const eq = (a, b, msg) => ok(JSON.stringify(a) === JSON.stringify(b), `${msg} → got ${JSON.stringify(a)} want ${JSON.stringify(b)}`);

// ===== 镜像 ExerciseVM 核心逻辑（去 ArkTS 装饰器的等价端口）=====

class ExerciseVM {
  constructor(repo, handwriting, confirmHandler, now) {
    this.repo = repo;
    this.handwriting = handwriting;
    this.confirmHandler = confirmHandler;
    this.now = now || (() => Date.now());
    this.status = 'loading';
    this.detail = undefined;
    this.attemptId = '';
    this.blanks = [];
    this.activeBlankIndex = -1;
    this.error = undefined;
  }

  async load(exerciseId) {
    this.status = 'loading';
    this.error = undefined;
    try {
      const detail = await this.repo.getExercise(exerciseId);
      this.detail = detail;
      const draft = await this.repo.createDraft(exerciseId);
      this.attemptId = draft.attemptId;
      this.blanks = detail.blanks.map(blank => this._buildBlankAttempt(detail, blank));
      this.activeBlankIndex = this.blanks.length > 0 ? 0 : -1;
      // loading 态 _recomputeStatus 会提前退出，先重置以确保能正确计算
      this.status = 'blank';
      this._recomputeStatus();
    } catch (cause) {
      this.error = { code: 'DB_QUERY_FAILED', detail: String(cause) };
      this.detail = undefined;
      this.blanks = [];
      this.activeBlankIndex = -1;
      this.status = 'broken';
    }
  }

  _buildBlankAttempt(detail, blank) {
    const widthVp = Math.min(360, Math.max(96, blank.widthEm * 16));
    const heightVp = Math.max(1, blank.lines) * 88;
    const target = { type: 'exercise-blank', ownerId: detail.id, blankKey: blank.blankKey, mode: blank.handwritingMode, canvasWidthVp: widthVp, canvasHeightVp: heightVp };
    return {
      blank,
      session: this.handwriting.begin(target),
      redoStack: [],
      strokeRecordId: '',
      widthVp,
      heightVp
    };
  }

  focusBlank(index) {
    if (index < 0 || index >= this.blanks.length) return;
    this.activeBlankIndex = index;
  }

  focusNextBlank() {
    if (this.activeBlankIndex >= 0 && this.activeBlankIndex < this.blanks.length - 1) {
      this.activeBlankIndex = this.activeBlankIndex + 1;
    }
  }

  appendStroke(stroke) {
    if (this.activeBlankIndex < 0 || this.activeBlankIndex >= this.blanks.length) return false;
    const attempt = this.blanks[this.activeBlankIndex];
    attempt.session.document.strokes.push(stroke);
    attempt.redoStack = [];
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    this._recomputeStatus();
    return true;
  }

  undo() {
    const attempt = this._currentAttempt();
    if (attempt === undefined || attempt.session.document.strokes.length === 0) return false;
    const popped = attempt.session.document.strokes.pop();
    if (popped !== undefined) attempt.redoStack.push(popped);
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    this._recomputeStatus();
    return true;
  }

  redo() {
    const attempt = this._currentAttempt();
    if (attempt === undefined || attempt.redoStack.length === 0) return false;
    const restored = attempt.redoStack.pop();
    if (restored !== undefined) attempt.session.document.strokes.push(restored);
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    this._recomputeStatus();
    return true;
  }

  clear() {
    const attempt = this._currentAttempt();
    if (attempt === undefined || attempt.session.document.strokes.length === 0) return false;
    const strokes = attempt.session.document.strokes;
    for (let i = strokes.length - 1; i >= 0; i--) attempt.redoStack.push(strokes[i]);
    attempt.session.document.strokes = [];
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    this._recomputeStatus();
    return true;
  }

  async persistDrafts() {
    for (let i = 0; i < this.blanks.length; i++) {
      const attempt = this.blanks[i];
      if (attempt.session.dirty) {
        try {
          await this.handwriting.persistDraft(attempt.session);
        } catch (cause) {
          this.error = { code: 'DB_WRITE_FAILED', detail: String(cause) };
        }
      }
    }
  }

  canSubmit() {
    for (let i = 0; i < this.blanks.length; i++) {
      if (this.blanks[i].session.document.strokes.length > 0) return true;
    }
    return false;
  }

  async confirm() {
    if (this.status === 'recognizing' || !this.canSubmit() || this.detail === undefined) return;
    await this.persistDrafts();
    const answers = [];
    for (let i = 0; i < this.blanks.length; i++) {
      const attempt = this.blanks[i];
      if (attempt.session.document.strokes.length > 0) {
        answers.push({ blankKey: attempt.blank.blankKey, recognizedText: '', strokeRecordId: attempt.strokeRecordId });
      }
    }
    this.status = 'recognizing';
    const payload = { exerciseId: this.detail.id, attemptId: this.attemptId, answers };
    try {
      await this.confirmHandler.handle(payload);
    } catch (cause) {
      this.error = { code: 'service-unavailable', detail: String(cause) };
      // recognizing 态 _recomputeStatus 会提前退出，先重置以确保能回退
      this.status = 'blank';
      this._recomputeStatus();
    }
  }

  _currentAttempt() {
    if (this.activeBlankIndex < 0 || this.activeBlankIndex >= this.blanks.length) return undefined;
    return this.blanks[this.activeBlankIndex];
  }

  _recomputeStatus() {
    if (this.status === 'recognizing' || this.status === 'loading' || this.status === 'broken') return;
    this.status = this.canSubmit() ? 'submittable' : 'blank';
  }
}

// ===== Mock 工厂 =====

let sessionCounter = 0;
function makeMockHandwriting(persistFail = false) {
  return {
    begin(target) {
      sessionCounter++;
      return {
        sessionId: `session-${sessionCounter}`,
        target,
        document: { format: 'ai.studybook.stroke', version: 1, canvas: { widthVp: target.canvasWidthVp, heightVp: target.canvasHeightVp }, strokes: [] },
        dirty: false,
        updatedAt: 0
      };
    },
    async persistDraft(session) {
      if (persistFail) throw new Error('disk-full');
      session.dirty = false;
    },
    recognize(session) {
      return { requestId: 'not-wired', result: Promise.resolve({ ok: false, requestId: 'not-wired', errorCode: 'service-unavailable', retryable: true, durationMs: 0 }), cancel: () => {} };
    }
  };
}

function makeDetail(id = 'ex1', blanks = null) {
  return {
    id,
    externalId: 'ex-ext-1',
    bookId: 'book1',
    chapterId: 'ch1',
    orderNo: 1,
    type: 'fill-blank-handwriting',
    instruction: '填写下列空格',
    prompt: { text: 'The ___ is beautiful.' },
    context: {},
    blanks: blanks || [
      { id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: ['sky'] }
    ],
    gradingOptions: { caseSensitive: false, trimWhitespace: true, collapseWhitespace: true, ignoreTerminalPunctuation: true, normalizeApostrophes: true, maxEditDistance: 0 }
  };
}

function makeRepo(detail = makeDetail(), fail = false) {
  return {
    async getExercise(id) {
      if (fail) throw new Error('not-found');
      return detail;
    },
    async createDraft(id) {
      return { attemptId: 'attempt-1', exerciseId: id, startedAt: 1000, answers: [] };
    },
    async saveGrade(attemptId, result) {}
  };
}

function makeHandler(fail = false) {
  let lastPayload = null;
  return {
    async handle(payload) {
      lastPayload = payload;
      if (fail) throw new Error('handler-failed');
    },
    getLastPayload() { return lastPayload; }
  };
}

function makeStroke(id = 's1') {
  return { id, points: [{ x: 10, y: 10, t: 0, pressure: 0.5, tiltX: 0, tiltY: 0 }, { x: 20, y: 20, t: 10, pressure: 0.5, tiltX: 0, tiltY: 0 }] };
}

// ===== 测试用例 =====

console.log('# 1. 初始态（load 前）');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  eq(vm.status, 'loading', '初始 status=loading');
  eq(vm.blanks.length, 0, '初始 blanks 为空');
  eq(vm.activeBlankIndex, -1, '初始 activeBlankIndex=-1');
  ok(vm.detail === undefined, '初始 detail 为空');
}

console.log('# 2. load 正常流');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  eq(vm.status, 'blank', 'load 后无笔迹 → blank');
  eq(vm.blanks.length, 1, 'blanks 数量=1');
  eq(vm.activeBlankIndex, 0, '首空自动聚焦 → activeBlankIndex=0');
  ok(vm.detail !== undefined, 'detail 已加载');
  eq(vm.attemptId, 'attempt-1', 'attemptId 来自 createDraft');
  // 各空已有独立会话
  ok(vm.blanks[0].session.document.strokes.length === 0, '初始会话无笔迹');
  ok(!vm.blanks[0].session.dirty, '初始会话 dirty=false');
}

console.log('# 3. load 练习不存在 → broken');
{
  const vm = new ExerciseVM(makeRepo(makeDetail(), true), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  eq(vm.status, 'broken', '加载失败 → broken');
  ok(vm.error !== undefined, 'error 已设置');
  eq(vm.blanks.length, 0, 'broken 时 blanks 为空');
  eq(vm.activeBlankIndex, -1, 'broken 时无焦点');
}

console.log('# 4. appendStroke → canSubmit=true → status=submittable');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  eq(vm.status, 'blank', 'load 后 blank');
  const appended = vm.appendStroke(makeStroke('s1'));
  ok(appended, 'appendStroke 返回 true');
  eq(vm.status, 'submittable', '有笔迹 → submittable');
  ok(vm.canSubmit(), 'canSubmit=true');
  eq(vm.blanks[0].session.document.strokes.length, 1, '空 0 有 1 笔');
  ok(vm.blanks[0].session.dirty, '会话标脏');
}

console.log('# 5. appendStroke 无焦点时拒绝');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  vm.activeBlankIndex = -1;
  const appended = vm.appendStroke(makeStroke('s1'));
  ok(!appended, '无焦点 → appendStroke 返回 false');
  ok(!vm.canSubmit(), 'canSubmit=false（无笔迹）');
  eq(vm.status, 'blank', 'status 仍为 blank');
}

console.log('# 6. undo → 笔迹移入 redoStack');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  vm.appendStroke(makeStroke('s2'));
  eq(vm.blanks[0].session.document.strokes.length, 2, '2 笔');
  const undone = vm.undo();
  ok(undone, 'undo 返回 true');
  eq(vm.blanks[0].session.document.strokes.length, 1, '撤销后 1 笔');
  eq(vm.blanks[0].redoStack.length, 1, 'redoStack 有 1 笔');
  ok(vm.blanks[0].redoStack[0].id === 's2', 'redoStack 末笔 id=s2');
  eq(vm.status, 'submittable', '仍有笔迹 → submittable');
}

console.log('# 7. undo 至 0 笔 → blank');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  vm.undo();
  eq(vm.blanks[0].session.document.strokes.length, 0, '撤销到 0 笔');
  eq(vm.status, 'blank', '无笔迹 → blank');
  ok(!vm.canSubmit(), 'canSubmit=false');
}

console.log('# 8. redo → 恢复一笔');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  vm.appendStroke(makeStroke('s2'));
  vm.undo();
  vm.undo();
  eq(vm.blanks[0].session.document.strokes.length, 0, '2 次撤销后 0 笔');
  const redone = vm.redo();
  ok(redone, 'redo 返回 true');
  eq(vm.blanks[0].session.document.strokes.length, 1, 'redo 后 1 笔');
  eq(vm.status, 'submittable', 'redo 后 submittable');
}

console.log('# 9. 新笔追加后 redo 栈清空（防止历史分叉）');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  vm.undo();
  eq(vm.blanks[0].redoStack.length, 1, 'undo 后 redoStack 有 1 笔');
  vm.appendStroke(makeStroke('s2'));
  eq(vm.blanks[0].redoStack.length, 0, '新笔追加后 redoStack 清空');
}

console.log('# 10. clear → 全部笔迹移入 redoStack（倒序，可整体 redo）');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  vm.appendStroke(makeStroke('s2'));
  vm.appendStroke(makeStroke('s3'));
  const cleared = vm.clear();
  ok(cleared, 'clear 返回 true');
  eq(vm.blanks[0].session.document.strokes.length, 0, 'clear 后 0 笔');
  eq(vm.blanks[0].redoStack.length, 3, 'redoStack 有 3 笔');
  eq(vm.status, 'blank', 'clear 后 blank');
  // redo 恢复应按原顺序（s1 先 push 入栈，最后出栈）
  vm.redo(); vm.redo(); vm.redo();
  const restored = vm.blanks[0].session.document.strokes.map(s => s.id);
  eq(restored, ['s1', 's2', 's3'], 'redo 后顺序恢复');
}

console.log('# 11. focusBlank → 切换焦点');
{
  const detail = makeDetail('ex1', [
    { id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: ['sky'] },
    { id: 'b2', blankKey: 'blank2', orderNo: 2, widthEm: 10, lines: 1, handwritingMode: 'english', displayAnswer: 'blue', acceptedAnswers: ['blue'] }
  ]);
  const vm = new ExerciseVM(makeRepo(detail), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  eq(vm.activeBlankIndex, 0, '初始聚焦首空');
  vm.focusBlank(1);
  eq(vm.activeBlankIndex, 1, '切换到第 2 空');
  vm.focusBlank(99); // 越界
  eq(vm.activeBlankIndex, 1, '越界不改变焦点');
}

console.log('# 12. focusNextBlank → 自动前进，末空不越界');
{
  const detail = makeDetail('ex1', [
    { id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: [] },
    { id: 'b2', blankKey: 'blank2', orderNo: 2, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'blue', acceptedAnswers: [] }
  ]);
  const vm = new ExerciseVM(makeRepo(detail), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  eq(vm.activeBlankIndex, 0, '初始首空');
  vm.focusNextBlank();
  eq(vm.activeBlankIndex, 1, '前进到第 2 空');
  vm.focusNextBlank();
  eq(vm.activeBlankIndex, 1, '末空不前进');
}

console.log('# 13. appendStroke 只追加到当前激活空');
{
  const detail = makeDetail('ex1', [
    { id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: [] },
    { id: 'b2', blankKey: 'blank2', orderNo: 2, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'blue', acceptedAnswers: [] }
  ]);
  const vm = new ExerciseVM(makeRepo(detail), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  // 默认焦点在 blank[0]
  vm.appendStroke(makeStroke('s1'));
  vm.focusBlank(1);
  vm.appendStroke(makeStroke('s2'));
  eq(vm.blanks[0].session.document.strokes.length, 1, 'blank[0] 有 1 笔');
  eq(vm.blanks[1].session.document.strokes.length, 1, 'blank[1] 有 1 笔');
}

console.log('# 14. persistDrafts → 只落盘脏会话');
{
  const detail = makeDetail('ex1', [
    { id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: [] },
    { id: 'b2', blankKey: 'blank2', orderNo: 2, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'blue', acceptedAnswers: [] }
  ]);
  let persistCount = 0;
  const handwriting = {
    begin: makeMockHandwriting().begin,
    async persistDraft(session) { persistCount++; session.dirty = false; },
    recognize: makeMockHandwriting().recognize
  };
  const vm = new ExerciseVM(makeRepo(detail), handwriting, makeHandler());
  await vm.load('ex1');
  // 只在 blank[0] 追加笔迹（dirty）
  vm.appendStroke(makeStroke('s1'));
  ok(vm.blanks[0].session.dirty, 'blank[0] dirty=true');
  ok(!vm.blanks[1].session.dirty, 'blank[1] dirty=false');
  await vm.persistDrafts();
  eq(persistCount, 1, '只调用 persistDraft 1 次（脏会话）');
  ok(!vm.blanks[0].session.dirty, 'blank[0] dirty 清除');
}

console.log('# 15. persistDrafts 单空失败 → 设置 error，不阻断其余空');
{
  const detail = makeDetail('ex1', [
    { id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: [] },
    { id: 'b2', blankKey: 'blank2', orderNo: 2, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'blue', acceptedAnswers: [] }
  ]);
  let persistCalls = [];
  const handwriting = {
    begin: makeMockHandwriting().begin,
    async persistDraft(session) {
      persistCalls.push(session.target.blankKey);
      if (session.target.blankKey === 'blank1') throw new Error('disk-full');
      session.dirty = false;
    },
    recognize: makeMockHandwriting().recognize
  };
  const vm = new ExerciseVM(makeRepo(detail), handwriting, makeHandler());
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));       // blank[0]
  vm.focusBlank(1);
  vm.appendStroke(makeStroke('s2'));       // blank[1]
  await vm.persistDrafts();
  ok(vm.error !== undefined, 'blank1 失败后 error 已设置');
  ok(!vm.blanks[1].session.dirty, 'blank2 成功落盘，dirty 清除');
  eq(persistCalls.length, 2, '两个脏会话都尝试落盘');
}

console.log('# 16. confirm 正常流 → status=recognizing → handler 被调用');
{
  const handler = makeHandler(false);
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), handler);
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  eq(vm.status, 'submittable', 'confirm 前 submittable');
  await vm.confirm();
  eq(vm.status, 'recognizing', 'confirm 后 recognizing');
  const payload = handler.getLastPayload();
  ok(payload !== null, 'handler 被调用');
  eq(payload.exerciseId, 'ex1', 'payload.exerciseId 正确');
  eq(payload.answers.length, 1, '1 个 answer（1 空有笔迹）');
  eq(payload.answers[0].blankKey, 'blank1', 'answer.blankKey 正确');
  eq(payload.answers[0].recognizedText, '', 'recognizedText 待 F07 补齐，初始为空串');
}

console.log('# 17. confirm handler 失败 → 回退到 submittable 并设 error');
{
  const handler = makeHandler(true);
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), handler);
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  await vm.confirm();
  eq(vm.status, 'submittable', 'handler 失败 → 回退 submittable');
  ok(vm.error !== undefined, 'error 已设置');
}

console.log('# 18. confirm 无笔迹时被忽略');
{
  const handler = makeHandler(false);
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), handler);
  await vm.load('ex1');
  eq(vm.status, 'blank', '无笔迹 → blank');
  await vm.confirm();
  eq(vm.status, 'blank', 'status 不变（confirm 被忽略）');
  eq(handler.getLastPayload(), null, 'handler 未被调用');
}

console.log('# 19. confirm 识别中防重复提交');
{
  const handler = makeHandler(false);
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), handler);
  await vm.load('ex1');
  vm.appendStroke(makeStroke('s1'));
  // 手动置 recognizing 模拟已提交
  vm.status = 'recognizing';
  await vm.confirm();
  // handler 不应被调用（防重复）
  eq(handler.getLastPayload(), null, 'recognizing 中再次 confirm 被忽略');
}

console.log('# 20. confirm 只包含有笔迹的空（多空场景）');
{
  const detail = makeDetail('ex1', [
    { id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: [] },
    { id: 'b2', blankKey: 'blank2', orderNo: 2, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'blue', acceptedAnswers: [] }
  ]);
  const handler = makeHandler(false);
  const vm = new ExerciseVM(makeRepo(detail), makeMockHandwriting(), handler);
  await vm.load('ex1');
  // 只在 blank[0] 写了字
  vm.appendStroke(makeStroke('s1'));
  await vm.confirm();
  const payload = handler.getLastPayload();
  eq(payload.answers.length, 1, '只有 1 个空有笔迹，answers.length=1');
  eq(payload.answers[0].blankKey, 'blank1', '只含有笔迹的 blank1');
}

console.log('# 21. undo/redo 无焦点时静默失败');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  vm.activeBlankIndex = -1;
  const undone = vm.undo();
  ok(!undone, 'undo 无焦点返回 false');
  const redone = vm.redo();
  ok(!redone, 'redo 无焦点返回 false');
  const cleared = vm.clear();
  ok(!cleared, 'clear 无焦点返回 false');
}

console.log('# 22. clear 无笔迹时静默忽略');
{
  const vm = new ExerciseVM(makeRepo(), makeMockHandwriting(), makeHandler());
  await vm.load('ex1');
  const cleared = vm.clear();
  ok(!cleared, '无笔迹 clear 返回 false');
  eq(vm.blanks[0].redoStack.length, 0, 'redoStack 仍为空');
}

console.log('# 23. 宽度/高度单位换算（clampBlankWidthVp / blankHeightVp 等价验证）');
{
  // widthEm=8 → raw=128vp → clamp→128（在[96,360]范围内）
  const vm1 = new ExerciseVM(makeRepo(makeDetail('ex1', [{ id: 'b1', blankKey: 'blank1', orderNo: 1, widthEm: 8, lines: 1, handwritingMode: 'english', displayAnswer: 'sky', acceptedAnswers: [] }])), makeMockHandwriting(), makeHandler());
  await vm1.load('ex1');
  eq(vm1.blanks[0].widthVp, 128, 'widthEm=8 → widthVp=128');
  eq(vm1.blanks[0].heightVp, 88, 'lines=1 → heightVp=88');

  // widthEm=3 → raw=48vp → clamp下界→96
  const vm2 = new ExerciseVM(makeRepo(makeDetail('ex2', [{ id: 'b2', blankKey: 'blank2', orderNo: 1, widthEm: 3, lines: 2, handwritingMode: 'english', displayAnswer: '', acceptedAnswers: [] }])), makeMockHandwriting(), makeHandler());
  await vm2.load('ex2');
  eq(vm2.blanks[0].widthVp, 96, 'widthEm=3 → raw 48vp → clamp 下界 96');
  eq(vm2.blanks[0].heightVp, 176, 'lines=2 → heightVp=176');

  // widthEm=40 → raw=640 → clamp上界→360
  const vm3 = new ExerciseVM(makeRepo(makeDetail('ex3', [{ id: 'b3', blankKey: 'blank3', orderNo: 1, widthEm: 40, lines: 3, handwritingMode: 'english', displayAnswer: '', acceptedAnswers: [] }])), makeMockHandwriting(), makeHandler());
  await vm3.load('ex3');
  eq(vm3.blanks[0].widthVp, 360, 'widthEm=40 → clamp 上界 360');
  eq(vm3.blanks[0].heightVp, 264, 'lines=3 → heightVp=264');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
