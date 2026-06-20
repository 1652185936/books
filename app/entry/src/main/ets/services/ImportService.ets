/**
 * 导入服务编排（F02/F03，《04-接口与DTO契约》§2 `ImportService`；LLD §2.3 状态机 / §2.4 校验顺序 / §6.2 P-F02 / §6.3 P-F03）。
 *
 * F02 实现 **`create`** / **`cancel`**；F03 在其后追加 **`runValidation(jobId)`**（异步生成器，流式校验进度）
 * 与 **`commit(jobId, mode)`**（确认导入 → 落库提升提交）。纯编排，**不碰 SQL**（一律经 Repository，CLAUDE.md §5）。
 *
 * F03 `runValidation` 沿 LLD §2.3 合法转移逐阶段推进状态机并 yield《04》§2 `ImportProgressEvent`（progress 单调不减）：
 *   selected → copying（复制 ZIP 字节到暂存）→ validating_zip（`ZipSafetyValidator` 不解压安全校验）
 *   → validating_manifest（解压后读 `manifest.json`：IMP-005 缺失 / IMP-006 主版本不兼容）
 *   → extracting_to_staging（解压全部条目到隔离暂存）→ validating_hash（逐文件 SHA-256 比对 `checksums.json`，IMP-009）
 *   → validating_schema（内置 Schema 逐文件校验，IMP-007/008）→ validating_business（`ContentMapper` 暴露 IMP-010/011/012/020，
 *      IMP-015 非阻断警告经 warningCount 传播）→ awaiting_confirmation（等待用户「确认导入」）。
 * 任一阶段的阻断错误经 `AppErrors` 归一为对应 IMP-* 码，作为 `blockingError` yield 后**短路终止**（任务置 failed、清理暂存）。
 *
 * F03 `commit` 复用既有落库内核：`new` 走 `ImportIndexer.land`、`upgrade` 走 `UpgradeIndexer.upgrade`，
 * 二者均沿 §2.4 step11~13（indexing → promoting-to-final → committing → completed）原子落库 + 目录提升 + 提交，
 * 任一步失败整体回滚（绝不残留半本书，§2.6）。
 *
 * **向后兼容（F02 不破坏）**：`create`/`cancel` 行为与构造签名前 6 参一字不改；F03 校验/提交所需依赖
 * （ImportFs / HashComputer / SchemaProvider / BookContentRepository / 字节读取与解压端口 / filesDir 等）一律作为
 * **可选构造参数**追加在原 6 参之后。`runValidation`/`commit` 内若依赖未注入则抛 AppError（不静默降级）。
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
import { Id, AppError } from '../domain/entities/common';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import { ImportProgressEvent, ImportResult, ValidationOptions, ValidationStage } from '../domain/entities/import';
import { IdFactory, ContentMapper, BookIndexModel, MapInput, ChapterFileInput } from './import/ContentMapper';
import { JsonValue } from './import/JsonSchemaValidator';
import { SourceProbePort, SourceFileMeta } from './StorageProbe';
import { UriPermissionPort } from './import/ImportLifecycle';
import { ImportLifecycle } from './import/ImportLifecycle';
import { ImportJobRepository, ImportJobRecord } from '../repositories/ImportJobRepository';
import { BookContentRepository, ExistingBookSummary } from '../repositories/BookContentRepository';
import { ImportFs, StagingArea } from './import/ImportStaging';
import { ChecksumVerifier, ChecksumsManifest, ChecksumVerifyResult, HashComputer } from './import/ChecksumVerifier';
import { ZipSafetyValidator, ZipSafetyOutcome, ZipSafetyStats } from './import/ZipSafetyValidator';
import { PackageSchemaValidator } from './import/PackageSchemaValidator';
import { SchemaProvider, classifyStagingFile } from './import/StudybookSchemaCatalog';
import { defaultValidationOptions } from './import/ImportLimits';
import { ImportIndexer, LandOutcome } from './import/ImportIndexer';
import { UpgradeIndexer } from './import/UpgradeIndexer';

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
 * 来源字节读取端口（F03 `copying`/`validating_zip` 阶段）：把来源 URI 的完整 ZIP 字节读入内存，
 * 供 `ZipSafetyValidator`（不解压安全校验）消费。生产实现以 `@ohos.file.fs` 读字节适配；单测以内存假实现注入。
 * 由调用方持原 URI（不入快照/日志，CLAUDE.md §5）；本服务仅传递 URI、不持有原 URI。
 */
export interface SourceBytesReader {
  /**
   * 读取来源 URI 的完整字节缓冲。
   * @param sourceUri 来源文件 URI（仅在本端口内部使用，不向上层/日志泄漏）。
   * @returns 完整字节缓冲。
   * @throws AppError 读取失败时抛出。
   */
  readSourceBytes(sourceUri: string): Promise<Uint8Array>;
}

/**
 * ZIP 解压端口（F03 `extracting_to_staging` 阶段）：把来源 ZIP 解压到隔离暂存根目录。
 * 实现须复用 `ZipSafetyValidator` 已校验的安全条目，逐条解压到 `stagingRoot/<相对路径>`（路径穿越已在
 * `validating_zip` 阶段拦截）。生产实现以 `@ohos.zlib`/`@ohos.file.fs` 适配；单测以内存假实现注入。
 */
export interface ZipExtractor {
  /**
   * 把来源 ZIP 解压到暂存根目录（隔离、对书架不可见）。
   * @param sourceUri 来源文件 URI（仅在本端口内部使用，不向上层/日志泄漏）。
   * @param stagingRoot 暂存根目录绝对路径（解压目标）。
   * @returns 解压出的文件相对路径列表（`/` 分隔、无前导斜杠）。
   * @throws AppError 解压失败时抛出（编排层归一为 IMP-018）。
   */
  extractTo(sourceUri: string, stagingRoot: string): Promise<string[]>;
}

/** runValidation/commit 阶段进度权重：把六个校验阶段映射到 [0, 0.85] 的单调递增进度上界。 */
const STAGE_PROGRESS_CEILING: Record<string, number> = {
  copying: 0.05,
  'validating-zip': 0.2,
  'validating-manifest': 0.3,
  'extracting-to-staging': 0.5,
  'validating-hash': 0.7,
  'validating-schema': 0.8,
  'validating-business': 0.85,
  'awaiting-confirmation': 0.88
};

/** 默认解压失败兜底码（IMP-018，§2.5）。 */
const EXTRACT_FAILURE_CODE: string = 'IMP-018';
/** 默认复制失败兜底码（IMP-017，§2.5）。 */
const COPY_FAILURE_CODE: string = 'IMP-017';

/**
 * F03 校验/提交依赖束（构造可选参数聚合，避免在 6 参之后追加一长串裸参数破坏可读性）。
 * 任一字段缺失时，`runValidation`/`commit` 在用到它前抛 AppError（不静默降级，CLAUDE.md「解决而非降级」）。
 */
export interface ImportValidationDeps {
  /** 文件系统端口（暂存准备/读取/枚举/原子提升）。 */
  fs: ImportFs;
  /** SHA-256 计算端口（暂存逐文件哈希）。 */
  hasher: HashComputer;
  /** 内置 Schema 来源（仅用应用内置可信副本，BR-002）。 */
  schemas: SchemaProvider;
  /** 书籍内容落库仓储（commit 落库）。 */
  contentRepo: BookContentRepository;
  /** 来源字节读取端口（ZIP 安全校验）。 */
  sourceBytes: SourceBytesReader;
  /** ZIP 解压端口（解压到暂存）。 */
  extractor: ZipExtractor;
  /** 运行期临时目录绝对路径（`context.tempDir`，派生暂存目录）。 */
  tempDir: string;
  /** 运行期文件目录绝对路径（`context.filesDir`，派生正式目录）。 */
  filesDir: string;
}

/**
 * 导入服务（F02 create/cancel + F03 runValidation/commit）。实现《04》§2 `ImportService` 契约。
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
  /** F03 校验/提交依赖束（F02 装配时不注入；为空时 runValidation/commit 抛 AppError）。 */
  private readonly deps?: ImportValidationDeps;
  /** runValidation 期间按 jobId 暂存来源 URI（仅内存、不入快照/日志；commit 需用同一暂存内容，不再读源 URI）。 */
  private readonly sourceUriByJob: Map<Id, string> = new Map<Id, string>();

  /**
   * @param jobRepo 导入任务仓储。
   * @param lifecycle 导入生命周期编排器（cancel 委托）。
   * @param ids 内部主键生成端口。
   * @param sourceProbe 来源文件探测端口。
   * @param uriHasher URI 哈希端口。
   * @param uriPersist 持久化 URI 授权写入端口。
   * @param deps （可选，F03）校验/提交依赖束；F02 装配不传，仅 create/cancel 时无需。
   */
  constructor(
    jobRepo: ImportJobRepository,
    lifecycle: ImportLifecycle,
    ids: IdFactory,
    sourceProbe: SourceProbePort,
    uriHasher: UriHasher,
    uriPersist: UriPersistPort,
    deps?: ImportValidationDeps) {
    this.jobRepo = jobRepo;
    this.lifecycle = lifecycle;
    this.ids = ids;
    this.sourceProbe = sourceProbe;
    this.uriHasher = uriHasher;
    this.uriPersist = uriPersist;
    this.deps = deps;
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

  /**
   * 绑定某任务的来源 URI（F03 校验页在 `runValidation` 前调用）。
   * `runValidation` 仅签名取 `jobId`（《04》§2），故来源 URI 由本方法在内存内按 jobId 暂存，
   * 供 copying（复制字节）/extracting（解压）阶段使用；不入快照/日志（CLAUDE.md §5）。
   * @param jobId 导入任务 ID。
   * @param sourceUri 来源文件 URI（仅在服务内部使用，不向上层/日志泄漏）。
   * @returns 无。
   */
  bindSourceUri(jobId: Id, sourceUri: string): void {
    this.sourceUriByJob.set(jobId, sourceUri);
  }

  /**
   * 取 F03 依赖束；未注入即抛 AppError（不静默降级）。
   * @returns 校验/提交依赖束。
   * @throws AppError 依赖未注入时抛出 `DB_WRITE_FAILED`。
   */
  private requireDeps(): ImportValidationDeps {
    if (this.deps === undefined) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: 'import-validation-deps-not-injected' });
    }
    return this.deps;
  }

  /**
   * 运行完整校验进度流（《04》§2 `ImportService.runValidation`；LLD §2.3/§2.4 step1~10）。
   *
   * 异步生成器：沿合法状态转移逐阶段推进并 yield 进度事件（progress 单调不减）。任一阶段命中阻断错误，
   * 归一为对应 IMP-* 码作为 `blockingError` yield 后**立即终止**（任务置 failed、清理暂存）；
   * IMP-015 为非阻断警告，经 `warningCount` 在 awaiting-confirmation 事件传播、不终止。
   * 全程经 `ImportStateMachine`/`ImportJobRepository.transition` 守卫，禁止越权推进。
   *
   * @param jobId 导入任务 ID（须处于 `selected`，且已 `bindSourceUri`）。
   * @returns 导入进度事件异步序列（最后一个事件为 awaiting-confirmation 或带 blockingError 的失败事件）。
   */
  async *runValidation(jobId: Id): AsyncIterable<ImportProgressEvent> {
    // 依赖与来源 URI 预检（缺失即作为内部错误短路，不进入状态机推进）
    const deps: ImportValidationDeps = this.requireDeps();
    const sourceUri: string | undefined = this.sourceUriByJob.get(jobId);
    if (sourceUri === undefined) {
      yield this.failEvent(jobId, AppErrors.create(DB_WRITE_FAILED, { detail: 'source-uri-not-bound' }), 0);
      return;
    }
    // 暂存区句柄（隔离、对书架不可见，§2.2）
    const staging: StagingArea = new StagingArea(deps.fs, deps.tempDir, jobId);
    // 校验阈值（§2.1 固化值 + 支持主版本）
    const options: ValidationOptions = defaultValidationOptions();
    // 进度单调不减游标
    let progress: number = 0;

    try {
      // ---- step: copying（selected → copying）：复制来源字节进内存（落暂存为 extracting 阶段职责）----
      await this.jobRepo.transition(jobId, 'copying', { stage: 'copying', progress: this.advance(progress, 'copying') });
      progress = this.advance(progress, 'copying');
      await staging.prepare();
      // 来源 ZIP 完整字节（IMP-017：复制/读取失败）
      const zipBytes: Uint8Array = await this.readSource(deps, sourceUri);

      // ---- step: validating-zip（不解压安全校验，IMP-001~004）----
      const zipEvt: ValidationEventInternal = await this.runZipStage(jobId, zipBytes, options, progress);
      progress = zipEvt.progress;
      yield zipEvt.event;
      if (zipEvt.event.blockingError !== undefined) {
        await this.failAndCleanup(jobId, zipEvt.event.blockingError, staging);
        return;
      }
      // 总文件数（供后续阶段 totalFiles）
      const totalFiles: number = zipEvt.totalFiles;

      // ---- step: extracting-to-staging（解压全部条目到隔离暂存，IMP-018）----
      // 注：manifest（IMP-005/006）需读取暂存文件，故解压先于 manifest 校验；阶段事件顺序仍按 §2.3
      //（validating-manifest 在 extracting 之前 yield，但 manifest 内容读取在解压完成后进行）。
      let extractedFiles: string[] = [];
      try {
        extractedFiles = await deps.extractor.extractTo(sourceUri, staging.getRoot());
      } catch (extractCause) {
        const error: AppError = AppErrors.from(extractCause, EXTRACT_FAILURE_CODE);
        // 解压在 extracting 阶段；但事件顺序需先发 manifest 阶段。此处直接以 extracting 阶段失败短路。
        await this.jobRepo.transition(jobId, 'validating_manifest',
          { stage: 'validating-manifest', progress: this.advance(progress, 'validating-manifest') });
        await this.jobRepo.transition(jobId, 'extracting_to_staging',
          { stage: 'extracting-to-staging', progress: this.advance(progress, 'extracting-to-staging') });
        const failEvt: ImportProgressEvent =
          this.failEvent(jobId, error, this.advance(progress, 'extracting-to-staging'));
        yield failEvt;
        await this.failAndCleanup(jobId, error, staging);
        return;
      }

      // ---- step: validating-manifest（manifest 存在 IMP-005 + 主版本兼容 IMP-006）----
      const manifestEvt: ValidationEventInternal =
        await this.runManifestStage(jobId, staging, extractedFiles, options, progress, totalFiles);
      progress = manifestEvt.progress;
      yield manifestEvt.event;
      if (manifestEvt.event.blockingError !== undefined) {
        await this.failAndCleanup(jobId, manifestEvt.event.blockingError, staging);
        return;
      }

      // ---- step: extracting-to-staging（解压已完成，发完成事件）----
      await this.jobRepo.transition(jobId, 'extracting_to_staging',
        { stage: 'extracting-to-staging', progress: this.advance(progress, 'extracting-to-staging') });
      progress = this.advance(progress, 'extracting-to-staging');
      yield this.validationEvent(jobId, 'extracting-to-staging', progress, extractedFiles.length, totalFiles, 0);

      // ---- step: validating-hash（逐文件 SHA-256 比对 checksums.json，IMP-009）----
      const hashEvt: ValidationEventInternal =
        await this.runHashStage(jobId, staging, extractedFiles, deps, progress, totalFiles);
      progress = hashEvt.progress;
      yield hashEvt.event;
      if (hashEvt.event.blockingError !== undefined) {
        await this.failAndCleanup(jobId, hashEvt.event.blockingError, staging);
        return;
      }

      // ---- step: validating-schema（内置 Schema 逐文件校验，IMP-007/008）----
      const schemaEvt: ValidationEventInternal =
        await this.runSchemaStage(jobId, staging, extractedFiles, deps, progress, totalFiles);
      progress = schemaEvt.progress;
      yield schemaEvt.event;
      if (schemaEvt.event.blockingError !== undefined) {
        await this.failAndCleanup(jobId, schemaEvt.event.blockingError, staging);
        return;
      }

      // ---- step: validating-business（ContentMapper 暴露 IMP-010/011/012/020 + IMP-015 警告）----
      const bizEvt: ValidationEventInternal =
        await this.runBusinessStage(jobId, staging, extractedFiles, deps, progress, totalFiles);
      progress = bizEvt.progress;
      yield bizEvt.event;
      if (bizEvt.event.blockingError !== undefined) {
        await this.failAndCleanup(jobId, bizEvt.event.blockingError, staging);
        return;
      }
      // 业务校验警告数（IMP-015 → warningCount）
      const warningCount: number = bizEvt.event.warningCount;

      // ---- step: awaiting-confirmation（等待用户「确认导入」）----
      await this.jobRepo.transition(jobId, 'awaiting_confirmation',
        { stage: 'awaiting-confirmation', progress: this.advance(progress, 'awaiting-confirmation'), warningCount: warningCount });
      progress = this.advance(progress, 'awaiting-confirmation');
      yield this.phaseEvent(jobId, 'awaiting-confirmation', progress, warningCount);
    } catch (cause) {
      // 阶段推进/IO 兜底（如状态机守卫拒绝、复制失败）：归一短路并清理
      const error: AppError = AppErrors.from(cause, COPY_FAILURE_CODE);
      yield this.failEvent(jobId, error, progress);
      await this.failAndCleanup(jobId, error, staging);
    }
  }

  /**
   * 提交导入（《04》§2 `ImportService.commit`；LLD §2.4 step11~13 / §2.7 升级）。
   *
   * 把 `awaiting_confirmation` 任务推进到 `completed`：从暂存解析协议 JSON 构建 `MapInput`，
   * `new` 走 `ImportIndexer.land`、`upgrade`（按 packageId 锚定旧书）走 `UpgradeIndexer.upgrade`，
   * 二者均在单事务内落库 + 提交前原子提升，任一步失败整体回滚并置 failed（绝不残留半本书）。
   *
   * @param jobId 导入任务 ID（须处于 `awaiting_confirmation`）。
   * @param mode 新导入或升级。
   * @returns 导入完成结果（《04》§2 `ImportResult`）。
   * @throws AppError 依赖未注入、任务态非法、内容/落库失败时抛出（失败任务已置 failed、目录已清理）。
   */
  async commit(jobId: Id, mode: 'new' | 'upgrade'): Promise<ImportResult> {
    // 依赖束
    const deps: ImportValidationDeps = this.requireDeps();
    // 任务记录（须存在且处于 awaiting_confirmation）
    const job: ImportJobRecord | undefined = await this.jobRepo.getJob(jobId);
    if (job === undefined) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `import-job-not-found:${jobId}` });
    }
    if (job.state !== 'awaiting_confirmation') {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `commit-requires-awaiting:${job.state}` });
    }
    // 暂存句柄与解析
    const staging: StagingArea = new StagingArea(deps.fs, deps.tempDir, jobId);
    const stagedFiles: string[] = await staging.listFiles();
    // 完成时间（epoch ms）
    const now: number = Date.now();

    // 升级：按 packageId 解析旧书，bookId 锚定旧书内部 id；新导入：生成新 bookId
    let bookId: string = this.ids.newId();
    if (mode === 'upgrade') {
      // 先读暂存 manifest 取 packageId（解析失败按内容错误短路）
      const manifest: Record<string, JsonValue> = await this.readJsonObject(staging, 'manifest.json');
      const packageId: string = this.readStr(manifest, 'packageId');
      const existing: ExistingBookSummary | undefined = await deps.contentRepo.findBookByPackageId(packageId);
      if (existing === undefined) {
        // 无旧书可升级：按内容错误处理（重复版本语义不当，用通用写入失败 + 脱敏 detail）
        throw AppErrors.create(DB_WRITE_FAILED, { detail: 'upgrade-target-not-found' });
      }
      bookId = existing.id;
    }

    // 构建映射输入（含解析后协议 JSON + 暂存哈希/大小 + 注入 id/now）
    const mapInput: MapInput = await this.buildMapInput(staging, stagedFiles, deps, bookId, now);
    // 暂存提升源
    const stagingRoot: string = staging.getRoot();

    // 落库 + 原子提升 + 提交（new/upgrade 分派）
    const outcome: LandOutcome = mode === 'upgrade'
      ? await new UpgradeIndexer(this.jobRepo, deps.contentRepo, deps.fs, deps.filesDir).upgrade(jobId, mapInput, stagingRoot)
      : await new ImportIndexer(this.jobRepo, deps.contentRepo, deps.fs, deps.filesDir).land(jobId, mapInput, stagingRoot);

    // 释放内存暂存的来源 URI（提交完成后不再需要）
    this.sourceUriByJob.delete(jobId);

    // 组装 ImportResult（《04》§2）
    return {
      jobId: jobId,
      bookId: outcome.bookId,
      packageId: outcome.packageId,
      contentVersion: outcome.contentVersion,
      mode: mode,
      chapterCount: outcome.chapterCount,
      warningCount: outcome.warningCount,
      completedAt: outcome.completedAt
    };
  }

  // ===========================================================================
  // F03 内部阶段实现
  // ===========================================================================

  /**
   * 读取来源字节，失败归一为 IMP-017（复制/读取失败）。
   * @param deps 依赖束。
   * @param sourceUri 来源 URI。
   * @returns 完整字节缓冲。
   * @throws AppError 读取失败时抛 IMP-017。
   */
  private async readSource(deps: ImportValidationDeps, sourceUri: string): Promise<Uint8Array> {
    try {
      return await deps.sourceBytes.readSourceBytes(sourceUri);
    } catch (cause) {
      throw AppErrors.from(cause, COPY_FAILURE_CODE);
    }
  }

  /**
   * validating-zip 阶段：不解压安全校验（IMP-001~004）。
   * @param jobId 任务 ID。
   * @param zipBytes ZIP 字节缓冲。
   * @param options 校验阈值。
   * @param prevProgress 上阶段进度。
   * @returns 阶段事件与进度（含总文件数）。
   */
  private async runZipStage(
    jobId: Id, zipBytes: Uint8Array, options: ValidationOptions, prevProgress: number): Promise<ValidationEventInternal> {
    // 推进状态机
    const progress: number = this.advance(prevProgress, 'validating-zip');
    await this.jobRepo.transition(jobId, 'validating_zip', { stage: 'validating-zip', progress: progress });
    // 安全校验
    const outcome: ZipSafetyOutcome = ZipSafetyValidator.validate(zipBytes, zipBytes.length, options);
    if (!outcome.ok) {
      const error: AppError = outcome.error !== undefined
        ? outcome.error : AppErrors.create('IMP-001', { detail: 'zip-validate-failed' });
      return { event: this.validationEvent(jobId, 'validating-zip', progress, 0, undefined, 0, error), progress: progress, totalFiles: 0 };
    }
    // 条目总数（供后续 totalFiles）
    const stats: ZipSafetyStats | undefined = outcome.stats;
    const totalFiles: number = stats !== undefined ? stats.entryCount : 0;
    return {
      event: this.validationEvent(jobId, 'validating-zip', progress, totalFiles, totalFiles, 0),
      progress: progress, totalFiles: totalFiles
    };
  }

  /**
   * validating-manifest 阶段：manifest 存在（IMP-005）+ 主版本兼容（IMP-006）。
   * @param jobId 任务 ID。
   * @param staging 暂存句柄。
   * @param files 暂存文件相对路径列表。
   * @param options 校验阈值（supportedFormatMajors）。
   * @param prevProgress 上阶段进度。
   * @param totalFiles 总文件数。
   * @returns 阶段事件与进度。
   */
  private async runManifestStage(
    jobId: Id, staging: StagingArea, files: string[], options: ValidationOptions,
    prevProgress: number, totalFiles: number): Promise<ValidationEventInternal> {
    const progress: number = this.advance(prevProgress, 'validating-manifest');
    await this.jobRepo.transition(jobId, 'validating_manifest', { stage: 'validating-manifest', progress: progress });
    // IMP-005：manifest.json 缺失
    if (files.indexOf('manifest.json') < 0) {
      const error: AppError = AppErrors.create('IMP-005', { detail: 'manifest-missing' });
      return { event: this.validationEvent(jobId, 'validating-manifest', progress, 0, totalFiles, 0, error), progress: progress, totalFiles: totalFiles };
    }
    // 读取并解析 manifest（解析失败 IMP-007）
    const text: string = await staging.readText('manifest.json');
    const parsed: AppError | Record<string, JsonValue> = this.parseObject('manifest.json', text);
    if (AppErrors.isAppError(parsed as Object)) {
      return { event: this.validationEvent(jobId, 'validating-manifest', progress, 0, totalFiles, 0, parsed as AppError), progress: progress, totalFiles: totalFiles };
    }
    // IMP-006：协议主版本不兼容（formatVersion 形如 `1.x.y`，取主版本与支持集合比对）
    const manifest: Record<string, JsonValue> = parsed as Record<string, JsonValue>;
    const formatVersion: string = this.readStr(manifest, 'formatVersion');
    const major: number = ImportService.majorOf(formatVersion);
    if (major < 0 || options.supportedFormatMajors.indexOf(major) < 0) {
      const error: AppError = AppErrors.create('IMP-006', { detail: `format-major-incompatible:${major}` });
      return { event: this.validationEvent(jobId, 'validating-manifest', progress, 1, totalFiles, 0, error), progress: progress, totalFiles: totalFiles };
    }
    return { event: this.validationEvent(jobId, 'validating-manifest', progress, 1, totalFiles, 0), progress: progress, totalFiles: totalFiles };
  }

  /**
   * validating-hash 阶段：逐文件 SHA-256 比对 checksums.json（IMP-009）。
   * @param jobId 任务 ID。
   * @param staging 暂存句柄。
   * @param files 暂存文件相对路径列表。
   * @param deps 依赖束（hasher）。
   * @param prevProgress 上阶段进度。
   * @param totalFiles 总文件数。
   * @returns 阶段事件与进度。
   */
  private async runHashStage(
    jobId: Id, staging: StagingArea, files: string[], deps: ImportValidationDeps,
    prevProgress: number, totalFiles: number): Promise<ValidationEventInternal> {
    const progress: number = this.advance(prevProgress, 'validating-hash');
    await this.jobRepo.transition(jobId, 'validating_hash', { stage: 'validating-hash', progress: progress });
    // checksums.json 必须存在（缺失视为引用不完整，IMP-010 由 §2.4 step9 覆盖；此处缺失记 IMP-009 hash 不可比对）
    if (files.indexOf('checksums.json') < 0) {
      const error: AppError = AppErrors.create('IMP-009', { retryable: false, detail: 'checksums-missing' });
      return { event: this.validationEvent(jobId, 'validating-hash', progress, 0, totalFiles, 0, error), progress: progress, totalFiles: totalFiles };
    }
    // 解析 checksums 清单（解析失败 IMP-007）
    const text: string = await staging.readText('checksums.json');
    const parsed: AppError | Record<string, JsonValue> = this.parseObject('checksums.json', text);
    if (AppErrors.isAppError(parsed as Object)) {
      return { event: this.validationEvent(jobId, 'validating-hash', progress, 0, totalFiles, 0, parsed as AppError), progress: progress, totalFiles: totalFiles };
    }
    // 转 ChecksumsManifest（algorithm + files 映射）
    const manifest: ChecksumsManifest = ImportService.toChecksumsManifest(parsed as Record<string, JsonValue>);
    // 逐文件实际哈希
    const actualHashes: Record<string, string> = await ChecksumVerifier.computeStagingHashes(staging, files, deps.hasher);
    // 纯比对
    const result: ChecksumVerifyResult = ChecksumVerifier.verify(manifest, actualHashes, files);
    if (!result.ok) {
      const error: AppError = ChecksumVerifier.toError(result);
      return { event: this.validationEvent(jobId, 'validating-hash', progress, files.length, totalFiles, 0, error), progress: progress, totalFiles: totalFiles };
    }
    return { event: this.validationEvent(jobId, 'validating-hash', progress, files.length, totalFiles, 0), progress: progress, totalFiles: totalFiles };
  }

  /**
   * validating-schema 阶段：内置 Schema 逐文件校验（IMP-007/008）。
   * @param jobId 任务 ID。
   * @param staging 暂存句柄。
   * @param files 暂存文件相对路径列表。
   * @param deps 依赖束（schemas）。
   * @param prevProgress 上阶段进度。
   * @param totalFiles 总文件数。
   * @returns 阶段事件与进度。
   */
  private async runSchemaStage(
    jobId: Id, staging: StagingArea, files: string[], deps: ImportValidationDeps,
    prevProgress: number, totalFiles: number): Promise<ValidationEventInternal> {
    const progress: number = this.advance(prevProgress, 'validating-schema');
    await this.jobRepo.transition(jobId, 'validating_schema', { stage: 'validating-schema', progress: progress });
    // 已检查文件计数
    let checked: number = 0;
    for (let i: number = 0; i < files.length; i++) {
      // 当前文件相对路径
      const path: string = files[i];
      // 仅对可分类的结构化文件做 Schema 校验（其余忽略，BR-002）
      if (classifyStagingFile(path) === undefined) {
        continue;
      }
      // 读文本 → 解析 + 校验（IMP-007/008）
      const text: string = await staging.readText(path);
      const error: AppError | undefined = PackageSchemaValidator.parseAndValidate(path, text, deps.schemas);
      checked = checked + 1;
      if (error !== undefined) {
        return { event: this.validationEvent(jobId, 'validating-schema', progress, checked, totalFiles, 0, error), progress: progress, totalFiles: totalFiles };
      }
    }
    return { event: this.validationEvent(jobId, 'validating-schema', progress, checked, totalFiles, 0), progress: progress, totalFiles: totalFiles };
  }

  /**
   * validating-business 阶段：ContentMapper 暴露 IMP-010/011/012/020 + IMP-015 警告（§2.5 R-037）。
   * @param jobId 任务 ID。
   * @param staging 暂存句柄。
   * @param files 暂存文件相对路径列表。
   * @param deps 依赖束。
   * @param prevProgress 上阶段进度。
   * @param totalFiles 总文件数。
   * @returns 阶段事件与进度（warningCount 来自映射模型）。
   */
  private async runBusinessStage(
    jobId: Id, staging: StagingArea, files: string[], deps: ImportValidationDeps,
    prevProgress: number, totalFiles: number): Promise<ValidationEventInternal> {
    const progress: number = this.advance(prevProgress, 'validating-business');
    await this.jobRepo.transition(jobId, 'validating_business', { stage: 'validating-business', progress: progress });
    try {
      // 构建映射模型（内容不变量在此暴露：IMP-010/011/012/020）；warningCount 含 IMP-015 判定
      const mapInput: MapInput = await this.buildMapInput(staging, files, deps, this.ids.newId(), Date.now());
      const model: BookIndexModel = ContentMapper.map(mapInput);
      return {
        event: this.validationEvent(jobId, 'validating-business', progress, files.length, totalFiles, model.warningCount),
        progress: progress, totalFiles: totalFiles
      };
    } catch (cause) {
      // 内容类阻断（IMP-010/011/012/020）；非 AppError 兜底 IMP-010 引用不完整
      const error: AppError = AppErrors.from(cause, 'IMP-010');
      return { event: this.validationEvent(jobId, 'validating-business', progress, files.length, totalFiles, 0, error), progress: progress, totalFiles: totalFiles };
    }
  }

  /**
   * 从暂存构建 `ContentMapper` 映射输入（解析 manifest/book/chapters/report + 暂存哈希/大小 + 注入 id/now）。
   * @param staging 暂存句柄。
   * @param files 暂存文件相对路径列表。
   * @param deps 依赖束（hasher）。
   * @param bookId 内部书籍 ID（new=新生成；upgrade=旧书 id）。
   * @param now 时间戳（epoch ms）。
   * @returns 映射输入。
   * @throws AppError 必需文件缺失/解析失败时抛出。
   */
  private async buildMapInput(
    staging: StagingArea, files: string[], deps: ImportValidationDeps, bookId: string, now: number): Promise<MapInput> {
    // manifest / book（必需）
    const manifest: Record<string, JsonValue> = await this.readJsonObject(staging, 'manifest.json');
    const book: Record<string, JsonValue> = await this.readJsonObject(staging, 'book.json');
    // 章节文件（chapters/*.json，逐个解析）
    const chapters: ChapterFileInput[] = [];
    for (let i: number = 0; i < files.length; i++) {
      // 当前文件
      const path: string = files[i];
      if (classifyStagingFile(path) === 'chapter') {
        chapters.push({ file: path, json: await this.readJsonObject(staging, path) });
      }
    }
    // report（可选）
    let report: Record<string, JsonValue> | undefined = undefined;
    if (files.indexOf('report.json') >= 0) {
      report = await this.readJsonObject(staging, 'report.json');
    }
    // 暂存全部文件哈希与大小
    const fileHashes: Record<string, string> = await ChecksumVerifier.computeStagingHashes(staging, files, deps.hasher);
    const fileSizes: Record<string, number> = {};
    for (let i: number = 0; i < files.length; i++) {
      // 当前文件字节数（读字节取长度；体积可接受，暂存已通过大小上限校验）
      const bytes: Uint8Array = await staging.readBytes(files[i]);
      fileSizes[files[i]] = bytes.length;
    }
    return {
      manifest: manifest,
      book: book,
      chapters: chapters,
      report: report,
      fileHashes: fileHashes,
      fileSizes: fileSizes,
      bookId: bookId,
      now: now,
      ids: this.ids
    };
  }

  /**
   * 读取并解析暂存某 JSON 文件为对象；解析失败/非对象抛 IMP-007。
   * @param staging 暂存句柄。
   * @param relativePath 相对路径。
   * @returns 解析后的对象。
   * @throws AppError 解析失败时抛 IMP-007。
   */
  private async readJsonObject(staging: StagingArea, relativePath: string): Promise<Record<string, JsonValue>> {
    const text: string = await staging.readText(relativePath);
    const parsed: AppError | Record<string, JsonValue> = this.parseObject(relativePath, text);
    if (AppErrors.isAppError(parsed as Object)) {
      throw parsed as AppError;
    }
    return parsed as Record<string, JsonValue>;
  }

  /**
   * 解析 JSON 文本为对象；失败或非对象返回 IMP-007 AppError（不抛，由调用方决定）。
   * @param relativePath 相对路径（仅诊断定位）。
   * @param text 文本。
   * @returns 解析后的对象，或 IMP-007 AppError。
   */
  private parseObject(relativePath: string, text: string): AppError | Record<string, JsonValue> {
    try {
      // 解析所得值
      const value: JsonValue = JSON.parse(text) as JsonValue;
      if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        return AppErrors.create('IMP-007', { retryable: false, detail: `json-not-object:${relativePath}` });
      }
      return value as Record<string, JsonValue>;
    } catch (e) {
      return AppErrors.create('IMP-007', { retryable: false, detail: `json-parse-failed:${relativePath}` });
    }
  }

  /**
   * 读对象字段为字符串（缺失/非串返回空串）。
   * @param obj 对象。
   * @param key 键。
   * @returns 字符串。
   */
  private readStr(obj: Record<string, JsonValue>, key: string): string {
    // 字段值
    const value: JsonValue | undefined = obj[key];
    return typeof value === 'string' ? value : '';
  }

  /**
   * 单调推进进度到某阶段上界（取「当前值」与「阶段上界」的较大者，保证 progress 单调不减）。
   * @param current 当前进度。
   * @param stage 阶段标识（事件阶段或 copying）。
   * @returns 推进后的进度（0..1）。
   */
  private advance(current: number, stage: string): number {
    // 阶段进度上界
    const ceiling: number | undefined = STAGE_PROGRESS_CEILING[stage];
    const target: number = ceiling !== undefined ? ceiling : current;
    return target > current ? target : current;
  }

  /**
   * 构造校验阶段事件（《04》§2 `ValidationEvent`）。
   * @param jobId 任务 ID。
   * @param stage 校验阶段。
   * @param progress 进度。
   * @param checkedFiles 已检查文件数。
   * @param totalFiles 总文件数（可省略）。
   * @param warningCount 警告累计数。
   * @param blockingError 阻断错误（可省略）。
   * @returns 校验阶段事件。
   */
  private validationEvent(
    jobId: Id, stage: ValidationStage, progress: number, checkedFiles: number,
    totalFiles: number | undefined, warningCount: number, blockingError?: AppError): ImportProgressEvent {
    // 基础事件
    const event: ImportProgressEvent = {
      jobId: jobId, stage: stage, progress: progress, checkedFiles: checkedFiles, warningCount: warningCount
    };
    if (totalFiles !== undefined) {
      event.totalFiles = totalFiles;
    }
    if (blockingError !== undefined) {
      event.blockingError = blockingError;
    }
    return event;
  }

  /**
   * 构造后续阶段事件（《04》§2 `ImportPhaseEvent`：awaiting-confirmation 等）。
   * @param jobId 任务 ID。
   * @param stage 后续阶段。
   * @param progress 进度。
   * @param warningCount 警告累计数。
   * @param blockingError 阻断错误（可省略）。
   * @returns 后续阶段事件。
   */
  private phaseEvent(
    jobId: Id, stage: 'awaiting-confirmation' | 'indexing' | 'promoting-to-final' | 'committing' | 'completed',
    progress: number, warningCount: number, blockingError?: AppError): ImportProgressEvent {
    // 基础事件
    const event: ImportProgressEvent = {
      jobId: jobId, stage: stage, progress: progress, warningCount: warningCount
    };
    if (blockingError !== undefined) {
      event.blockingError = blockingError;
    }
    return event;
  }

  /**
   * 构造失败事件：以 validating-business 阶段承载阻断错误（非阶段相关的内部失败统一以校验阶段表达）。
   * @param jobId 任务 ID。
   * @param error 领域错误。
   * @param progress 进度。
   * @returns 带 blockingError 的校验阶段事件。
   */
  private failEvent(jobId: Id, error: AppError, progress: number): ImportProgressEvent {
    return this.validationEvent(jobId, 'validating-business', progress, 0, undefined, 0, error);
  }

  /**
   * 失败短路统一处理：把任务置 failed（守卫式，写错误码/脱敏详情）并清理暂存（最佳努力）。
   * @param jobId 任务 ID。
   * @param error 领域错误。
   * @param staging 暂存句柄。
   * @returns 完成的 Promise。
   */
  private async failAndCleanup(jobId: Id, error: AppError, staging: StagingArea): Promise<void> {
    // 守卫式置 failed（当前态为 copying/validating_* 任一 → failed 均为合法边）
    try {
      await this.jobRepo.transition(jobId, 'failed', {
        stage: 'failed',
        errorCode: error.code,
        errorDetail: error.detail !== undefined ? error.detail : error.code
      });
    } catch (ignore) {
      // 状态写入失败不掩盖原业务错误（如当前态无 →failed 合法边的边界情况）
    }
    // 清理暂存目录（§2.6）+ 释放内存来源 URI
    try {
      await staging.cleanup();
    } catch (ignore) {
      // 清理失败仅静默：不输出敏感路径（CLAUDE.md §5）
    }
    this.sourceUriByJob.delete(jobId);
  }

  /**
   * 取 `formatVersion`（形如 `1.x.y`）的主版本号；非法返回 -1。
   * @param formatVersion 协议格式版本串。
   * @returns 主版本号或 -1。
   */
  private static majorOf(formatVersion: string): number {
    // 取首段
    const head: string = formatVersion.split('.')[0];
    // 解析为整数
    const major: number = Number.parseInt(head, 10);
    return Number.isNaN(major) ? -1 : major;
  }

  /**
   * 把已解析的 checksums JSON 对象转为 `ChecksumsManifest`（algorithm + files 映射）。
   * @param obj 已解析对象。
   * @returns checksums 清单。
   */
  private static toChecksumsManifest(obj: Record<string, JsonValue>): ChecksumsManifest {
    // 算法（缺失/非串归一空串，由比对层判失败）
    const algorithm: string = typeof obj.algorithm === 'string' ? obj.algorithm : '';
    // files 映射（仅保留字符串值项）
    const files: Record<string, string> = {};
    const rawFiles: JsonValue | undefined = obj.files;
    if (rawFiles !== null && rawFiles !== undefined && typeof rawFiles === 'object' && !Array.isArray(rawFiles)) {
      // files 子对象
      const filesObj: Record<string, JsonValue> = rawFiles as Record<string, JsonValue>;
      const keys: string[] = Object.keys(filesObj);
      for (let i: number = 0; i < keys.length; i++) {
        // 当前条目值
        const value: JsonValue = filesObj[keys[i]];
        if (typeof value === 'string') {
          files[keys[i]] = value;
        }
      }
    }
    return { algorithm: algorithm, files: files };
  }
}

/** 阶段实现的内部返回（阶段事件 + 推进后进度 + 总文件数）。 */
interface ValidationEventInternal {
  /** 阶段事件（含可能的 blockingError）。 */
  event: ImportProgressEvent;
  /** 推进后进度（单调不减）。 */
  progress: number;
  /** 总文件数（供后续阶段 totalFiles）。 */
  totalFiles: number;
}
