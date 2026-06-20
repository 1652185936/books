/**
 * P-F03 校验页 ViewModel（LLD §6.3：状态 校验中/可导入/警告/失败/导入中/完成；约束 阻断错误隐藏确认按钮、进度只前进不回退）。
 *
 * 职责（页面与 Service/SQL/SDK 的隔离层，CLAUDE.md §5 / 04 §12.5「页面只依赖 Service/ViewModel」）：
 * - 持有校验页有限状态机（`ImportValidateStatus`）与脱敏展示数据（阶段进度、警告数、阻断错误、各阶段标记、ImportResult）；
 * - 消费 `ImportService.runValidation` 异步事件流，逐阶段刷新进度与阶段标记（progress 单调不减）；
 *   命中 `blockingError` → 切「失败」并据 `retryable` 决定可重试；走完到 awaiting-confirmation → 切「可导入/警告」；
 * - 「确认导入」`confirm` → `ImportService.commit`（先切「导入中」）→ 成功切「完成」并携带 `ImportResult`；
 * - 「取消」`cancel` → `ImportService.cancel`（§2.6：`indexing` 及之后不可取消，导入中态屏蔽取消）；
 * - 失败统一归一为 `AppError`（不抛裸字符串，04 §1），页面据 `messageKey` 渲染资源文案。
 *
 * 纯逻辑、零 ArkUI/`@ohos.*` 依赖：设备 IO 经 `ImportService` 及其端口完成；本类可用内存假实现单测。
 */
import { Id, AppError } from '../domain/entities/common';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import { ImportService } from '../services/ImportService';
import { ImportProgressEvent, ImportResult, ValidationStage } from '../domain/entities/import';

/** 各校验阶段标记态（供 ValidationStageGrid 渲染九宫格状态）。 */
export type StageMark = 'pending' | 'active' | 'done' | 'failed';

/** 阶段标识（六个校验阶段，对齐《04》§2 `ValidationStage`，按 §2.3 顺序）。 */
export const VALIDATION_STAGES: ValidationStage[] = [
  'validating-zip',
  'validating-manifest',
  'extracting-to-staging',
  'validating-hash',
  'validating-schema',
  'validating-business'
];

/**
 * P-F03 校验页有限状态（LLD §6.3「状态」列逐一对齐）。
 */
export enum ImportValidateStatus {
  /** 校验中：runValidation 进行中，尚未抵达 awaiting-confirmation/失败。 */
  Validating = 'validating',
  /** 可导入：校验全通过、无警告，等待用户「确认导入」。 */
  Importable = 'importable',
  /** 警告：校验通过但存在待复核内容（IMP-015，warningCount>0），仍可确认导入。 */
  Warning = 'warning',
  /** 失败：命中阻断错误（含 blockingError）；阻断错误隐藏「确认导入」。 */
  Failed = 'failed',
  /** 导入中：已点击「确认导入」，commit 进行中（不可取消）。 */
  Importing = 'importing',
  /** 完成：commit 成功，已落库提升提交，携带 ImportResult。 */
  Completed = 'completed'
}

/**
 * 校验页可观察状态快照（页面以 `@State` 持有；只含脱敏展示字段）。
 */
export interface ImportValidateState {
  /** 当前有限状态。 */
  status: ImportValidateStatus;
  /** 当前整体进度（0..1，单调不减）。 */
  progress: number;
  /** 各阶段标记（与 `VALIDATION_STAGES` 等长、同序）。 */
  stageMarks: StageMark[];
  /** 当前活跃/最近一个阶段下标（-1 表示未开始）。 */
  activeStageIndex: number;
  /** 警告累计数（IMP-015）。 */
  warningCount: number;
  /** 已检查文件数（最近一次校验事件）。 */
  checkedFiles: number;
  /** 总文件数（可得时）。 */
  totalFiles?: number;
  /** 阻断/失败错误（失败态存在；供页面据 messageKey 渲染）。 */
  error?: AppError;
  /** 完成结果（完成态存在）。 */
  result?: ImportResult;
}

/**
 * 导入校验页 ViewModel。
 */
export class ImportValidateVM {
  /** 导入服务（校验/提交/取消编排）。 */
  private readonly importService: ImportService;
  /** 当前导入任务 ID。 */
  private readonly jobId: Id;
  /** 当前状态快照（单一可变状态，所有变更经 emit 同步给监听器）。 */
  private state: ImportValidateState;
  /** 状态变更监听器（页面注册以触发 `@State` 刷新）。 */
  private listener?: (state: ImportValidateState) => void;

  /**
   * @param importService 导入服务。
   * @param jobId 导入任务 ID（import_jobs.id）。
   */
  constructor(importService: ImportService, jobId: Id) {
    this.importService = importService;
    this.jobId = jobId;
    // 初始为「校验中」全 pending 快照
    this.state = ImportValidateVM.initialState();
  }

  /**
   * 构造初始「校验中」快照（全阶段 pending、进度 0）。
   * @returns 初始状态快照。
   */
  private static initialState(): ImportValidateState {
    // 全 pending 阶段标记
    const marks: StageMark[] = [];
    for (let i: number = 0; i < VALIDATION_STAGES.length; i++) {
      marks.push('pending');
    }
    return {
      status: ImportValidateStatus.Validating,
      progress: 0,
      stageMarks: marks,
      activeStageIndex: -1,
      warningCount: 0,
      checkedFiles: 0
    };
  }

  /**
   * 取当前状态快照（供页面 onReady 初始化 `@State`）。
   * @returns 当前状态快照。
   */
  getState(): ImportValidateState {
    return this.state;
  }

  /**
   * 注册状态变更监听器（页面用以把 VM 状态同步到 `@State`）。
   * @param listener 状态变更回调。
   * @returns 无。
   */
  setListener(listener: (state: ImportValidateState) => void): void {
    this.listener = listener;
  }

  /**
   * 启动校验：消费 `runValidation` 事件流逐阶段刷新；终态切「可导入/警告/失败」。
   * 页面在 onReady（装配 + bindSourceUri 后）调用一次；不抛异常，错误进 state.error。
   * @returns 完成的 Promise（迭代结束即返回）。
   */
  async start(): Promise<void> {
    // 重置为初始校验中态
    this.emit(ImportValidateVM.initialState());
    try {
      // 消费异步事件流
      for await (const event of this.importService.runValidation(this.jobId)) {
        this.consume(event);
        // 命中阻断错误：迭代会随之终止，这里提前置失败态（保险）
        if (event.blockingError !== undefined) {
          return;
        }
      }
      // 迭代正常结束且未失败：若仍停留校验中（无 awaiting 事件兜底），按失败处理
      if (this.state.status === ImportValidateStatus.Validating) {
        this.toFailed(AppErrors.create(DB_WRITE_FAILED, { detail: 'validation-ended-without-confirmation' }));
      }
    } catch (cause) {
      // 事件流自身异常：归一并切失败
      this.toFailed(AppErrors.from(cause, DB_WRITE_FAILED));
    }
  }

  /**
   * 消费单个进度事件：刷新进度、阶段标记、警告数；据 stage/blockingError 切相应态。
   * @param event 导入进度事件。
   * @returns 无。
   */
  private consume(event: ImportProgressEvent): void {
    // 进度单调不减
    const progress: number = event.progress > this.state.progress ? event.progress : this.state.progress;
    // 拷贝阶段标记数组（避免就地修改造成 @State 不刷新）
    const marks: StageMark[] = this.state.stageMarks.slice();
    // 当前阶段在六校验阶段中的下标（-1 表示非校验阶段，如 awaiting-confirmation）
    const stageIndex: number = VALIDATION_STAGES.indexOf(event.stage as ValidationStage);
    // 已检查/总文件数（仅校验事件携带；后续阶段事件无此字段）
    const validationEvent: ValidationEventLike = event as ValidationEventLike;
    const checkedFiles: number = typeof validationEvent.checkedFiles === 'number' ? validationEvent.checkedFiles : this.state.checkedFiles;
    const totalFiles: number | undefined = typeof validationEvent.totalFiles === 'number' ? validationEvent.totalFiles : this.state.totalFiles;

    // 阻断错误：把当前阶段前序全标 done、当前标 failed，切「失败」
    if (event.blockingError !== undefined) {
      if (stageIndex >= 0) {
        for (let i: number = 0; i < stageIndex; i++) {
          marks[i] = 'done';
        }
        marks[stageIndex] = 'failed';
      }
      this.emit({
        status: ImportValidateStatus.Failed,
        progress: progress,
        stageMarks: marks,
        activeStageIndex: stageIndex >= 0 ? stageIndex : this.state.activeStageIndex,
        warningCount: this.state.warningCount,
        checkedFiles: checkedFiles,
        totalFiles: totalFiles,
        error: event.blockingError
      });
      return;
    }

    // 非阻断校验阶段事件：把此前阶段标记 done、当前阶段标记 active
    if (stageIndex >= 0) {
      for (let i: number = 0; i < stageIndex; i++) {
        marks[i] = 'done';
      }
      marks[stageIndex] = 'active';
      this.emit({
        status: ImportValidateStatus.Validating,
        progress: progress,
        stageMarks: marks,
        activeStageIndex: stageIndex,
        warningCount: event.warningCount,
        checkedFiles: checkedFiles,
        totalFiles: totalFiles
      });
      return;
    }

    // awaiting-confirmation：六校验阶段全 done，切「可导入/警告」
    if (event.stage === 'awaiting-confirmation') {
      for (let i: number = 0; i < marks.length; i++) {
        marks[i] = 'done';
      }
      this.emit({
        status: event.warningCount > 0 ? ImportValidateStatus.Warning : ImportValidateStatus.Importable,
        progress: progress,
        stageMarks: marks,
        activeStageIndex: marks.length - 1,
        warningCount: event.warningCount,
        checkedFiles: checkedFiles,
        totalFiles: totalFiles
      });
    }
  }

  /**
   * 确认导入：切「导入中」→ `ImportService.commit(jobId, 'new')` → 成功切「完成」（携 ImportResult）。
   * 仅「可导入/警告」态可触发；其余态忽略（防重复点击 / 阻断态无确认按钮，§6.3）。
   * @returns 完成结果（成功时）；被忽略或失败返回 undefined（失败时 state.error 已置）。
   */
  async confirm(): Promise<ImportResult | undefined> {
    // 仅可导入/警告态可确认（阻断态隐藏确认按钮，导入中防重复）
    if (this.state.status !== ImportValidateStatus.Importable && this.state.status !== ImportValidateStatus.Warning) {
      return undefined;
    }
    // 进入「导入中」（不可取消，§2.6）
    this.emit({
      status: ImportValidateStatus.Importing,
      progress: this.state.progress,
      stageMarks: this.state.stageMarks.slice(),
      activeStageIndex: this.state.activeStageIndex,
      warningCount: this.state.warningCount,
      checkedFiles: this.state.checkedFiles,
      totalFiles: this.state.totalFiles
    });
    try {
      // 第一版仅 new 导入路径（upgrade 子流程由 commit 内核支持，UI 选择列入后续）
      const result: ImportResult = await this.importService.commit(this.jobId, 'new');
      // 成功：切「完成」并携带结果（进度满）
      this.emit({
        status: ImportValidateStatus.Completed,
        progress: 1,
        stageMarks: this.state.stageMarks.slice(),
        activeStageIndex: this.state.activeStageIndex,
        warningCount: result.warningCount,
        checkedFiles: this.state.checkedFiles,
        totalFiles: this.state.totalFiles,
        result: result
      });
      return result;
    } catch (cause) {
      // 提交失败：切「失败」（commit 内核已置任务 failed、回滚目录）
      this.toFailed(AppErrors.from(cause, DB_WRITE_FAILED));
      return undefined;
    }
  }

  /**
   * 取消导入：`ImportService.cancel`（§2.6：`indexing` 及之后不可取消；导入中态屏蔽取消）。
   * @returns 取消成功返回 true；被屏蔽/失败返回 false（失败时 state.error 已置）。
   */
  async cancel(): Promise<boolean> {
    // 导入中/已完成：不可取消（§2.6 indexing 及之后）
    if (this.state.status === ImportValidateStatus.Importing || this.state.status === ImportValidateStatus.Completed) {
      return false;
    }
    try {
      await this.importService.cancel(this.jobId, Date.now());
      return true;
    } catch (cause) {
      // 取消失败：仅置错误（不改变主流程态，由页面据 error 提示并允许返回）
      this.emit({
        status: this.state.status,
        progress: this.state.progress,
        stageMarks: this.state.stageMarks.slice(),
        activeStageIndex: this.state.activeStageIndex,
        warningCount: this.state.warningCount,
        checkedFiles: this.state.checkedFiles,
        totalFiles: this.state.totalFiles,
        error: AppErrors.from(cause, DB_WRITE_FAILED)
      });
      return false;
    }
  }

  /**
   * 当前态是否允许取消（页面据此决定取消按钮可用性；§2.6）。
   * @returns 可取消返回 true。
   */
  isCancellable(): boolean {
    return this.state.status === ImportValidateStatus.Validating
      || this.state.status === ImportValidateStatus.Importable
      || this.state.status === ImportValidateStatus.Warning
      || this.state.status === ImportValidateStatus.Failed;
  }

  /**
   * 当前态是否展示「确认导入」按钮（阻断错误隐藏确认按钮，§6.3 页面约束）。
   * @returns 展示返回 true。
   */
  canConfirm(): boolean {
    return this.state.status === ImportValidateStatus.Importable || this.state.status === ImportValidateStatus.Warning;
  }

  /**
   * 切「失败」态（统一出口）。
   * @param error 领域错误。
   * @returns 无。
   */
  private toFailed(error: AppError): void {
    // 把活跃阶段标记 failed（若有）
    const marks: StageMark[] = this.state.stageMarks.slice();
    if (this.state.activeStageIndex >= 0 && this.state.activeStageIndex < marks.length) {
      marks[this.state.activeStageIndex] = 'failed';
    }
    this.emit({
      status: ImportValidateStatus.Failed,
      progress: this.state.progress,
      stageMarks: marks,
      activeStageIndex: this.state.activeStageIndex,
      warningCount: this.state.warningCount,
      checkedFiles: this.state.checkedFiles,
      totalFiles: this.state.totalFiles,
      error: error
    });
  }

  /**
   * 更新内部状态并通知监听器（单一变更出口，保证 state 与页面 `@State` 一致）。
   * @param next 下一状态快照。
   * @returns 无。
   */
  private emit(next: ImportValidateState): void {
    // 替换当前快照
    this.state = next;
    // 通知页面刷新（未注册监听器时静默）
    if (this.listener !== undefined) {
      this.listener(next);
    }
  }
}

/** 校验事件鸭子类型（读取 checkedFiles/totalFiles，后续阶段事件无此字段时为 undefined）。 */
interface ValidationEventLike {
  /** 已检查文件数（仅校验阶段事件携带）。 */
  checkedFiles?: number;
  /** 总文件数（仅校验阶段事件携带）。 */
  totalFiles?: number;
}
