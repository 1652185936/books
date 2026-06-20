/**
 * 导入与校验 DTO 契约（《04-接口与DTO契约》§2）。
 * 适配 ArkTS：04 中 ImportProgressEvent 联合类型的内联第二支拆为具名接口 ImportPhaseEvent，字段集不变。
 * `ImportedBook` 属导入模块内部结构，不在此跨模块暴露（其字段由《06-协议到数据库映射规范》定义）。
 */
import { Id, EpochMs, AppError } from './common';

/** 校验阈值参数（LLD §2.1，不解压先检查）。 */
export interface ValidationOptions {
  /** 压缩包大小上限（字节）。 */
  maxArchiveBytes: number;
  /** 解压后总大小上限（字节）。 */
  maxExpandedBytes: number;
  /** 条目数上限。 */
  maxEntries: number;
  /** 压缩比上限（防压缩炸弹）。 */
  maxCompressionRatio: number;
  /** 支持的协议主版本号集合。 */
  supportedFormatMajors: number[];
}

/** 校验阶段枚举（流式进度，04 §2）。 */
export type ValidationStage =
  | 'validating-zip'
  | 'validating-manifest'
  | 'extracting-to-staging'
  | 'validating-hash'
  | 'validating-schema'
  | 'validating-business';

/** 校验进度事件。 */
export interface ValidationEvent {
  /** 导入任务 ID。 */
  jobId: Id;
  /** 当前校验阶段。 */
  stage: ValidationStage;
  /** 进度 0..1。 */
  progress: number;
  /** 已检查文件数。 */
  checkedFiles: number;
  /** 总文件数（可得时）。 */
  totalFiles?: number;
  /** 警告累计数。 */
  warningCount: number;
  /** 阻断错误（存在即失败）。 */
  blockingError?: AppError;
}

/** 导入后续阶段事件（ImportProgressEvent 联合类型第二支，对齐 04 §2 内联结构）。 */
export interface ImportPhaseEvent {
  /** 导入任务 ID。 */
  jobId: Id;
  /** 后续阶段标识。 */
  stage: 'awaiting-confirmation' | 'indexing' | 'promoting-to-final' | 'committing' | 'completed';
  /** 进度 0..1。 */
  progress: number;
  /** 警告累计数。 */
  warningCount: number;
  /** 阻断错误（存在即失败）。 */
  blockingError?: AppError;
}

/** 导入进度事件：校验阶段事件或后续阶段事件。 */
export type ImportProgressEvent = ValidationEvent | ImportPhaseEvent;

/** 导入完成结果。 */
export interface ImportResult {
  /** 导入任务 ID。 */
  jobId: Id;
  /** 书籍内部 ID。 */
  bookId: Id;
  /** 学习包外部包 ID。 */
  packageId: string;
  /** 内容版本。 */
  contentVersion: string;
  /** 新导入或升级。 */
  mode: 'new' | 'upgrade';
  /** 章节数（事务内重算）。 */
  chapterCount: number;
  /** 警告累计数。 */
  warningCount: number;
  /** 完成时间。 */
  completedAt: EpochMs;
}

/** 学习包流式校验器契约。 */
export interface PackageValidator {
  /**
   * 流式校验学习包，不解压先检查（LLD §2.1）。
   * @param sourceUri 学习包来源 URI
   * @param options 校验阈值参数
   * @returns 校验进度事件异步序列
   */
  validate(sourceUri: string, options: ValidationOptions): AsyncIterable<ValidationEvent>;
}

/** 导入服务编排契约（创建/校验/提交/取消）。 */
export interface ImportService {
  /**
   * 创建导入任务。
   * @param sourceUri 学习包来源 URI
   * @returns 导入任务 ID
   */
  create(sourceUri: string): Promise<Id>;
  /**
   * 运行校验并产出进度事件流。
   * @param jobId 导入任务 ID
   * @returns 导入进度事件异步序列
   */
  runValidation(jobId: Id): AsyncIterable<ImportProgressEvent>;
  /**
   * 提交导入（原子提升 + 提交，LLD §2.4 step11-13）。
   * @param jobId 导入任务 ID
   * @param mode 新导入或升级
   * @returns 导入完成结果
   */
  commit(jobId: Id, mode: 'new' | 'upgrade'): Promise<ImportResult>;
  /**
   * 取消导入任务并回滚暂存（LLD §2.6）。
   * @param jobId 导入任务 ID
   */
  cancel(jobId: Id): Promise<void>;
}
