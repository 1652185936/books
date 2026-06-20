/**
 * 升级（upgrade）落库编排（P1-5，LLD §2.7 R-016）。
 *
 * `commit(jobId, 'upgrade')` 在 `indexing` 与 `committing` 之间插入「回滚点 + 目录切换」（§2.7）：
 *   1. 单飞守卫（§8）：同一 `package_id` 仅允许一个进行中导入/升级任务，否则拒绝。
 *   2. `books.status='updating'`：升级期书架显示「更新中」、不可进入学习（§2.7）。
 *   3. `snapshot_old`：把旧 `files/books/<bookId>` 重命名为回滚点（§2.7 step1）。
 *   4. 按 `external_id` 原地写入新内容（`planUpgrade` + `BookContentRepository.upgradeBook`，《06》§10），
 *      内部主键稳定、历史答题/错题不丢失（FR-F03-06、验收 5）。
 *   5. `promoting_to_final`：暂存目录原子切换到正式目录（§2.7 step3），与 DB 提交同一事务原子完成。
 *   6. 成功：删除回滚点、`books.status='ready'`（由 upgradeBook 落库）、任务 → `completed`。
 *   7. 任一步失败 → `restore_old`（§2.7 step4）：删除新目录、恢复回滚点、回滚事务，`books.status` 回到 `ready`，
 *      任务 → `failed`；绝不残留半本书（§2.6）。
 *
 * 状态推进经 `ImportJobRepository.transition` 守卫式（合法边校验，复用与新导入相同的 indexing→…→completed 边）。
 * relationalStore 单事务不可嵌套：DB 原地 UPDATE + 目录提升作为一个事务原子完成（提升在提交前钩子内执行）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore 与 `@ohos.file.fs`（经 `ImportFs` 端口）以 API 12 为准；
 * 原地落库 SQL 已用 Python sqlite3 等价端口执行回归（见 `.ralph/lifecycle-test`）。
 */
import { AppError } from '../../domain/entities/common';
import { AppErrors, DB_WRITE_FAILED } from '../../utils/AppErrors';
import { ImportJobRepository } from '../../repositories/ImportJobRepository';
import { BookContentRepository } from '../../repositories/BookContentRepository';
import { ImportStateMachine } from './ImportStateMachine';
import { ImportPaths, ImportFs } from './ImportStaging';
import { ContentMapper, BookIndexModel, MapInput } from './ContentMapper';
import { planUpgrade, UpgradePlan, ExistingIndex } from './UpgradePlan';
import { LandOutcome } from './ImportIndexer';

/** 回滚点目录后缀（旧正式目录重命名为 `<bookRoot><suffix>`，§2.7 snapshot_old）。 */
const ROLLBACK_SUFFIX: string = '.rollback';
/** 升级提升/提交失败兜底码（IMP-016，§2.5）。 */
const UPGRADE_COMMIT_FAILURE_CODE: string = 'IMP-016';
/** 升级建索引/落库失败兜底码（IMP-019，§2.5）。 */
const UPGRADE_INDEX_FAILURE_CODE: string = 'IMP-019';

/**
 * 升级落库编排器。
 */
export class UpgradeIndexer {
  /** 导入任务仓储（状态机持久化）。 */
  private readonly jobRepo: ImportJobRepository;
  /** 书籍内容落库仓储（含升级原地 UPDATE）。 */
  private readonly contentRepo: BookContentRepository;
  /** 文件系统端口（快照/提升/恢复）。 */
  private readonly fs: ImportFs;
  /** 运行期文件目录绝对路径（`context.filesDir`）。 */
  private readonly filesDir: string;

  /**
   * @param jobRepo 导入任务仓储。
   * @param contentRepo 书籍内容落库仓储。
   * @param fs 文件系统端口。
   * @param filesDir 运行期文件目录绝对路径。
   */
  constructor(jobRepo: ImportJobRepository, contentRepo: BookContentRepository, fs: ImportFs, filesDir: string) {
    this.jobRepo = jobRepo;
    this.contentRepo = contentRepo;
    this.fs = fs;
    this.filesDir = filesDir;
  }

  /**
   * 执行升级 step（§2.7）：单飞守卫 → updating → snapshot → 原地落库 + 原子提升 → completed；失败 restore。
   * @param jobId 导入任务 ID（须处于 `awaiting_confirmation`）。
   * @param mapInput 映射输入（其 `bookId` **必须**为旧书内部 id，使新模型锚定旧书）。
   * @param stagingRoot 暂存根目录绝对路径（提升源）。
   * @returns 升级落库结果。
   * @throws AppError 任一阶段失败时抛出（已 restore 旧目录、任务置 failed、status 回 ready）。
   */
  async upgrade(jobId: string, mapInput: MapInput, stagingRoot: string): Promise<LandOutcome> {
    // 旧书内部 id（= mapInput.bookId，调用方经 findBookByPackageId 解析后注入）
    const bookId: string = mapInput.bookId;
    // 正式目录与回滚点路径
    const bookRoot: string = ImportPaths.bookRoot(this.filesDir, bookId);
    const packageDir: string = ImportPaths.packageDir(this.filesDir, bookId);
    const rollbackRoot: string = bookRoot + ROLLBACK_SUFFIX;
    // 是否已建立回滚点（决定失败时是否需恢复）
    let snapshotTaken: boolean = false;

    try {
      // step11：进入建索引，构建新内容模型（纯函数，可能抛 IMP-010/011/012/020）
      await this.jobRepo.transition(jobId, 'indexing', { stage: 'indexing', progress: 0.9 });
      const model: BookIndexModel = ContentMapper.map(mapInput);

      // §8 单飞守卫：同一 package_id 不得有其它进行中任务
      const inflight: number = await this.jobRepo.countActiveJobsForPackage(model.book.packageId, jobId);
      if (inflight > 0) {
        throw AppErrors.create(DB_WRITE_FAILED, { detail: 'package-import-in-flight' });
      }

      // 读旧索引锚点并规划原地升级（按 external_id 重映射，《06》§10）
      const existing: ExistingIndex = await this.contentRepo.readExistingIndex(bookId);
      const plan: UpgradePlan = planUpgrade(model, existing);

      // §2.7 step：书架置「更新中」
      await this.contentRepo.setBookStatus(bookId, 'updating', mapInput.now);

      // §2.7 step1 snapshot_old：旧正式目录重命名为回滚点
      await this.fs.move(bookRoot, rollbackRoot);
      snapshotTaken = true;

      // step12/13 标记：进入目录提升与提交阶段
      await this.jobRepo.transition(jobId, 'promoting_to_final', { stage: 'promoting-to-final', progress: 0.95 });
      await this.jobRepo.transition(jobId, 'committing', { stage: 'committing', progress: 0.98 });

      // 原地落库 + 提交前原子提升（暂存→新正式目录），失败整体回滚
      const chapterCount: number = await this.contentRepo.upgradeBook(plan, (): Promise<void> => {
        return this.promote(stagingRoot, bookRoot, packageDir);
      });

      // 成功：删除回滚点（最佳努力），任务 → completed
      await this.safeRemove(rollbackRoot);
      await this.jobRepo.transition(jobId, 'completed', {
        stage: 'completed', progress: 1, warningCount: model.warningCount,
        packageId: model.book.packageId, completedAt: mapInput.now
      });

      return {
        bookId: bookId,
        packageId: model.book.packageId,
        contentVersion: model.book.contentVersion,
        chapterCount: chapterCount,
        warningCount: model.warningCount,
        completedAt: mapInput.now
      };
    } catch (cause) {
      // 归一为领域错误（非 AppError：提升后属提交期失败 IMP-016，否则建索引失败 IMP-019）
      const fallback: string = snapshotTaken ? UPGRADE_COMMIT_FAILURE_CODE : UPGRADE_INDEX_FAILURE_CODE;
      const error: AppError = AppErrors.from(cause, fallback);
      // §2.7 step4 restore_old：删新目录、恢复回滚点、status 回 ready、任务置 failed
      await this.restoreOld(jobId, bookId, bookRoot, packageDir, rollbackRoot, stagingRoot, snapshotTaken, error, mapInput.now);
      throw error;
    }
  }

  /**
   * 暂存目录原子提升到正式包目录（§2.7 step3，在原地落库事务提交前执行）。
   * @param stagingRoot 暂存根目录绝对路径。
   * @param bookRoot 正式书籍根目录绝对路径。
   * @param packageDir 正式包目录绝对路径（提升目标）。
   * @throws AppError 提升失败时抛出 IMP-016。
   */
  private async promote(stagingRoot: string, bookRoot: string, packageDir: string): Promise<void> {
    try {
      // 确保正式书籍根目录存在，再把暂存整体移动为正式包目录
      await this.fs.mkdirs(bookRoot);
      await this.fs.move(stagingRoot, packageDir);
    } catch (moveErr) {
      // 清理可能的部分提升（最佳努力，不掩盖原错误）
      await this.safeRemove(packageDir);
      throw ImportStateMachine.buildStageFailure('committing', { detail: 'upgrade-promote-failed' });
    }
  }

  /**
   * 失败恢复（§2.7 step4 restore_old）：删除新正式目录、恢复回滚点旧目录、`status` 回 `ready`、任务置 `failed`。
   * 全部清理动作均最佳努力（吞掉清理自身异常，不掩盖原业务错误）。
   * @param jobId 任务 ID。
   * @param bookId 旧书内部 id。
   * @param bookRoot 正式书籍根目录绝对路径。
   * @param packageDir 正式包目录绝对路径。
   * @param rollbackRoot 回滚点目录绝对路径。
   * @param stagingRoot 暂存根目录绝对路径。
   * @param snapshotTaken 是否已建立回滚点（决定是否需恢复目录）。
   * @param error 领域错误（写入 failed 的码与脱敏详情）。
   * @param now 时间戳（status 回写）。
   */
  private async restoreOld(
    jobId: string, bookId: string, bookRoot: string, packageDir: string, rollbackRoot: string,
    stagingRoot: string, snapshotTaken: boolean, error: AppError, now: number): Promise<void> {
    if (snapshotTaken) {
      // 删除可能已部分提升的新正式目录
      await this.safeRemove(bookRoot);
      // 恢复回滚点旧目录（若存在）
      try {
        if (await this.fs.exists(rollbackRoot)) {
          await this.fs.move(rollbackRoot, bookRoot);
        }
      } catch (ignore) {
        // 恢复失败仅静默：不输出敏感路径（CLAUDE.md §5）；原业务错误已由调用方持有
      }
    }
    // 清理残留暂存（提升可能已部分消费）
    await this.safeRemove(stagingRoot);
    // status 回 ready（DB 事务已回滚 → 旧内容仍在；目录已恢复 → 一致）
    try {
      await this.contentRepo.setBookStatus(bookId, 'ready', now);
    } catch (ignore) {
      // 状态回写失败仅静默：重启恢复会再次扫描 updating 书（归后续迭代）
    }
    // 任务置 failed（守卫式；当前态 indexing/promoting_to_final/committing → failed 均合法）
    try {
      await this.jobRepo.transition(jobId, 'failed', {
        stage: 'failed',
        errorCode: error.code,
        errorDetail: error.detail !== undefined ? error.detail : error.code,
        warningCount: 0
      });
    } catch (ignore) {
      // 守卫拒绝（当前态非可入 failed）不得掩盖原业务错误：静默吞掉，由 upgrade() 继续上抛
    }
  }

  /**
   * 最佳努力删除路径，吞掉删除自身异常（清理失败不应掩盖业务原错误）。
   * @param path 绝对路径。
   */
  private async safeRemove(path: string): Promise<void> {
    try {
      await this.fs.remove(path);
    } catch (ignore) {
      // 清理失败仅静默：不输出敏感路径（CLAUDE.md §5）
    }
  }
}
