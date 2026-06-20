/**
 * P-F02 导入选择页 ViewModel（LLD §6.2：状态 未选择/已选择/空间不足/类型错误/复制中；约束 仅单文件、按钮防重复点击）。
 *
 * 职责（页面与 SQL/SDK 的隔离层，CLAUDE.md §5 / 04 §12.5「页面只依赖 Service/ViewModel」）：
 * - 持有选择页有限状态机（`ImportSelectStatus`）与脱敏展示数据（仅文件名/大小，**不含绝对路径**，§6.2 约束）；
 * - 接收页面「选择文件」结果 → 预检查（扩展名类型校验 + 空间充足性）→ 切到对应状态；
 * - 「开始校验」时**防重复点击**（已在复制中即忽略），调用 `ImportService.create` 落 `selected`，
 *   产出 `jobId` 供页面 `pushPathByName('import/validate', { jobId })`；
 * - 失败统一归一为 `AppError`（不抛裸字符串，04 §1），由页面据 `messageKey` 渲染资源文案。
 *
 * 纯逻辑、零 ArkUI/`@ohos.*` 依赖：设备 IO 经 `ImportService` 及其端口完成；本类可用内存假实现单测。
 * 时间戳经 `now` 注入（页面取系统时钟），便于确定性测试。
 *
 * 文件类型校验口径：仅接受文件名以 `.studybook.zip` 结尾的来源（CLAUDE.md 边界 3「只导入 ai.studybook 协议 ZIP」）；
 * 其余一律切「类型错误」，不进入 create（深度 ZIP/魔数校验由后续校验页 P-F03 的内核承担，此处仅做轻量前置拦截）。
 */
import { Id } from '../domain/entities/common';
import { AppError } from '../domain/entities/common';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import { ImportService } from '../services/ImportService';
import { SourceProbePort, SourceFileMeta, FreeSpaceProbePort, StorageProbe, SpaceCheckResult } from '../services/StorageProbe';

/** 学习包文件名后缀（CLAUDE.md 边界 3：`.studybook.zip`）。 */
const STUDYBOOK_SUFFIX: string = '.studybook.zip';

/**
 * P-F02 选择页有限状态（LLD §6.2「状态」列逐一对齐）。
 */
export enum ImportSelectStatus {
  /** 未选择：初始/已重置，等待用户选择文件。 */
  Idle = 'idle',
  /** 已选择：通过类型与空间预检查，可点击「开始校验」。 */
  Selected = 'selected',
  /** 空间不足：所选文件预估所需暂存空间超过可用空间。 */
  InsufficientSpace = 'insufficient-space',
  /** 类型错误：所选文件非 `.studybook.zip`。 */
  WrongType = 'wrong-type',
  /** 复制中：已点击「开始校验」，正在创建任务（防重复点击窗口）。 */
  Copying = 'copying'
}

/**
 * 选择页可观察状态快照（页面以 `@State` 持有；只含脱敏展示字段，不含绝对路径/原 URI）。
 */
export interface ImportSelectState {
  /** 当前有限状态。 */
  status: ImportSelectStatus;
  /** 已选文件脱敏名（仅末段文件名；未选择时为空串）。 */
  fileName: string;
  /** 已选文件字节大小（未选择时为 0）。 */
  fileSize: number;
  /** 空间不足时的所需/可用明细（其它状态为 undefined）。 */
  space?: SpaceCheckResult;
  /** 失败/错误时的领域错误（供页面据 messageKey 渲染；正常态为 undefined）。 */
  error?: AppError;
  /** 创建成功后的导入任务 ID（供页面跳校验页；未创建为 undefined）。 */
  jobId?: Id;
}

/**
 * 导入选择页 ViewModel。
 */
export class ImportSelectVM {
  /** 导入服务（创建/取消编排）。 */
  private readonly importService: ImportService;
  /** 来源文件探测端口（脱敏文件名/大小）。 */
  private readonly sourceProbe: SourceProbePort;
  /** 可用空间探测端口（暂存盘剩余字节）。 */
  private readonly freeSpaceProbe: FreeSpaceProbePort;
  /** 空间充足性判定（纯逻辑）。 */
  private readonly storageProbe: StorageProbe;
  /** 当前状态快照（单一可变状态，所有变更经 setter 同步给监听器）。 */
  private state: ImportSelectState;
  /** 当前所选来源 URI（仅内存暂存供 create 使用，不外泄/不入快照，CLAUDE.md §5）。 */
  private selectedUri?: string;
  /** 状态变更监听器（页面注册以触发 `@State` 刷新）。 */
  private listener?: (state: ImportSelectState) => void;

  /**
   * @param importService 导入服务。
   * @param sourceProbe 来源文件探测端口。
   * @param freeSpaceProbe 可用空间探测端口。
   * @param storageProbe 空间充足性判定（缺省新建默认余量系数实例）。
   */
  constructor(
    importService: ImportService,
    sourceProbe: SourceProbePort,
    freeSpaceProbe: FreeSpaceProbePort,
    storageProbe?: StorageProbe) {
    this.importService = importService;
    this.sourceProbe = sourceProbe;
    this.freeSpaceProbe = freeSpaceProbe;
    this.storageProbe = storageProbe !== undefined ? storageProbe : new StorageProbe();
    // 初始为「未选择」空快照
    this.state = ImportSelectVM.idleState();
  }

  /**
   * 构造「未选择」初始快照。
   * @returns 空 Idle 状态快照。
   */
  private static idleState(): ImportSelectState {
    return { status: ImportSelectStatus.Idle, fileName: '', fileSize: 0 };
  }

  /**
   * 取当前状态快照（供页面 onReady 初始化 `@State`）。
   * @returns 当前状态快照。
   */
  getState(): ImportSelectState {
    return this.state;
  }

  /**
   * 注册状态变更监听器（页面用以把 VM 状态同步到 `@State`）。
   * @param listener 状态变更回调。
   * @returns 无。
   */
  setListener(listener: (state: ImportSelectState) => void): void {
    this.listener = listener;
  }

  /**
   * 判断文件名是否为合法学习包（仅 `.studybook.zip` 后缀，大小写不敏感）。
   * @param fileName 脱敏文件名。
   * @returns 合法返回 true。
   */
  static isStudybookFile(fileName: string): boolean {
    // 统一小写后比较后缀（系统返回大小写不定）
    const lower: string = fileName.toLowerCase();
    return lower.length > STUDYBOOK_SUFFIX.length && lower.endsWith(STUDYBOOK_SUFFIX);
  }

  /**
   * 处理用户选择文件结果：探测元信息 → 类型校验 → 空间检查 → 切到对应状态（已选择/类型错误/空间不足）。
   * 单文件约束由调用方（页面只取首个选中项）保证；本方法只接受一个 URI。
   * @param sourceUri 所选来源 URI（DocumentViewPicker 返回）。
   * @returns 完成的 Promise（状态经监听器下发，不抛异常，错误进 state.error）。
   */
  async onFileSelected(sourceUri: string): Promise<void> {
    try {
      // 探测脱敏文件名/大小（不外泄原 URI）
      const meta: SourceFileMeta = await this.sourceProbe.probeSource(sourceUri);
      // 类型校验：非 .studybook.zip → 类型错误（不暂存 URI，阻止后续 create）
      if (!ImportSelectVM.isStudybookFile(meta.displayName)) {
        this.selectedUri = undefined;
        this.emit({
          status: ImportSelectStatus.WrongType,
          fileName: meta.displayName,
          fileSize: meta.sizeBytes >= 0 ? meta.sizeBytes : 0,
          error: AppErrors.create('IMP-001', { detail: 'wrong-file-type' })
        });
        return;
      }
      // 空间检查：可用空间 vs 预估所需（来源大小 × 余量系数）
      const available: number = await this.freeSpaceProbe.freeBytes();
      const space: SpaceCheckResult = this.storageProbe.checkSpace(meta.sizeBytes, available);
      if (!space.sufficient) {
        // 空间不足：保留所选 URI（用户清理空间后可直接重试），切「空间不足」并附明细
        this.selectedUri = sourceUri;
        this.emit({
          status: ImportSelectStatus.InsufficientSpace,
          fileName: meta.displayName,
          fileSize: meta.sizeBytes,
          space: space,
          error: AppErrors.create('IMP-013', { retryable: true, detail: 'insufficient-space' })
        });
        return;
      }
      // 通过预检查：暂存 URI，切「已选择」（可点击开始校验）
      this.selectedUri = sourceUri;
      this.emit({
        status: ImportSelectStatus.Selected,
        fileName: meta.displayName,
        fileSize: meta.sizeBytes
      });
    } catch (cause) {
      // 探测/空间检查异常：归一为 AppError，回到未选择并携带错误
      this.selectedUri = undefined;
      this.emit({
        status: ImportSelectStatus.Idle,
        fileName: '',
        fileSize: 0,
        error: AppErrors.from(cause, DB_WRITE_FAILED)
      });
    }
  }

  /**
   * 开始校验：防重复点击 → 调用 `ImportService.create` 落 `selected` → 产出 jobId（页面据此跳校验页）。
   * 仅「已选择」态可触发；复制中/其它态忽略（按钮防重复，§6.2）。
   * @param now 当前时间戳（epoch ms，写 `started_at`；页面取系统时钟）。
   * @returns 创建成功的 jobId；被忽略或失败返回 undefined（失败时 state.error 已置）。
   */
  async startValidation(now: number): Promise<Id | undefined> {
    // 防重复点击：非「已选择」态（含已在复制中）直接忽略，不重复 create
    if (this.state.status !== ImportSelectStatus.Selected) {
      return undefined;
    }
    // 缺所选 URI（防御性）：保持当前态返回
    const uri: string | undefined = this.selectedUri;
    if (uri === undefined) {
      return undefined;
    }
    // 进入「复制中」：禁用按钮、展示进行态
    this.emit({
      status: ImportSelectStatus.Copying,
      fileName: this.state.fileName,
      fileSize: this.state.fileSize
    });
    try {
      // 创建导入任务（落 import_jobs state=selected）
      const jobId: Id = await this.importService.create(uri, now);
      // 成功：把 jobId 写入快照供页面跳转（保持复制中态直至导航离开）
      this.emit({
        status: ImportSelectStatus.Copying,
        fileName: this.state.fileName,
        fileSize: this.state.fileSize,
        jobId: jobId
      });
      return jobId;
    } catch (cause) {
      // 创建失败：回到「已选择」允许重试，并携带归一错误
      this.emit({
        status: ImportSelectStatus.Selected,
        fileName: this.state.fileName,
        fileSize: this.state.fileSize,
        error: AppErrors.from(cause, DB_WRITE_FAILED)
      });
      return undefined;
    }
  }

  /**
   * 重置为「未选择」（清空所选 URI 与展示数据，供「重新选择」或离开页面调用）。
   * @returns 无。
   */
  reset(): void {
    this.selectedUri = undefined;
    this.emit(ImportSelectVM.idleState());
  }

  /**
   * 更新内部状态并通知监听器（单一变更出口，保证 state 与页面 `@State` 一致）。
   * @param next 下一状态快照。
   * @returns 无。
   */
  private emit(next: ImportSelectState): void {
    // 替换当前快照
    this.state = next;
    // 通知页面刷新（未注册监听器时静默）
    if (this.listener !== undefined) {
      this.listener(next);
    }
  }
}
