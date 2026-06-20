/**
 * 导入重启恢复 + 后台超时（P1-5，LLD §2.6 R-017）。
 *
 * 应用重启时扫描**非终态** `import_jobs`，按状态归类并清理半成品（§2.6）：
 * - `awaiting_confirmation`：用户离开后挂起等待；超过 24 小时未确认 → 自动 `cancelled` 并清理；未超时 → 保持挂起。
 * - `selected`：仅选中、后台任务未真正启动即中断 → `cancelled` 清理（无半成品；用户可重新导入）。
 * - `copying`/`validating_*`/`extracting_to_staging`（`indexing` 之前）：中断 → 按**可重试失败**处理（IMP-017，
 *   清理暂存，用户可重试复用 jobId）。
 * - `indexing`/`promoting_to_final`/`committing`（写库阶段）：中断 → 回滚至 `failed` 并清理半成品（IMP-019）；
 *   DB 事务未提交即自动回滚（无残留书行），暂存目录清理，**绝不残留半本书**。
 *
 * 纯分类 `classify`（状态 + 时间 → 动作）可单测；执行器 `recover` 仅做「清理暂存 + 守卫式 transition」，
 * 时间戳由调用方注入（`now`，启动时取系统时钟）。
 *
 * 已知边界（非降级，文档化）：写库阶段中断时，正式目录可能残留**新导入**未提交的半提升目录；由于 `import_jobs`
 * 不持 `bookId`，本恢复仅清理暂存与置 `failed`，对应正式目录孤儿（崩溃窗口极窄）留待派生目录 GC 清理——
 * 因其无对应 DB 书行，不构成「半本书」。升级路径的目录回滚由 `UpgradeIndexer.restoreOld` 在事务内承担。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore（经仓储）、`ImportFs`/URI 授权端口生产实现以 API 12 为准。
 */
import { ImportJobRepository, ImportJobRecord } from '../../repositories/ImportJobRepository';
import { ImportState } from './ImportStateMachine';
import { ImportFs, StagingArea } from './ImportStaging';
import { UriPermissionPort } from './ImportLifecycle';

/** 恢复动作种类。 */
export type RecoveryActionKind =
  | 'keep-suspended'   // 保持挂起（awaiting_confirmation 未超时；或终态防御性 no-op）
  | 'cancel'           // 置 cancelled 并清理（selected 中断 / awaiting 超时）
  | 'fail-retryable'   // 置 failed（可重试，indexing 之前中断）
  | 'rollback-fail';   // 置 failed 并清理半成品（写库阶段中断）

/** 恢复动作（纯分类产物）。 */
export interface RecoveryAction {
  /** 任务 ID。 */
  jobId: string;
  /** 动作种类。 */
  kind: RecoveryActionKind;
  /** 写入 failed 的错误码（仅 fail/rollback 动作）。 */
  errorCode?: string;
  /** 脱敏诊断详情。 */
  detail?: string;
}

/** `awaiting_confirmation` 自动取消阈值：24 小时（§2.6）。 */
export const AWAITING_TTL_MS: number = 24 * 60 * 60 * 1000;

/** 非终态状态集合（重启恢复扫描对象）。 */
export const NON_TERMINAL_STATES: ImportState[] = [
  'selected', 'copying', 'validating_zip', 'validating_manifest', 'extracting_to_staging',
  'validating_hash', 'validating_schema', 'validating_business', 'awaiting_confirmation',
  'indexing', 'promoting_to_final', 'committing'
];

/** `indexing` 之前的中断按可重试失败处理（IMP-017，环境/IO 类可重试）。 */
const PRE_INDEX_INTERRUPT_CODE: string = 'IMP-017';
/** 写库阶段中断回滚的失败码（IMP-019，建索引失败，可重试）。 */
const INDEX_INTERRUPT_CODE: string = 'IMP-019';

/** `indexing` 之前的中断状态集合（按可重试失败处理）。 */
const PRE_INDEX_STATES: ImportState[] = [
  'copying', 'validating_zip', 'validating_manifest', 'extracting_to_staging',
  'validating_hash', 'validating_schema', 'validating_business'
];

/** 写库阶段中断状态集合（回滚至 failed 并清理半成品）。 */
const INDEXING_STATES: ImportState[] = ['indexing', 'promoting_to_final', 'committing'];

/**
 * 导入重启恢复器。
 */
export class ImportRecovery {
  /** 导入任务仓储（状态机持久化）。 */
  private readonly jobRepo: ImportJobRepository;
  /** 文件系统端口（暂存清理）。 */
  private readonly fs: ImportFs;
  /** 运行期临时目录绝对路径（`context.tempDir`）。 */
  private readonly tempDir: string;
  /** 持久化 URI 授权端口（自动取消时释放）。 */
  private readonly uriPermissions: UriPermissionPort;

  /**
   * @param jobRepo 导入任务仓储。
   * @param fs 文件系统端口。
   * @param tempDir 运行期临时目录绝对路径。
   * @param uriPermissions 持久化 URI 授权端口。
   */
  constructor(jobRepo: ImportJobRepository, fs: ImportFs, tempDir: string, uriPermissions: UriPermissionPort) {
    this.jobRepo = jobRepo;
    this.fs = fs;
    this.tempDir = tempDir;
    this.uriPermissions = uriPermissions;
  }

  /**
   * 纯分类：根据状态与时间决定恢复动作（可单测，不触 IO）。
   * @param job 任务记录（仅读 id/state/startedAt）。
   * @param now 当前时间戳（epoch ms）。
   * @param ttlMs awaiting_confirmation 超时阈值（默认 24h）。
   * @returns 恢复动作。
   */
  static classify(job: ImportJobRecord, now: number, ttlMs: number): RecoveryAction {
    // 当前状态
    const state: ImportState = job.state;
    if (state === 'awaiting_confirmation') {
      // 超过 TTL 未确认 → 自动取消；否则保持挂起
      if (now - job.startedAt > ttlMs) {
        return { jobId: job.id, kind: 'cancel', detail: 'awaiting-confirmation-timeout' };
      }
      return { jobId: job.id, kind: 'keep-suspended' };
    }
    if (state === 'selected') {
      return { jobId: job.id, kind: 'cancel', detail: 'selected-interrupted' };
    }
    if (PRE_INDEX_STATES.indexOf(state) >= 0) {
      return { jobId: job.id, kind: 'fail-retryable', errorCode: PRE_INDEX_INTERRUPT_CODE, detail: 'interrupted-pre-index' };
    }
    if (INDEXING_STATES.indexOf(state) >= 0) {
      return { jobId: job.id, kind: 'rollback-fail', errorCode: INDEX_INTERRUPT_CODE, detail: 'interrupted-during-index' };
    }
    // 终态（防御性）：无操作
    return { jobId: job.id, kind: 'keep-suspended' };
  }

  /**
   * 执行重启恢复：扫描非终态任务、逐个分类并落地清理/状态推进。
   * @param now 当前时间戳（epoch ms）。
   * @param ttlMs awaiting_confirmation 超时阈值（缺省 24h）。
   * @returns 已采取的恢复动作数组（供日志/诊断）。
   */
  async recover(now: number, ttlMs?: number): Promise<RecoveryAction[]> {
    // 实际超时阈值
    const ttl: number = ttlMs !== undefined ? ttlMs : AWAITING_TTL_MS;
    // 扫描非终态任务
    const jobs: ImportJobRecord[] = await this.jobRepo.listByStates(NON_TERMINAL_STATES);
    // 已采取动作
    const actions: RecoveryAction[] = [];
    for (let i: number = 0; i < jobs.length; i++) {
      // 当前任务的恢复动作
      const action: RecoveryAction = ImportRecovery.classify(jobs[i], now, ttl);
      await this.apply(jobs[i], action, now);
      actions.push(action);
    }
    return actions;
  }

  /**
   * 落地单个恢复动作（清理暂存 + 守卫式 transition）。
   * @param job 任务记录。
   * @param action 恢复动作。
   * @param now 当前时间戳（epoch ms）。
   */
  private async apply(job: ImportJobRecord, action: RecoveryAction, now: number): Promise<void> {
    if (action.kind === 'keep-suspended') {
      return;
    }
    // 清理暂存目录（取消/失败统一清理，§2.6）
    await this.cleanupStaging(job.id);
    if (action.kind === 'cancel') {
      // 自动取消：释放 URI 授权 + 置 cancelled（不写 error_code，保留脱敏摘要，记 completed_at）
      await this.releaseUri(job.sourceUriHash);
      await this.jobRepo.transition(job.id, 'cancelled', {
        stage: 'cancelled', errorDetail: action.detail, completedAt: now
      });
      return;
    }
    // fail-retryable / rollback-fail：置 failed（写错误码 + 脱敏详情；不设 completed_at 以便重试复用）
    await this.jobRepo.transition(job.id, 'failed', {
      stage: 'failed',
      errorCode: action.errorCode,
      errorDetail: action.detail !== undefined ? action.detail : action.errorCode,
      warningCount: 0
    });
  }

  /**
   * 清理某任务暂存目录（最佳努力，吞掉清理自身异常）。
   * @param jobId 任务 ID。
   */
  private async cleanupStaging(jobId: string): Promise<void> {
    try {
      const staging: StagingArea = new StagingArea(this.fs, this.tempDir, jobId);
      await staging.cleanup();
    } catch (ignore) {
      // 清理失败仅静默：不输出敏感路径（CLAUDE.md §5）
    }
  }

  /**
   * 释放持久化 URI 授权（最佳努力，吞掉释放自身异常）。
   * @param sourceUriHash 来源 URI 哈希。
   */
  private async releaseUri(sourceUriHash: string): Promise<void> {
    try {
      await this.uriPermissions.release(sourceUriHash);
    } catch (ignore) {
      // 释放失败仅静默：授权泄漏不阻塞启动主流程
    }
  }
}
