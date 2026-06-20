/**
 * 导入生命周期编排：取消 / 重试 / 放弃（P1-5，LLD §2.6 R-014/R-015）。
 *
 * - **取消（R-014）**：`selected`、`copying`、`validating_*`、`extracting_to_staging`、`awaiting_confirmation` 任一
 *   状态均可转入 `cancelled`（对应 FR-F02-05「写入数据库前可取消」）；`indexing` 及之后不可取消（§2.6）。
 *   进入 `cancelled` 统一清理：删除暂存目录、释放 URI 授权、置 `state=cancelled` 并保留脱敏摘要；
 *   取消不写 `error_code`、不计入 `warning_count`（§2.6）。
 * - **重试（R-015）**：仅当处于 `failed` 且错误码为**可重试**（IMP-013/016/017/019）时允许 `failed → copying`，
 *   **复用同一 `jobId`**，清理上次暂存目录后重建；终态拒绝（内容类错误）不可重试。
 * - **放弃（R-015）**：终态拒绝或用户放弃后释放持久化 URI 授权并清理暂存；可取消态一并转 `cancelled`。
 *
 * 状态推进经 `ImportJobRepository.transition` 守卫式（合法边校验）。本编排不持时间/随机源：时间戳由调用方注入
 * （`now`，UI 触发时取系统时钟），便于单测。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore（经仓储）、`ImportFs`/URI 授权端口生产实现以 API 12 为准。
 */
import { AppErrors, DB_WRITE_FAILED } from '../../utils/AppErrors';
import { ImportJobRepository, ImportJobRecord } from '../../repositories/ImportJobRepository';
import { ImportStateMachine } from './ImportStateMachine';
import { ImportFs, StagingArea } from './ImportStaging';

/**
 * 持久化 URI 授权端口（R-015）：`ImportService.create` 保存可重开的持久化 URI 授权（不能仅存 `source_uri_hash`），
 * 终态拒绝或用户放弃后释放该授权。生产实现以 `@ohos.app.ability.UriPermissionManager` 等价能力适配；单测以假实现注入。
 */
export interface UriPermissionPort {
  /**
   * 释放某来源 URI 的持久化授权（最佳努力，幂等）。
   * @param sourceUriHash 来源 URI 的哈希（`import_jobs.source_uri_hash`，不持原 URI）。
   * @returns 完成的 Promise。
   */
  release(sourceUriHash: string): Promise<void>;
}

/**
 * 导入生命周期编排器。
 */
export class ImportLifecycle {
  /** 导入任务仓储（状态机持久化）。 */
  private readonly jobRepo: ImportJobRepository;
  /** 文件系统端口（暂存清理/重建）。 */
  private readonly fs: ImportFs;
  /** 运行期临时目录绝对路径（`context.tempDir`）。 */
  private readonly tempDir: string;
  /** 持久化 URI 授权端口。 */
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
   * 取消导入任务（R-014）：清理暂存 + 释放授权 + 置 `cancelled`（不写错误码/不计警告）。
   * @param jobId 任务 ID。
   * @param now 当前时间戳（epoch ms，写 completed_at）。
   * @returns 完成的 Promise。
   * @throws AppError 任务不存在、已终态或已进入不可取消阶段（indexing+）时抛出。
   */
  async cancel(jobId: string, now: number): Promise<void> {
    // 任务记录
    const job: ImportJobRecord | undefined = await this.jobRepo.getJob(jobId);
    if (job === undefined) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `import-job-not-found:${jobId}` });
    }
    // 已取消：幂等返回
    if (job.state === 'cancelled') {
      return;
    }
    // 已终态（completed/failed）：取消无效（failed 请用 retry/abandon）
    if (ImportStateMachine.isTerminal(job.state)) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `cannot-cancel-terminal:${job.state}` });
    }
    // 已进入不可取消阶段（indexing 及之后，§2.6）
    if (!ImportStateMachine.isCancellable(job.state)) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `not-cancellable:${job.state}` });
    }
    // 清理暂存目录 + 释放 URI 授权（均最佳努力，不掩盖主流程）
    await this.cleanupStaging(jobId);
    await this.releaseUri(job.sourceUriHash);
    // 置 cancelled：不写 error_code、保留原 warning_count（不传即沿用），记 completed_at
    await this.jobRepo.transition(jobId, 'cancelled', { stage: 'cancelled', completedAt: now });
  }

  /**
   * 重试导入任务（R-015）：仅可重试错误码允许 `failed → copying`，复用 jobId，重建暂存。
   * @param jobId 任务 ID。
   * @returns 完成的 Promise。
   * @throws AppError 任务不存在、非 `failed`、或为终态拒绝（不可重试）时抛出。
   */
  async retry(jobId: string): Promise<void> {
    // 任务记录
    const job: ImportJobRecord | undefined = await this.jobRepo.getJob(jobId);
    if (job === undefined) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `import-job-not-found:${jobId}` });
    }
    // 重试要求处于 failed
    if (job.state !== 'failed') {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `retry-requires-failed:${job.state}` });
    }
    // 终态拒绝（内容类错误）不可重试
    if (job.errorCode === undefined || !ImportStateMachine.isRetryable(job.errorCode)) {
      throw AppErrors.create(DB_WRITE_FAILED, {
        detail: `not-retryable:${job.errorCode !== undefined ? job.errorCode : 'none'}`
      });
    }
    // 重建干净暂存目录（清上次残留后重建，复用同一 jobId）
    const staging: StagingArea = new StagingArea(this.fs, this.tempDir, jobId);
    await staging.prepare();
    // failed → copying：清空错误码/详情（不传即写 null），进度归零
    await this.jobRepo.transition(jobId, 'copying', { stage: 'copying', progress: 0 });
  }

  /**
   * 放弃导入任务（R-015）：释放 URI 授权 + 清理暂存；若处于可取消态则一并置 `cancelled`。
   * 用于终态拒绝后用户放弃，或用户主动放弃进行中任务。
   * @param jobId 任务 ID。
   * @param now 当前时间戳（epoch ms）。
   * @returns 完成的 Promise。
   */
  async abandon(jobId: string, now: number): Promise<void> {
    // 任务记录（不存在则无事可做）
    const job: ImportJobRecord | undefined = await this.jobRepo.getJob(jobId);
    if (job === undefined) {
      return;
    }
    // 释放授权 + 清理暂存（最佳努力）
    await this.releaseUri(job.sourceUriHash);
    await this.cleanupStaging(jobId);
    // 可取消态：一并置 cancelled（终态保留原状，仅完成资源释放）
    if (ImportStateMachine.isCancellable(job.state)) {
      await this.jobRepo.transition(jobId, 'cancelled', { stage: 'cancelled', completedAt: now });
    }
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
      // 释放失败仅静默：授权泄漏不阻塞用户主流程，可由后续清理回收
    }
  }
}
