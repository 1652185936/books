/**
 * 导入服务编排（F02，《04-接口与DTO契约》§2 `ImportService`；LLD §2.3 状态机 / §6.2 P-F02）。
 *
 * 本轮（F02）只实现 `ImportService` 契约中的 **`create(sourceUri)`** 与 **`cancel(jobId)`** 两个方法，
 * 作为「导入选择页 → 校验页」的薄封装：纯编排，**不碰 SQL**（一律经 `ImportJobRepository`，CLAUDE.md §5）。
 * `runValidation` / `commit` 是后续轮（F03+）职责，本轮不实现以免破坏类型，仅在文末以 TODO 占位说明。
 *
 * `create` 职责（LLD §2.3：create 后任务进 `selected`）：
 * 1. 生成 `jobId`（注入 `IdFactory`，与导入内核一致）；
 * 2. 经端口探测来源脱敏文件名/大小（`SourceProbePort`，不持原 URI）、计算 URI 哈希（`UriHasher`，§3.22 仅存哈希）；
 * 3. 经端口持久化 URI 授权（`UriPermissionPort.persist`，R-015 支持重试重开）；
 * 4. （可选单飞守卫，§8.1 / §8）：升级场景已知 `packageId` 时，拒绝同包并发活动任务（IMP-014 复用「重复版本」语义不当，
 *    单飞冲突用通用 `DB_WRITE_FAILED` + 脱敏 detail，文案走兜底状态键）；首次导入解压前无 `packageId`，跳过守卫；
 * 5. 经 `ImportJobRepository.insertJob` 落 `state='selected'`、`progress=0` 起始行。
 *
 * `cancel` 职责（R-014）：委托既有 `ImportLifecycle.cancel`（清理暂存 + 释放授权 + 置 `cancelled`），不重复实现。
 *
 * 纯编排、零 `@ohos.*` 依赖：所有设备 IO（文件探测/哈希/URI 授权/文件系统）均经接口端口注入，
 * 生产适配器在应用装配处提供。本模块连同端口可用内存假实现 + 真 SQLite 单测（见 `.ralph/f02-test/`）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：生产端口适配器依赖 `@ohos.file.*` / `@kit.CryptoArchitectureKit` /
 * URI 授权能力，形态以 API 12 为准；本模块自身不含 SDK 调用。
 */
import { Id } from '../domain/entities/common';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import { IdFactory } from './import/ContentMapper';
import { SourceProbePort, SourceFileMeta } from './StorageProbe';
import { UriPermissionPort } from './import/ImportLifecycle';
import { ImportLifecycle } from './import/ImportLifecycle';
import { ImportJobRepository, ImportJobRecord } from '../repositories/ImportJobRepository';

/**
 * URI 哈希端口：把来源 URI 折算为稳定哈希（§3.22 `source_uri_hash`，绝不持原 URI）。
 * 生产实现以 `@kit.CryptoArchitectureKit`（SHA-256）适配；单测以确定性假实现注入。
 */
export interface UriHasher {
  /**
   * 计算来源 URI 的稳定哈希（十六进制小写）。
   * @param sourceUri 来源文件 URI（仅在本端口内部使用，不向上层/日志泄漏）。
   * @returns URI 哈希字符串。
   */
  hashUri(sourceUri: string): Promise<string>;
}

/**
 * 持久化 URI 授权写入端口（R-015）：`create` 须保存可重开的持久化授权（不能仅存 `source_uri_hash`），
 * 以支持失败重试时重新打开来源。释放在 `ImportLifecycle`（abandon/终态）经既有 `UriPermissionPort.release` 完成。
 * 生产实现以 `@ohos.app.ability.UriPermissionManager` 等价能力适配；单测以假实现注入。
 */
export interface UriPersistPort {
  /**
   * 持久化某来源 URI 的可重开授权（幂等，最佳努力）。
   * @param sourceUri 来源文件 URI（仅在本端口内部使用，不向上层/日志泄漏）。
   * @returns 完成的 Promise。
   */
  persist(sourceUri: string): Promise<void>;
}

/**
 * 导入服务（F02 切片）。实现 `ImportService.create` / `ImportService.cancel`；其余契约方法属后续轮。
 */
export class ImportService {
  /** 导入任务仓储（状态机持久化边界，页面/服务不碰 SQL）。 */
  private readonly jobRepo: ImportJobRepository;
  /** 生命周期编排器（取消/重试/放弃；本服务的 cancel 委托其 cancel）。 */
  private readonly lifecycle: ImportLifecycle;
  /** 内部主键生成端口（与导入内核同源，便于确定性单测）。 */
  private readonly ids: IdFactory;
  /** 来源文件探测端口（脱敏文件名/大小）。 */
  private readonly sourceProbe: SourceProbePort;
  /** URI 哈希端口（落 `source_uri_hash`，不持原 URI）。 */
  private readonly uriHasher: UriHasher;
  /** 持久化 URI 授权写入端口（R-015 支持重试重开）。 */
  private readonly uriPersist: UriPersistPort;

  /**
   * @param jobRepo 导入任务仓储。
   * @param lifecycle 导入生命周期编排器（cancel 委托）。
   * @param ids 内部主键生成端口。
   * @param sourceProbe 来源文件探测端口。
   * @param uriHasher URI 哈希端口。
   * @param uriPersist 持久化 URI 授权写入端口。
   */
  constructor(
    jobRepo: ImportJobRepository,
    lifecycle: ImportLifecycle,
    ids: IdFactory,
    sourceProbe: SourceProbePort,
    uriHasher: UriHasher,
    uriPersist: UriPersistPort) {
    this.jobRepo = jobRepo;
    this.lifecycle = lifecycle;
    this.ids = ids;
    this.sourceProbe = sourceProbe;
    this.uriHasher = uriHasher;
    this.uriPersist = uriPersist;
  }

  /**
   * 创建导入任务（《04》§2 `ImportService.create`；LLD §2.3：create 后进 `selected`）。
   * 纯编排：探测来源 → 计算/持久化授权 → 落 `import_jobs(state='selected')`。不解压、不解析 packageId。
   * @param sourceUri 学习包来源 URI（DocumentViewPicker 返回）。
   * @param now 当前时间戳（epoch ms，写 `started_at`；UI 触发时取系统时钟，便于单测注入）。
   * @returns 新建导入任务 ID。
   * @throws AppError 来源探测/哈希/写库失败时抛出（可转 AppError 的领域错误，04 §1）。
   */
  async create(sourceUri: string, now: number): Promise<Id> {
    // 生成任务 ID（单一安全路径段，后续派生 temp/import/<jobId>）
    const jobId: Id = this.ids.newId();
    // 探测来源脱敏元信息（文件名/大小；不回传/不记录原 URI）
    const meta: SourceFileMeta = await this.sourceProbe.probeSource(sourceUri);
    // 计算 URI 哈希（仅存哈希，§3.22）
    const sourceUriHash: string = await this.uriHasher.hashUri(sourceUri);
    // 持久化可重开授权（R-015；最佳努力，失败由端口内部决定是否抛出）
    await this.uriPersist.persist(sourceUri);
    // 组装起始行：state=selected、progress=0、warning_count=0、current_stage='selected'
    const record: ImportJobRecord = {
      id: jobId,
      sourceName: meta.displayName,
      sourceSize: meta.sizeBytes >= 0 ? meta.sizeBytes : 0,
      sourceUriHash: sourceUriHash,
      state: 'selected',
      currentStage: 'selected',
      progress: 0,
      warningCount: 0,
      startedAt: now
    };
    // 落库（仓储内单事务写入；非法/失败抛 AppError）
    await this.jobRepo.insertJob(record);
    return jobId;
  }

  /**
   * 单飞守卫（§8.1 / §8：同一 `packageId` 同时只允许一个活动任务）。
   * 供升级场景在已知 `packageId` 后调用：存在同包非终态在飞任务则拒绝，避免并发导入/升级竞争同一书。
   * 首次导入在解压出 `packageId` 前无需调用（此时同包并发无从判定）。
   * @param packageId 学习包外部包 ID。
   * @param jobId 当前任务 ID（排除自身）。
   * @returns 完成的 Promise（无冲突时静默通过）。
   * @throws AppError 存在同包活动任务时抛出 `DB_WRITE_FAILED`（脱敏 detail）。
   */
  async assertSingleFlight(packageId: string, jobId: Id): Promise<void> {
    // 同包非终态在飞任务数（排除自身）
    const activeCount: number = await this.jobRepo.countActiveJobsForPackage(packageId, jobId);
    if (activeCount > 0) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `single-flight-conflict:${activeCount}` });
    }
  }

  /**
   * 取消导入任务（《04》§2 `ImportService.cancel`；R-014）。委托既有 `ImportLifecycle.cancel`，
   * 后者完成：清理暂存目录 + 释放 URI 授权 + 置 `state='cancelled'`（不写错误码/不计警告）。
   * @param jobId 导入任务 ID。
   * @param now 当前时间戳（epoch ms，写 `completed_at`；UI 触发时取系统时钟）。
   * @returns 完成的 Promise。
   * @throws AppError 任务不存在、已终态或已进入不可取消阶段时抛出（由 lifecycle 守卫）。
   */
  cancel(jobId: Id, now: number): Promise<void> {
    // 直接委托生命周期编排器（R-014 单一真值，不重复实现取消语义）
    return this.lifecycle.cancel(jobId, now);
  }

  // TODO(F03+)：`runValidation(jobId)` / `commit(jobId, mode)` 属后续轮职责，本切片不实现，
  // 以免在 selected 之外越权推进状态机或触碰校验/落库内核。届时按《04》§2 补齐契约方法。
}
