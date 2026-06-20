/**
 * 导入落库编排（P1-4，LLD §2.4 step11~step13）。
 *
 * 把「已通过 §2.4 step1~step10 校验、确认导入（awaiting_confirmation）」的任务推进到 `completed`：
 *   - step11 `indexing`：用 `ContentMapper`（纯函数）把解析后的协议 JSON 构建为完整 `BookIndexModel`
 *     （内容校验不变量 IMP-010/011/012/020 在此暴露）。
 *   - step12 `promoting_to_final` + step13 `committing`：在 `BookContentRepository.indexBook` 的**单个事务**内
 *     落库全部内容行、事务内重算 `chapter_count`，并在提交前把暂存目录原子提升到正式目录；任一步失败整体回滚
 *     （绝不残留半本书，§2.6）。
 *   - 成功后置 `completed`（写回 packageId / warning_count / completed_at）。
 *
 * 状态推进经 `ImportJobRepository.transition`（守卫式、合法边校验）；本编排沿 §2.3 合法路径
 * `awaiting_confirmation → indexing → promoting_to_final → committing → completed` 逐步标记，
 * 真正的「DB 落库 + 目录提升 + 提交」三者作为一个原子操作在 `committing` 标记后执行（relationalStore 单事务约束下
 * 无法把细粒度状态标记嵌入同一事务，故标记在原子操作前后包裹；崩溃恢复语义归 P1-5 §2.6）。
 *
 * 错误映射（R-056）：内容校验类错误（IMP-010/011/012/020）按原码终态拒绝；建索引/落库失败兜底 IMP-019；
 * 目录提升或提交失败记 IMP-016。失败统一清理本次正式目录（新导入下安全：该目录此前不存在），并置 `failed`。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore 与 `@ohos.file.fs`（经 `ImportFs` 端口）以 API 12 为准。
 */
import { AppError } from '../../domain/entities/common';
import { AppErrors } from '../../utils/AppErrors';
import { ImportJobRepository } from '../../repositories/ImportJobRepository';
import { BookContentRepository } from '../../repositories/BookContentRepository';
import { ImportStateMachine } from './ImportStateMachine';
import { ImportPaths, ImportFs } from './ImportStaging';
import { ContentMapper, BookIndexModel, MapInput } from './ContentMapper';

/** 落库结果（供 `ImportService.commit` 组装 `ImportResult`，《04》§2）。 */
export interface LandOutcome {
  /** 内部书籍 ID。 */
  bookId: string;
  /** 学习包外部包 ID。 */
  packageId: string;
  /** 内容版本。 */
  contentVersion: string;
  /** 章节数（事务内重算）。 */
  chapterCount: number;
  /** 警告累计数（IMP-015）。 */
  warningCount: number;
  /** 完成时间（epoch ms）。 */
  completedAt: number;
}

/** 默认建索引/落库失败兜底码（IMP-019）。 */
const DEFAULT_INDEX_FAILURE_CODE: string = 'IMP-019';

/**
 * 导入落库编排器。
 */
export class ImportIndexer {
  /** 导入任务仓储（状态机持久化）。 */
  private readonly jobRepo: ImportJobRepository;
  /** 书籍内容落库仓储。 */
  private readonly contentRepo: BookContentRepository;
  /** 文件系统端口（暂存→正式提升）。 */
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
   * 执行 step11~13：建索引模型 → 落库 + 原子提升 + 提交 → completed。
   * @param jobId 导入任务 ID（须处于 `awaiting_confirmation`）。
   * @param mapInput 映射输入（含 bookId / now / ids / 解析后 JSON / 哈希 / 大小）。
   * @param stagingRoot 暂存根目录绝对路径（提升源）。
   * @returns 落库结果。
   * @throws AppError 任一阶段失败时抛出（任务已置 failed、正式目录已清理）。
   */
  async land(jobId: string, mapInput: MapInput, stagingRoot: string): Promise<LandOutcome> {
    // 正式目录路径（提升目标）
    const bookRoot: string = ImportPaths.bookRoot(this.filesDir, mapInput.bookId);
    const packageDir: string = ImportPaths.packageDir(this.filesDir, mapInput.bookId);
    try {
      // step11：进入建索引，构建内容索引模型（纯函数，可能抛 IMP-010/011/012/020）
      await this.jobRepo.transition(jobId, 'indexing', { stage: 'indexing', progress: 0.9 });
      const model: BookIndexModel = ContentMapper.map(mapInput);

      // step12/13 标记：进入目录提升与提交阶段
      await this.jobRepo.transition(jobId, 'promoting_to_final', { stage: 'promoting-to-final', progress: 0.95 });
      await this.jobRepo.transition(jobId, 'committing', { stage: 'committing', progress: 0.98 });

      // 原子落库 + 提交前提升（失败整体回滚）
      const chapterCount: number = await this.contentRepo.indexBook(model, (): Promise<void> => {
        return this.promote(stagingRoot, bookRoot, packageDir);
      });

      // step13 完成 → completed（写回 packageId / 警告数 / 完成时间）
      await this.jobRepo.transition(jobId, 'completed', {
        stage: 'completed', progress: 1, warningCount: model.warningCount,
        packageId: model.book.packageId, completedAt: model.book.importedAt
      });

      return {
        bookId: model.book.id,
        packageId: model.book.packageId,
        contentVersion: model.book.contentVersion,
        chapterCount: chapterCount,
        warningCount: model.warningCount,
        completedAt: model.book.importedAt
      };
    } catch (cause) {
      // 归一为领域错误（非 AppError 兜底 IMP-019）
      const error: AppError = AppErrors.from(cause, DEFAULT_INDEX_FAILURE_CODE);
      // 清理本次正式目录（新导入下安全：该目录此前不存在）+ 置 failed
      await this.failJob(jobId, error, bookRoot);
      throw error;
    }
  }

  /**
   * 暂存目录原子提升到正式包目录（§2.4 step12，在落库事务提交前执行）。
   * 失败时清理可能的半成品并归一为 IMP-016（提交/提升失败）。
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
      throw ImportStateMachine.buildStageFailure('committing', { detail: 'promote-failed' });
    }
  }

  /**
   * 失败处理：清理正式目录并把任务置 `failed`（携带错误码/脱敏详情/可重试标志）。
   * @param jobId 任务 ID。
   * @param error 领域错误。
   * @param bookRoot 正式书籍根目录绝对路径。
   */
  private async failJob(jobId: string, error: AppError, bookRoot: string): Promise<void> {
    // 清理半成品正式目录（新导入：失败即不应残留任何已提升内容）
    await this.safeRemove(bookRoot);
    try {
      // 守卫式置 failed（当前态 indexing/promoting_to_final/committing → failed 均为合法边）
      await this.jobRepo.transition(jobId, 'failed', {
        stage: 'failed',
        errorCode: error.code,
        errorDetail: error.detail !== undefined ? error.detail : error.code,
        warningCount: 0
      });
    } catch (ignore) {
      // 状态写入失败（如调用方未把任务置于可进入 indexing 的状态导致守卫拒绝）不得掩盖原业务错误：
      // 静默吞掉本次状态更新异常，由 land() 继续上抛真实失败原因。
    }
  }

  /**
   * 最佳努力删除路径，吞掉删除自身的异常（清理失败不应掩盖业务原错误）。
   * @param path 绝对路径。
   */
  private async safeRemove(path: string): Promise<void> {
    try {
      await this.fs.remove(path);
    } catch (ignore) {
      // 清理失败仅静默：不输出敏感路径（CLAUDE.md §5），原业务错误已由调用方持有
    }
  }
}
