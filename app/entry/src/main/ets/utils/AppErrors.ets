import { AppError } from '../domain/entities/common';

/**
 * 领域错误工厂（P0-4，LLD §3.14A / 04 契约 §1）。
 *
 * 职责：
 * - 固化 §3.14A「error_code → i18n 资源键」**稳定映射**（本表只固化映射，
 *   中英文文案在 P0-5/§3.14B 的 `string.json` 落地，这里不重定义文案）；
 * - 统一构造 `AppError`：自动按错误码取资源键、对 `detail` 脱敏（≤1000 字符，
 *   禁止含完整正文/笔迹/敏感路径，CLAUDE.md §5）；
 * - 把任意捕获到的异常归一为 `AppError`，避免 Promise 抛裸字符串（04 §1）。
 *
 * 唯一真值：§3.14A 为映射真值，04 契约 §1 为 `AppError` 结构真值；本模块不得自造错误码语义。
 */

/** 通用数据库事务错误码（结构性错误，非用户内容流程；统一走兜底状态文案键）。 */
export const DB_TRANSACTION_FAILED: string = 'DB_TRANSACTION_FAILED';
/** 通用数据库查询错误码。 */
export const DB_QUERY_FAILED: string = 'DB_QUERY_FAILED';
/** 通用数据库写入错误码。 */
export const DB_WRITE_FAILED: string = 'DB_WRITE_FAILED';

/** `AppError.detail` 脱敏上限（04 契约 §1：detail 最多 1000 字符）。 */
const DETAIL_MAX_LEN: number = 1000;
/** 未命中 §3.14A 映射时的兜底文案资源键（§3.14B 通用状态键 `state.error`）。 */
const DEFAULT_MESSAGE_KEY: string = 'state.error';

/**
 * §3.14A error_code → i18n 资源键稳定映射（逐行对齐 LLD §3.14A 表）。
 * 末尾追加的 `DB_*` 通用结构性错误码统一映射到兜底状态键，文案在 P0-5 落盘。
 */
const ERROR_CODE_TO_MESSAGE_KEY: Record<string, string> = {
  'IMP-001': 'error.import.invalidZip',
  'IMP-002': 'error.import.pathTraversal',
  'IMP-003': 'error.import.limitExceeded',
  'IMP-004': 'error.import.zipBomb',
  'IMP-005': 'error.import.manifestMissing',
  'IMP-006': 'error.import.versionIncompatible',
  'IMP-007': 'error.import.jsonParse',
  'IMP-008': 'error.import.schemaInvalid',
  'IMP-009': 'error.import.hashMismatch',
  'IMP-010': 'error.import.referenceMissing',
  'IMP-011': 'error.import.chapterConflict',
  'IMP-012': 'error.import.answerMissing',
  'IMP-013': 'error.import.storageFull',
  'IMP-014': 'error.import.duplicateVersion',
  'IMP-015': 'warning.import.needsReview',
  'IMP-016': 'error.import.dbCommitFailed',
  'IMP-017': 'error.import.copyFailed',
  'IMP-018': 'error.import.extractFailed',
  'IMP-019': 'error.import.indexFailed',
  'IMP-020': 'error.import.unknownExerciseType',
  'timeout': 'error.recognition.timeout',
  'empty-text': 'error.recognition.emptyText',
  'service-unavailable': 'error.recognition.unavailable',
  'unsupported-mode': 'error.recognition.unsupportedMode',
  'internal-error': 'error.recognition.internal',
  'DB_TRANSACTION_FAILED': 'state.error',
  'DB_QUERY_FAILED': 'state.error',
  'DB_WRITE_FAILED': 'state.error',
  'DB_MIGRATION_FAILED': 'state.error'
};

/** 构造领域错误的可选参数（均可省略，省略时取安全默认）。 */
export interface CreateAppErrorOptions {
  /** 是否可重试，默认 `false`。 */
  retryable?: boolean;
  /** 诊断详情，写入前会被脱敏并截断。 */
  detail?: string;
  /** 覆盖默认资源键（仅在错误码未进 §3.14A 映射且需指定文案时使用）。 */
  messageKey?: string;
}

/**
 * 领域错误工具集。以静态方法暴露，风格与 `SqlScript`/`MigrationRunner` 一致。
 */
export class AppErrors {
  /**
   * 取错误码对应的 i18n 资源键；未命中 §3.14A 映射时回退到兜底状态键。
   * @param code 错误码（IMP-* / 识别码 / DB_* 等）。
   * @returns 资源键字符串。
   */
  static messageKeyFor(code: string): string {
    // 映射命中值（Record 索引在运行期可能为 undefined，故显式判空回退）
    const mapped: string | undefined = ERROR_CODE_TO_MESSAGE_KEY[code];
    return mapped !== undefined ? mapped : DEFAULT_MESSAGE_KEY;
  }

  /**
   * 对诊断详情脱敏：去首尾空白并截断到 `DETAIL_MAX_LEN`。
   * @param detail 原始诊断详情（调用方须保证不含完整正文/笔迹/敏感路径）。
   * @returns 脱敏后的详情字符串。
   */
  static sanitizeDetail(detail: string): string {
    // 去首尾空白后的详情
    const trimmed: string = detail.trim();
    return trimmed.length > DETAIL_MAX_LEN ? trimmed.substring(0, DETAIL_MAX_LEN) : trimmed;
  }

  /**
   * 构造领域错误。资源键默认按 §3.14A 映射，`detail` 自动脱敏。
   * @param code 错误码。
   * @param options 可选项（retryable / detail / messageKey）。
   * @returns AppError。
   */
  static create(code: string, options?: CreateAppErrorOptions): AppError {
    // 归一化可选项（缺省为空对象，字段各自取默认）
    const opts: CreateAppErrorOptions = options !== undefined ? options : {};
    // 组装基础错误（必填字段齐全）
    const error: AppError = {
      code: code,
      messageKey: opts.messageKey !== undefined ? opts.messageKey : AppErrors.messageKeyFor(code),
      retryable: opts.retryable !== undefined ? opts.retryable : false
    };
    // 仅当提供非空详情时写入脱敏后的 detail
    if (opts.detail !== undefined && opts.detail.length > 0) {
      error.detail = AppErrors.sanitizeDetail(opts.detail);
    }
    return error;
  }

  /**
   * 判断对象是否已是领域错误（鸭子类型：code/messageKey/retryable 齐备）。
   * @param value 待判断的值。
   * @returns 是 AppError 时为 true。
   */
  static isAppError(value: Object | null | undefined): value is AppError {
    if (value === null || value === undefined) {
      return false;
    }
    // 候选错误（仅用于读取字段做形态校验，不改变其语义）
    const candidate: AppError = value as AppError;
    return typeof candidate.code === 'string'
      && typeof candidate.messageKey === 'string'
      && typeof candidate.retryable === 'boolean';
  }

  /**
   * 把任意捕获到的异常归一为领域错误：已是 AppError 则透传，否则包成 `fallbackCode`。
   * @param cause 捕获到的异常对象。
   * @param fallbackCode 非 AppError 时使用的兜底错误码。
   * @returns AppError。
   */
  static from(cause: Object | null | undefined, fallbackCode: string): AppError {
    if (AppErrors.isAppError(cause)) {
      return cause as AppError;
    }
    return AppErrors.create(fallbackCode, { detail: AppErrors.briefMessage(cause) });
  }

  /**
   * 从异常对象提取简短结构性消息（不含用户内容/笔迹/敏感路径）。
   * @param cause 捕获到的异常对象。
   * @returns 简短消息字符串。
   */
  private static briefMessage(cause: Object | null | undefined): string {
    // BusinessError 继承自 Error，统一按 Error.message 提取
    if (cause instanceof Error) {
      return cause.message;
    }
    if (cause === null || cause === undefined) {
      return '';
    }
    return String(cause);
  }
}
