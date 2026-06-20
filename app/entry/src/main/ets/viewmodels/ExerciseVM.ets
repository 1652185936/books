/**
 * P-F06 手写练习页 ViewModel（LLD §6.6：状态 空白/书写中/可提交/识别判分中；多空逐空独立画布/焦点 R-018）。
 *
 * 职责（页面与 SQL/SDK 的隔离层，CLAUDE.md §5 / 04 §12.5「页面只依赖 Service/ViewModel」）：
 * - 加载 `ExerciseDetail` 并为每个 blank 经 `HandwritingService.begin` 建立独立 `StrokeSession`（逐空独立画布）。
 * - 维护当前激活 blank 焦点（当前空强调边框、下一空自动/点击聚焦，§6.6）；**不允许一条笔迹跨空保存**——
 *   笔画始终追加到「当前激活 blank」的会话，越界/无焦点时拒绝（不变量见 `appendStroke`）。
 * - 维护每空的撤销/重做/清除栈（撤销=弹出最后一笔入重做栈；重做=回推；清除=整段入重做栈一次性撤销）。
 * - draft 快照持久化：经 `HandwritingService.persistDraft` 落盘（页面每 2 秒/退出前调用；**停笔不自动识别**，§4.1）。
 * - 状态机：空白（无任何笔迹）→ 书写中（有笔迹但尚不可提交语义）→ 可提交（至少一空有笔迹）→ 识别判分中
 *   （`confirm` 后）。本 VM 把「书写中/可提交」统一以「是否至少一空有笔迹」判定：有笔迹即「可提交」。
 * - `confirm()`：收集 `ConfirmedAnswer[]` 的**前置数据**（逐空 strokeRecordId 由识别成功后补齐——F07），
 *   切「识别判分中」态并调用**注入的 handler**（F07 接真实识别 + 判分）；本轮 handler 为占位。
 *
 * 单位换算：blank 渲染宽度经 `clampBlankWidthVp(widthEm)`（§1.3 R-035 / §6.6），高度经 `blankHeightVp(lines)`。
 *
 * 纯逻辑、零 ArkUI/`@ohos.*` 依赖：仓储/手写服务经构造注入；状态机/栈/不变量可用内存假实现单测（见 `.ralph/f06-test/`）。
 */
import { Id, EpochMs, AppError } from '../domain/entities/common';
import { AppErrors, DB_QUERY_FAILED } from '../utils/AppErrors';
import { ExerciseRepository, ExerciseDetail, ExerciseBlank, ConfirmedAnswer } from '../domain/entities/exercise';
import {
  HandwritingService, HandwritingTarget, StrokeSession, Stroke
} from '../domain/entities/handwriting';
import { clampBlankWidthVp, blankHeightVp } from '../components/exercise/ExerciseTokens';

/** P-F06 手写练习页有限状态（LLD §6.6「状态」列逐一对齐）。 */
export type ExerciseStatus = 'loading' | 'blank' | 'writing' | 'submittable' | 'recognizing' | 'broken';

/**
 * 单空作答运行态（内存）：会话 + 撤销/重做栈 + 已落盘笔迹记录引用（F07 识别后补齐）。
 */
export interface BlankAttempt {
  /** 对应空位定义。 */
  blank: ExerciseBlank;
  /** 该空独立笔迹会话（HandwritingService.begin 建立）。 */
  session: StrokeSession;
  /** 重做栈（撤销弹出的笔画压入此处；新笔画追加时清空，避免分叉历史）。 */
  redoStack: Stroke[];
  /** 该空已落盘笔迹记录 ID（识别成功后由 F07 写 handwriting_records 后补齐；未落盘为空串）。 */
  strokeRecordId: Id;
  /** blank 渲染宽度（vp，clampBlankWidthVp 预计算）。 */
  widthVp: number;
  /** blank 渲染高度（vp，blankHeightVp 预计算）。 */
  heightVp: number;
}

/**
 * 确认答案后交给 F07 的提交载体：练习/作答标识 + 逐空已确认答案前置数据。
 * recognizedText/strokeRecordId 在识别成功后补齐——F06 提交时识别文本为空、strokeRecordId 取已落盘值（可空）。
 */
export interface ExerciseConfirmPayload {
  /** 练习内部主键。 */
  exerciseId: Id;
  /** 作答内部主键（createDraft 产出的快照锚）。 */
  attemptId: Id;
  /** 逐空已确认答案前置数据（顺序与 blanks 一致，仅含有笔迹的空）。 */
  answers: ConfirmedAnswer[];
}

/**
 * 确认答案处理端口（F07 接真实识别 + 判分编排）。F06 注入占位实现（不识别、不判分）。
 */
export interface ConfirmHandler {
  /**
   * 提交已确认答案前置数据进入识别/判分（F07）。
   * @param payload 提交载体。
   * @returns 完成的 Promise（F06 占位实现可立即 resolve 或抛「未接入」）。
   */
  handle(payload: ExerciseConfirmPayload): Promise<void>;
}

/**
 * 手写练习页 ViewModel。`@Observed` 使其字段变更驱动页面刷新（页面以快照同步或 `@ObjectLink` 持有）。
 */
@Observed
export class ExerciseVM {
  /** 练习仓储（构造注入；页面不直接持有，经 VM 间接访问，CLAUDE.md §5）。 */
  private readonly repo: ExerciseRepository;
  /** 手写服务（会话/草稿/识别编排；构造注入）。 */
  private readonly handwriting: HandwritingService;
  /** 确认答案处理端口（F07 接；F06 占位）。 */
  private readonly confirmHandler: ConfirmHandler;
  /** 时间源（epoch ms；构造注入便于确定性测试，缺省取系统时钟）。 */
  private readonly now: () => EpochMs;

  /** 顶层页面状态。 */
  status: ExerciseStatus = 'loading';
  /** 已加载练习详情（status 非 loading/broken 时有值）。 */
  detail?: ExerciseDetail;
  /** 作答草稿标识（createDraft 产出；提交时随 payload 上抛）。 */
  attemptId: Id = '';
  /** 逐空作答运行态（顺序与 detail.blanks 一致）。 */
  blanks: BlankAttempt[] = [];
  /** 当前激活 blank 下标（焦点；-1 表示无焦点）。 */
  activeBlankIndex: number = -1;
  /** 失败错误（status='broken' 或识别失败时有值，供状态行取资源键文案）。 */
  error?: AppError;

  /**
   * @param repo 练习仓储。
   * @param handwriting 手写服务。
   * @param confirmHandler 确认答案处理端口（F07 接；F06 占位）。
   * @param now 时间源（缺省 `() => Date.now()`）。
   */
  constructor(
    repo: ExerciseRepository,
    handwriting: HandwritingService,
    confirmHandler: ConfirmHandler,
    now?: () => EpochMs) {
    this.repo = repo;
    this.handwriting = handwriting;
    this.confirmHandler = confirmHandler;
    this.now = now !== undefined ? now : (): EpochMs => Date.now();
  }

  /**
   * 加载练习并建立逐空运行态：取详情 → 建草稿 attempt → 为每空 begin 会话（独立画布）→ 落定状态机。
   * 失败置 'broken' 态（不抛出，状态机自落定）。
   * @param exerciseId 练习内部主键。
   * @returns 加载完成的 Promise。
   */
  async load(exerciseId: Id): Promise<void> {
    this.status = 'loading';
    this.error = undefined;
    try {
      // 练习详情（题面 + 判分选项 + 空位）
      const detail: ExerciseDetail = await this.repo.getExercise(exerciseId);
      this.detail = detail;
      // 作答草稿（grade='draft' 快照锚，可重启恢复，§4.1 / R-021）
      const draftAttemptId: Id = (await this.repo.createDraft(exerciseId)).attemptId;
      this.attemptId = draftAttemptId;
      // 逐空建立独立笔迹会话与运行态
      this.blanks = detail.blanks.map((blank: ExerciseBlank): BlankAttempt =>
        this.buildBlankAttempt(detail, blank));
      // 默认聚焦首空（多空：当前空强调边框；无空则无焦点）
      this.activeBlankIndex = this.blanks.length > 0 ? 0 : -1;
      // loading 态 recomputeStatus 会提前退出；先重置为 'blank' 以确保状态机能正确落定
      this.status = 'blank';
      this.recomputeStatus();
    } catch (cause) {
      // 练习不存在/损坏 → broken 态
      this.error = AppErrors.from(cause, DB_QUERY_FAILED);
      this.detail = undefined;
      this.blanks = [];
      this.activeBlankIndex = -1;
      this.status = 'broken';
    }
  }

  /**
   * 为单空构建运行态：begin 独立会话（画布尺寸取 clamp 后的渲染宽高，§4.1 同坐标系）+ 空栈。
   * @param detail 练习详情（提供归属 ID）。
   * @param blank 空位定义。
   * @returns 单空运行态。
   */
  private buildBlankAttempt(detail: ExerciseDetail, blank: ExerciseBlank): BlankAttempt {
    // 渲染宽高（§6.6 clamp / 有效高度 ≥88vp）
    const widthVp: number = clampBlankWidthVp(blank.widthEm);
    const heightVp: number = blankHeightVp(blank.lines);
    // 手写目标（exercise-blank：ownerId=练习 ID、blankKey=空位键、画布与渲染同坐标系）
    const target: HandwritingTarget = {
      type: 'exercise-blank',
      ownerId: detail.id,
      blankKey: blank.blankKey,
      mode: blank.handwritingMode,
      canvasWidthVp: widthVp,
      canvasHeightVp: heightVp
    };
    return {
      blank,
      session: this.handwriting.begin(target),
      redoStack: [],
      strokeRecordId: '',
      widthVp,
      heightVp
    };
  }

  /**
   * 聚焦某空（下一空点击或完成当前空后自动聚焦，§6.6）。越界静默忽略。
   * @param index 目标空下标。
   * @returns 无。
   */
  focusBlank(index: number): void {
    if (index < 0 || index >= this.blanks.length) {
      return;
    }
    this.activeBlankIndex = index;
  }

  /**
   * 自动聚焦下一空（完成当前空后调用，§6.6「完成当前空后自动聚焦」）。已是末空则保持。
   * @returns 无。
   */
  focusNextBlank(): void {
    // 末空或无焦点时不前进（保持当前焦点，避免跨出范围）
    if (this.activeBlankIndex >= 0 && this.activeBlankIndex < this.blanks.length - 1) {
      this.activeBlankIndex = this.activeBlankIndex + 1;
    }
  }

  /**
   * 追加一条笔迹到**当前激活 blank** 的会话（即时墨迹由页面渲染；本方法只维护数据不变量）。
   *
   * 不变量（§6.6「不允许一条笔迹跨空位保存」）：笔画只能进入当前激活 blank 的会话；无焦点（-1）或越界时**拒绝**
   * 写入并返回 false。页面必须保证笔迹的命中测试落在当前激活画布内，跨画布的笔迹不得提交到本方法。
   *
   * @param stroke 一条完整笔画（停笔后产生的整条笔迹，不跨空）。
   * @returns 成功追加返回 true；无焦点/越界拒绝返回 false。
   */
  appendStroke(stroke: Stroke): boolean {
    // 无焦点或越界：拒绝（不变量——不允许无归属/跨空笔迹）
    if (this.activeBlankIndex < 0 || this.activeBlankIndex >= this.blanks.length) {
      return false;
    }
    // 当前激活 blank 运行态
    const attempt: BlankAttempt = this.blanks[this.activeBlankIndex];
    // 追加笔画到该空会话（仅当前空，永不跨空）
    attempt.session.document.strokes.push(stroke);
    // 新笔画使重做栈失效（避免历史分叉）
    attempt.redoStack = [];
    // 标记脏 + 刷新时间（页面据此触发 2 秒快照）
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    // 有笔迹后状态从空白进入可提交（recomputeStatus 统一判定）
    this.recomputeStatus();
    return true;
  }

  /**
   * 撤销当前激活 blank 的最后一笔（弹出末笔压入重做栈）。无焦点/无笔迹静默忽略。
   * @returns 撤销成功返回 true。
   */
  undo(): boolean {
    // 当前激活 blank（无焦点返回 false）
    const attempt: BlankAttempt | undefined = this.currentAttempt();
    if (attempt === undefined || attempt.session.document.strokes.length === 0) {
      return false;
    }
    // 弹出末笔压入重做栈
    const popped: Stroke | undefined = attempt.session.document.strokes.pop();
    if (popped !== undefined) {
      attempt.redoStack.push(popped);
    }
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    this.recomputeStatus();
    return true;
  }

  /**
   * 重做当前激活 blank 的上一次撤销（从重做栈回推一笔）。无焦点/重做栈空静默忽略。
   * @returns 重做成功返回 true。
   */
  redo(): boolean {
    // 当前激活 blank（无焦点返回 false）
    const attempt: BlankAttempt | undefined = this.currentAttempt();
    if (attempt === undefined || attempt.redoStack.length === 0) {
      return false;
    }
    // 从重做栈回推一笔到文档末尾
    const restored: Stroke | undefined = attempt.redoStack.pop();
    if (restored !== undefined) {
      attempt.session.document.strokes.push(restored);
    }
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    this.recomputeStatus();
    return true;
  }

  /**
   * 清除当前激活 blank 的全部笔迹（整段移入重做栈，一次性可重做恢复）。无焦点/无笔迹静默忽略。
   * @returns 清除成功返回 true。
   */
  clear(): boolean {
    // 当前激活 blank（无焦点返回 false）
    const attempt: BlankAttempt | undefined = this.currentAttempt();
    if (attempt === undefined || attempt.session.document.strokes.length === 0) {
      return false;
    }
    // 全部笔画倒序压入重做栈（重做时按原顺序回推），再清空文档
    const strokes: Stroke[] = attempt.session.document.strokes;
    for (let i: number = strokes.length - 1; i >= 0; i--) {
      attempt.redoStack.push(strokes[i]);
    }
    attempt.session.document.strokes = [];
    attempt.session.dirty = true;
    attempt.session.updatedAt = this.now();
    this.recomputeStatus();
    return true;
  }

  /**
   * 持久化全部脏会话的草稿快照（页面每 2 秒/退出前调用；停笔不识别，§4.1）。
   * @returns 全部落盘完成的 Promise（单空失败不阻断其余，记录到 error）。
   */
  async persistDrafts(): Promise<void> {
    // 逐空落盘脏会话（页面 2 秒快照 / 退出强制落盘，§4.1）
    for (let i: number = 0; i < this.blanks.length; i++) {
      // 当前空运行态
      const attempt: BlankAttempt = this.blanks[i];
      if (attempt.session.dirty) {
        try {
          await this.handwriting.persistDraft(attempt.session);
        } catch (cause) {
          // 单空落盘失败不阻断其余空（保留笔迹，记录错误供页面提示重试）
          this.error = AppErrors.from(cause, 'DB_WRITE_FAILED');
        }
      }
    }
  }

  /**
   * 「可提交」判定（§6.6）：至少一空有笔迹即可提交（确认答案按钮可用）。
   * @returns 至少一空有笔迹返回 true。
   */
  canSubmit(): boolean {
    for (let i: number = 0; i < this.blanks.length; i++) {
      if (this.blanks[i].session.document.strokes.length > 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 确认答案：收集 `ConfirmedAnswer[]` 前置数据，先落盘草稿 → 切「识别判分中」态 → 调用注入的 handler（F07 接）。
   *
   * 约束（CLAUDE.md §6/§8）：**仅用户点击「确认答案」后调用**；识别判分中禁用按钮防重复提交（页面据 status 禁用）。
   * F06 不识别不判分：recognizedText 留空、strokeRecordId 取已落盘值，识别文本在 F07 识别成功后补齐。
   *
   * @returns 完成的 Promise（不可提交时直接返回；handler 失败回退「可提交」并置 error）。
   */
  async confirm(): Promise<void> {
    // 不可提交（无任何笔迹）或非作答态：忽略
    if (this.status === 'recognizing' || !this.canSubmit() || this.detail === undefined) {
      return;
    }
    // 先强制落盘当前笔迹（保证识别提交的是最新原始笔迹，§4.1 退出前强制落盘同口径）
    await this.persistDrafts();
    // 收集逐空已确认答案前置数据（仅含有笔迹的空；recognizedText 待 F07 补齐）
    const answers: ConfirmedAnswer[] = [];
    for (let i: number = 0; i < this.blanks.length; i++) {
      // 当前空运行态
      const attempt: BlankAttempt = this.blanks[i];
      if (attempt.session.document.strokes.length > 0) {
        answers.push({
          blankKey: attempt.blank.blankKey,
          recognizedText: '',
          strokeRecordId: attempt.strokeRecordId
        });
      }
    }
    // 切「识别判分中」态（禁用确认按钮，防重复提交，§4.2）
    this.status = 'recognizing';
    // 提交载体
    const payload: ExerciseConfirmPayload = {
      exerciseId: this.detail.id,
      attemptId: this.attemptId,
      answers
    };
    try {
      // 委托 F07 handler（F06 占位实现）；超时/失败由 handler 内部按 §4.2 处理
      await this.confirmHandler.handle(payload);
    } catch (cause) {
      // handler 失败：保留笔迹、从 recognizing 重置为 blank 再 recompute（guard 跳过 recognizing 态）
      this.error = AppErrors.from(cause, 'service-unavailable');
      this.status = 'blank';
      this.recomputeStatus();
    }
  }

  /**
   * 取当前激活 blank 运行态（无焦点/越界返回 undefined）。
   * @returns 当前空运行态或 undefined。
   */
  currentAttempt(): BlankAttempt | undefined {
    if (this.activeBlankIndex < 0 || this.activeBlankIndex >= this.blanks.length) {
      return undefined;
    }
    return this.blanks[this.activeBlankIndex];
  }

  /**
   * 重算顶层状态（识别判分中态由 confirm 显式置，本方法不覆盖）：
   * 无空位/无任何笔迹 → 'blank'；有笔迹 → 'submittable'（书写中即可提交，§6.6「可提交=至少一空有笔迹」）。
   * @returns 无。
   */
  private recomputeStatus(): void {
    // 识别判分中由 confirm 维护，重算不打断
    if (this.status === 'recognizing' || this.status === 'loading' || this.status === 'broken') {
      return;
    }
    this.status = this.canSubmit() ? 'submittable' : 'blank';
  }
}
