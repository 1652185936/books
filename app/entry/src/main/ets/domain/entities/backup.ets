/**
 * 备份 DTO 契约（《04-接口与DTO契约》§11，F12 数据导出/恢复）。
 */
import { EpochMs, AppError } from './common';

/** 导出选项。 */
export interface ExportOptions {
  /** 是否包含书籍。 */
  includeBooks: boolean;
  /** 是否包含进度。 */
  includeProgress: boolean;
  /** 是否包含作答记录。 */
  includeAttempts: boolean;
  /** 是否包含手写笔迹。 */
  includeHandwriting: boolean;
  /** 是否包含批注。 */
  includeNotes: boolean;
}

/** 备份兼容性校验结果。 */
export interface BackupValidationResult {
  /** 是否兼容。 */
  compatible: boolean;
  /** 备份格式版本。 */
  formatVersion: string;
  /** 备份创建时间。 */
  createdAt: EpochMs;
  /** 书籍数。 */
  bookCount: number;
  /** 预估解压后字节数。 */
  estimatedExpandedBytes: number;
  /** 警告列表。 */
  warnings: AppError[];
  /** 阻断错误列表。 */
  blockingErrors: AppError[];
}

/** 恢复模式。 */
export type RestoreMode = 'merge' | 'replace-all';

/** 备份服务契约。 */
export interface BackupService {
  /**
   * 导出备份。
   * @param options 导出选项
   * @returns 备份文件沙箱相对路径
   */
  export(options: ExportOptions): Promise<string>;
  /**
   * 校验备份兼容性（formatVersion 兼容判定，P3-2）。
   * @param uri 备份文件 URI
   * @returns 校验结果
   */
  validateBackup(uri: string): Promise<BackupValidationResult>;
  /**
   * 恢复备份。
   * @param uri 备份文件 URI
   * @param mode 恢复模式
   */
  restore(uri: string, mode: RestoreMode): Promise<void>;
}
