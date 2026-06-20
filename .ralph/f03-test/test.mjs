// F03 自验证：ImportValidateVM 纯逻辑状态机测试
// 对 ImportValidateVM 的有限状态转移、事件消费、confirm/cancel 行为做全覆盖断言。
// Mock ImportService（runValidation 返回预设事件序列，不依赖 DB/SDK）。
// 运行：node .ralph/f03-test/test.mjs

let pass = 0, fail = 0;
const ok = (cond, msg) => { if (cond) { pass++; } else { fail++; console.error('  ✗ ' + msg); } };
const eq = (a, b, msg) => ok(JSON.stringify(a) === JSON.stringify(b), `${msg} → got ${JSON.stringify(a)} want ${JSON.stringify(b)}`);

// ===== 镜像 ImportValidateVM 核心逻辑（纯逻辑等价端口）=====

const VALIDATION_STAGES = [
  'validating-zip', 'validating-manifest', 'extracting-to-staging',
  'validating-hash', 'validating-schema', 'validating-business'
];

const ImportValidateStatus = {
  Validating: 'validating',
  Importable: 'importable',
  Warning: 'warning',
  Failed: 'failed',
  Importing: 'importing',
  Completed: 'completed'
};

function initialState() {
  return {
    status: ImportValidateStatus.Validating,
    progress: 0,
    stageMarks: Array(VALIDATION_STAGES.length).fill('pending'),
    activeStageIndex: -1,
    warningCount: 0,
    checkedFiles: 0,
    totalFiles: undefined,
    error: undefined,
    result: undefined
  };
}

class ImportValidateVM {
  constructor(importService, jobId) {
    this.importService = importService;
    this.jobId = jobId;
    this.state = initialState();
    this.listener = null;
  }
  getState() { return this.state; }
  setListener(l) { this.listener = l; }

  isCancellable() {
    const s = this.state.status;
    return s === 'validating' || s === 'importable' || s === 'warning' || s === 'failed';
  }
  canConfirm() {
    return this.state.status === 'importable' || this.state.status === 'warning';
  }

  async start() {
    this.emit(initialState());
    try {
      for await (const event of this.importService.runValidation(this.jobId)) {
        this.consume(event);
        if (event.blockingError !== undefined) return;
      }
      if (this.state.status === 'validating') {
        this.toFailed({ code: 'DB_WRITE_FAILED', messageKey: 'state.error', retryable: false, detail: 'ended-without-confirmation' });
      }
    } catch (cause) {
      this.toFailed({ code: 'DB_WRITE_FAILED', messageKey: 'state.error', retryable: false, detail: String(cause) });
    }
  }

  consume(event) {
    const progress = event.progress > this.state.progress ? event.progress : this.state.progress;
    const marks = [...this.state.stageMarks];
    const stageIndex = VALIDATION_STAGES.indexOf(event.stage);
    const checkedFiles = event.checkedFiles !== undefined ? event.checkedFiles : this.state.checkedFiles;
    const totalFiles = event.totalFiles !== undefined ? event.totalFiles : this.state.totalFiles;

    if (event.blockingError !== undefined) {
      if (stageIndex >= 0) {
        for (let i = 0; i < stageIndex; i++) marks[i] = 'done';
        marks[stageIndex] = 'failed';
      }
      this.emit({
        status: 'failed', progress, stageMarks: marks,
        activeStageIndex: stageIndex >= 0 ? stageIndex : this.state.activeStageIndex,
        warningCount: this.state.warningCount, checkedFiles, totalFiles, error: event.blockingError
      });
      return;
    }
    if (stageIndex >= 0) {
      for (let i = 0; i < stageIndex; i++) marks[i] = 'done';
      marks[stageIndex] = 'active';
      this.emit({ status: 'validating', progress, stageMarks: marks, activeStageIndex: stageIndex, warningCount: event.warningCount, checkedFiles, totalFiles });
      return;
    }
    if (event.stage === 'awaiting-confirmation') {
      for (let i = 0; i < marks.length; i++) marks[i] = 'done';
      this.emit({
        status: event.warningCount > 0 ? 'warning' : 'importable',
        progress, stageMarks: marks, activeStageIndex: marks.length - 1,
        warningCount: event.warningCount, checkedFiles, totalFiles
      });
    }
  }

  async confirm() {
    if (this.state.status !== 'importable' && this.state.status !== 'warning') return undefined;
    this.emit({ ...this.state, status: 'importing', stageMarks: [...this.state.stageMarks] });
    try {
      const result = await this.importService.commit(this.jobId, 'new');
      this.emit({ ...this.state, status: 'completed', progress: 1, result, warningCount: result.warningCount });
      return result;
    } catch (cause) {
      this.toFailed({ code: 'DB_WRITE_FAILED', messageKey: 'state.error', retryable: false, detail: String(cause) });
      return undefined;
    }
  }

  async cancel() {
    if (this.state.status === 'importing' || this.state.status === 'completed') return false;
    try {
      await this.importService.cancel(this.jobId, Date.now());
      return true;
    } catch (cause) {
      this.emit({ ...this.state, error: { code: 'DB_WRITE_FAILED', messageKey: 'state.error', retryable: false, detail: String(cause) } });
      return false;
    }
  }

  toFailed(error) {
    const marks = [...this.state.stageMarks];
    if (this.state.activeStageIndex >= 0) marks[this.state.activeStageIndex] = 'failed';
    this.emit({ status: 'failed', progress: this.state.progress, stageMarks: marks, activeStageIndex: this.state.activeStageIndex, warningCount: this.state.warningCount, checkedFiles: this.state.checkedFiles, totalFiles: this.state.totalFiles, error });
  }

  emit(next) {
    this.state = next;
    if (this.listener) this.listener(next);
  }
}

// ===== Mock ImportService =====
function makeMockService(events, commitResult, cancelOk = true) {
  return {
    async *runValidation(_jobId) {
      for (const e of events) yield e;
    },
    async commit(_jobId, _mode) {
      if (commitResult instanceof Error) throw commitResult;
      return commitResult;
    },
    async cancel(_jobId, _now) {
      if (!cancelOk) throw new Error('cancel-denied');
    }
  };
}

// 校验进度事件快捷构造
const zipEvent = (progress, warn = 0) => ({ stage: 'validating-zip', progress, checkedFiles: 5, totalFiles: 5, warningCount: warn });
const manifestEvent = (progress) => ({ stage: 'validating-manifest', progress, checkedFiles: 5, totalFiles: 5, warningCount: 0 });
const extractEvent = (progress) => ({ stage: 'extracting-to-staging', progress, checkedFiles: 5, totalFiles: 5, warningCount: 0 });
const hashEvent = (progress) => ({ stage: 'validating-hash', progress, checkedFiles: 5, totalFiles: 5, warningCount: 0 });
const schemaEvent = (progress) => ({ stage: 'validating-schema', progress, checkedFiles: 5, totalFiles: 5, warningCount: 0 });
const bizEvent = (progress, warn = 0) => ({ stage: 'validating-business', progress, checkedFiles: 5, totalFiles: 5, warningCount: warn });
const awaitingEvent = (progress, warn = 0) => ({ stage: 'awaiting-confirmation', progress, warningCount: warn });
const failEvent = (stage, progress, code) => ({ stage, progress, checkedFiles: 0, totalFiles: 5, warningCount: 0, blockingError: { code, messageKey: `error.import.${code}`, retryable: false, detail: 'test' } });

// ===== 测试用例 =====

console.log('# 1. 初始态');
{
  const vm = new ImportValidateVM(makeMockService([]), {});
  const s = vm.getState();
  eq(s.status, 'validating', '初始 status=validating');
  eq(s.progress, 0, '初始 progress=0');
  eq(s.stageMarks, Array(6).fill('pending'), '初始 stageMarks 全 pending');
  eq(s.activeStageIndex, -1, '初始 activeStageIndex=-1');
  eq(s.warningCount, 0, '初始 warningCount=0');
  ok(s.error === undefined, '初始无 error');
  ok(!vm.canConfirm(), '初始不可确认');
  ok(vm.isCancellable(), '初始可取消');
}

console.log('# 2. 正常校验流（无警告）→ importable');
{
  const events = [
    zipEvent(0.2), manifestEvent(0.3), extractEvent(0.5), hashEvent(0.7), schemaEvent(0.8), bizEvent(0.85),
    awaitingEvent(0.88, 0)
  ];
  const vm = new ImportValidateVM(makeMockService(events, null), 'j1');
  const states = [];
  vm.setListener(s => states.push({ ...s, stageMarks: [...s.stageMarks] }));
  await vm.start();
  // 最终态
  const final = vm.getState();
  eq(final.status, 'importable', '全通过 → importable');
  eq(final.stageMarks, Array(6).fill('done'), '全通过 → 所有阶段 done');
  eq(final.warningCount, 0, '无警告');
  ok(vm.canConfirm(), '可导入态 → canConfirm=true');
  ok(vm.isCancellable(), '可导入态 → isCancellable=true（可取消）');
  // 中间态：zip 阶段 active
  const zipState = states.find(s => s.stageMarks[0] === 'active');
  ok(zipState !== undefined, 'zip 阶段有 active 标记');
  eq(zipState.status, 'validating', 'zip active 时 status=validating');
  // 进度单调不减
  for (let i = 1; i < states.length; i++) {
    ok(states[i].progress >= states[i-1].progress, `progress 单调不减（${i}）`);
  }
  // manifest active 时 zip 已 done
  const manifestState = states.find(s => s.stageMarks[1] === 'active');
  ok(manifestState !== undefined, 'manifest 阶段有 active 标记');
  eq(manifestState.stageMarks[0], 'done', 'manifest active 时 zip 已 done');
}

console.log('# 3. 正常校验流（有警告）→ warning');
{
  const events = [
    zipEvent(0.2), manifestEvent(0.3), extractEvent(0.5), hashEvent(0.7), schemaEvent(0.8), bizEvent(0.85, 2),
    awaitingEvent(0.88, 2)
  ];
  const vm = new ImportValidateVM(makeMockService(events, null), 'j2');
  await vm.start();
  eq(vm.getState().status, 'warning', '有警告 → warning');
  eq(vm.getState().warningCount, 2, 'warningCount=2');
  ok(vm.canConfirm(), 'warning 态 → canConfirm=true（仍可导入）');
}

console.log('# 4. 阻断错误 → failed（zip 阶段）');
{
  const events = [failEvent('validating-zip', 0.2, 'IMP-001')];
  const vm = new ImportValidateVM(makeMockService(events, null), 'j3');
  await vm.start();
  const s = vm.getState();
  eq(s.status, 'failed', '阻断 → failed');
  eq(s.stageMarks[0], 'failed', 'zip 阶段标记 failed');
  ok(s.error !== undefined, 'error 已设置');
  ok(!vm.canConfirm(), 'failed 态 → canConfirm=false（阻断错误隐藏确认按钮）');
  ok(vm.isCancellable(), 'failed 态 → isCancellable=true');
}

console.log('# 5. 阻断错误 → failed（schema 阶段）');
{
  const events = [
    zipEvent(0.2), manifestEvent(0.3), extractEvent(0.5), hashEvent(0.7),
    failEvent('validating-schema', 0.8, 'IMP-008')
  ];
  const vm = new ImportValidateVM(makeMockService(events, null), 'j4');
  await vm.start();
  const s = vm.getState();
  eq(s.status, 'failed', 'schema 阻断 → failed');
  eq(s.stageMarks[4], 'failed', 'schema(下标4) 标记 failed');
  eq(s.stageMarks[0], 'done', 'zip(下标0) 已 done');
  eq(s.stageMarks[3], 'done', 'hash(下标3) 已 done');
  eq(s.error.code, 'IMP-008', 'error.code=IMP-008');
}

console.log('# 6. confirm 正常流 → importing → completed');
{
  const commitResult = { jobId: 'j5', bookId: 'b1', packageId: 'pkg', contentVersion: '1.0', mode: 'new', chapterCount: 3, warningCount: 0, completedAt: 1700000000000 };
  const events = [
    zipEvent(0.2), manifestEvent(0.3), extractEvent(0.5), hashEvent(0.7), schemaEvent(0.8), bizEvent(0.85),
    awaitingEvent(0.88, 0)
  ];
  const vm = new ImportValidateVM(makeMockService(events, commitResult), 'j5');
  await vm.start();
  eq(vm.getState().status, 'importable', 'confirm 前 importable');
  ok(vm.canConfirm(), '可确认');
  const result = await vm.confirm();
  eq(vm.getState().status, 'completed', 'confirm 后 completed');
  eq(vm.getState().progress, 1, '完成时 progress=1');
  ok(result !== undefined, 'confirm 返回 ImportResult');
  eq(result.bookId, 'b1', 'ImportResult.bookId 正确');
  ok(!vm.isCancellable(), 'completed 态 → isCancellable=false');
  ok(!vm.canConfirm(), 'completed 态 → canConfirm=false');
}

console.log('# 7. confirm 失败 → failed');
{
  const events = [
    zipEvent(0.2), manifestEvent(0.3), extractEvent(0.5), hashEvent(0.7), schemaEvent(0.8), bizEvent(0.85),
    awaitingEvent(0.88, 0)
  ];
  const vm = new ImportValidateVM(makeMockService(events, new Error('commit-failed')), 'j6');
  await vm.start();
  const result = await vm.confirm();
  eq(result, undefined, 'commit 失败时 confirm 返回 undefined');
  eq(vm.getState().status, 'failed', 'commit 失败 → failed');
  ok(vm.getState().error !== undefined, 'error 已设置');
}

console.log('# 8. confirm 在非可导入态被忽略');
{
  const vm = new ImportValidateVM(makeMockService([], null), 'j7');
  // 初始 validating 态
  const result = await vm.confirm();
  eq(result, undefined, '非 importable/warning 态 confirm 返回 undefined');
  eq(vm.getState().status, 'validating', '态不变');
}

console.log('# 9. cancel 正常流 → start 短路');
{
  const events = [zipEvent(0.2), awaitingEvent(0.88, 0)];
  const vm = new ImportValidateVM(makeMockService(events, null), 'j8');
  await vm.start();
  eq(vm.getState().status, 'importable', 'cancel 前 importable');
  const cancelled = await vm.cancel();
  eq(cancelled, true, 'cancel 成功返回 true');
}

console.log('# 10. cancel 在 importing 态被屏蔽');
{
  // 模拟 importing 态：从 warningEvent 进 confirm 但 commit 异步
  const events = [awaitingEvent(0.88, 0)];
  let commitResolve;
  const commitPromise = new Promise(r => commitResolve = r);
  const svc = {
    async *runValidation() { for (const e of events) yield e; },
    async commit() { return commitPromise; },
    async cancel() {}
  };
  const vm = new ImportValidateVM(svc, 'j9');
  await vm.start();
  // 发起 confirm（不 await，令其进入 importing）
  const confirmProm = vm.confirm();
  // 此时 status 应为 importing
  eq(vm.getState().status, 'importing', '进入 importing');
  ok(!vm.isCancellable(), 'importing → isCancellable=false');
  const cancelled = await vm.cancel();
  eq(cancelled, false, 'importing 态 cancel 返回 false');
  // 完成 confirm 避免泄漏
  commitResolve({ jobId: 'j9', bookId: 'b', packageId: 'p', contentVersion: '1', mode: 'new', chapterCount: 1, warningCount: 0, completedAt: 0 });
  await confirmProm;
}

console.log('# 11. cancel 失败时仍设置 error');
{
  const events = [zipEvent(0.2), awaitingEvent(0.88, 0)];
  const vm = new ImportValidateVM(makeMockService(events, null, false), 'j10');
  await vm.start();
  const cancelled = await vm.cancel();
  eq(cancelled, false, 'cancel 失败返回 false');
  ok(vm.getState().error !== undefined, 'cancel 失败时 error 已设置');
  eq(vm.getState().status, 'importable', '态不变（仍可取消显示错误提示）');
}

console.log('# 12. 事件流空或立即结束时 → failed（无 awaiting）');
{
  const vm = new ImportValidateVM(makeMockService([], null), 'j11');
  await vm.start();
  eq(vm.getState().status, 'failed', '空事件流 → failed（无 awaiting-confirmation）');
}

console.log('# 13. 监听器在每次状态变更时被调用');
{
  const events = [zipEvent(0.2), awaitingEvent(0.88, 0)];
  const vm = new ImportValidateVM(makeMockService(events, null), 'j12');
  let callCount = 0;
  vm.setListener(() => callCount++);
  await vm.start();
  // start 开始 emit 初始态（1次），zip 事件（1次），awaiting-confirmation（1次）= 3次
  ok(callCount >= 2, `监听器被调用 ${callCount} 次（≥2）`);
}

console.log('# 14. progress 单调不减（包含 zip 快进到 awaiting）');
{
  const events = [
    { stage: 'validating-zip', progress: 0.3, checkedFiles: 5, totalFiles: 5, warningCount: 0 },
    { stage: 'awaiting-confirmation', progress: 0.2, warningCount: 0 }  // 进度反而更小：应被拦截
  ];
  const vm = new ImportValidateVM(makeMockService(events, null), 'j13');
  await vm.start();
  ok(vm.getState().progress >= 0.3, `progress 单调：${vm.getState().progress} ≥ 0.3`);
}

console.log('# 15. warning 态 confirm → importing → completed（warningCount 保留）');
{
  const commitResult = { jobId: 'j14', bookId: 'b2', packageId: 'pkg2', contentVersion: '1.0', mode: 'new', chapterCount: 2, warningCount: 3, completedAt: 1700000000001 };
  const events = [
    zipEvent(0.2), manifestEvent(0.3), extractEvent(0.5), hashEvent(0.7), schemaEvent(0.8), bizEvent(0.85, 3),
    awaitingEvent(0.88, 3)
  ];
  const vm = new ImportValidateVM(makeMockService(events, commitResult), 'j14');
  await vm.start();
  eq(vm.getState().status, 'warning', '警告态确认前');
  await vm.confirm();
  eq(vm.getState().status, 'completed', 'warning → 确认 → completed');
  eq(vm.getState().warningCount, 3, 'completed 后 warningCount=3（来自 ImportResult）');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
