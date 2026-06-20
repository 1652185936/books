/**
 * ZIP 安全校验器（P1-1，LLD §2.1 资源限制 + §2.4 step2，错误码 IMP-001~004）。
 *
 * 在「不解压」前提下，对中央目录枚举出的条目逐条做安全约束判定，先于解压拦截恶意/异常包：
 * - IMP-001 不是有效 ZIP：缓冲无法解析为 ZIP（无 EOCD / 中央目录损坏）。
 * - IMP-002 ZIP 路径穿越：绝对路径、`..` 回溯、盘符、反斜杠分隔、非法空段（ZIP Slip）。
 * - IMP-003 条目数量或大小超限：条目数 / 压缩包大小 / 解压总大小 / 单文件大小 /
 *   路径深度 / 文件名长度 / 路径长度 / 非允许（伪造）扩展名等「资源约束」违反。
 * - IMP-004 疑似压缩炸弹：单条目压缩比或整体压缩比超过 100:1。
 *
 * 错误码分类裁决（§2.1 与 IMP 表的对齐说明，避免自造错误码）：
 *   IMP 表在 ZIP 阶段仅提供 IMP-001~004 四个码。§2.1「ZIP 资源限制」表把条目数、各类大小、
 *   路径深度、文件名/路径长度、允许扩展名统一归为同一节「资源限制」。因此除「路径穿越」(IMP-002)
 *   与「压缩比」(IMP-004) 两类有专属语义外，其余资源约束（含伪造扩展名）统一落 IMP-003。
 *   该归类不新增/不改写 IMP 语义，仅在既有码内做确定性分派；具体子原因记入 `AppError.detail`（脱敏）。
 *
 * 日志/脱敏：`detail` 仅含「子原因 token + 包内相对路径（截断）」，相对路径非设备敏感路径；
 * 经 `AppErrors.create` 统一截断 ≤ 1000 字符（CLAUDE.md §5 / 04 §1）。
 */
import { AppError } from '../../domain/entities/common';
import { ValidationOptions } from '../../domain/entities/import';
import { AppErrors } from '../../utils/AppErrors';
import { ZipCentralDirectoryReader, ZipEntry, ZipParseResult } from './ZipCentralDirectory';
import { ALLOWED_EXTENSIONS, IMAGE_EXTENSIONS, ZIP_SAFETY_LIMITS, ZipSafetyLimits } from './ImportLimits';

/** 校验统计（成功时回传，供进度/报告展示，不含用户内容）。 */
export interface ZipSafetyStats {
  /** 条目总数。 */
  entryCount: number;
  /** 解压后总字节数（各条目压缩前大小之和）。 */
  totalUncompressedBytes: number;
  /** 压缩包字节数（来自文件大小或缓冲长度）。 */
  archiveBytes: number;
}

/** 校验结论（成功或带阻断错误的失败）。 */
export interface ZipSafetyOutcome {
  /** 是否通过。 */
  ok: boolean;
  /** 阻断错误（`ok=false` 时存在）。 */
  error?: AppError;
  /** 校验统计（`ok=true` 时存在）。 */
  stats?: ZipSafetyStats;
}

/** ZIP 盘符前缀匹配（如 `C:`，Windows 绝对路径风险）。 */
const DRIVE_LETTER_PATTERN: RegExp = /^[A-Za-z]:/;

/** ZIP 安全校验器（静态方法集合）。 */
export class ZipSafetyValidator {
  /**
   * 对完整 ZIP 字节缓冲执行安全校验（不解压）。
   * @param bytes 完整 ZIP 字节缓冲。
   * @param archiveByteLength 压缩包真实字节数（一般等于 `bytes.length`，由上层文件大小提供）。
   * @param options 校验阈值（《04》§2 `ValidationOptions`，DTO 级四阈值 + 支持主版本）。
   * @returns 校验结论。
   */
  static validate(
    bytes: Uint8Array, archiveByteLength: number, options: ValidationOptions): ZipSafetyOutcome {
    // 路径/扩展名/分类大小等内部约束（§2.1 固化常量）
    const limits: ZipSafetyLimits = ZIP_SAFETY_LIMITS;

    // 前置：压缩包大小（先于解析，超限即拒，避免无谓处理）
    if (archiveByteLength > options.maxArchiveBytes) {
      return ZipSafetyValidator.fail('IMP-003',
        `archive-too-large:${archiveByteLength}>${options.maxArchiveBytes}`);
    }

    // 解析中央目录（不解压）
    const parsed: ZipParseResult = ZipCentralDirectoryReader.read(bytes);
    if (!parsed.ok) {
      // 解析失败原因映射：zip64 量级超限→IMP-003，其余→IMP-001
      if (parsed.reason === 'exceeds-zip64') {
        return ZipSafetyValidator.fail('IMP-003', 'zip64-exceeds-limits');
      }
      return ZipSafetyValidator.fail('IMP-001', `not-a-valid-zip:${parsed.reason}`);
    }

    // 条目数上限
    const entries: ZipEntry[] = parsed.entries;
    if (entries.length > options.maxEntries) {
      return ZipSafetyValidator.fail('IMP-003',
        `too-many-entries:${entries.length}>${options.maxEntries}`);
    }

    // 解压总大小累计
    let totalUncompressed: number = 0;
    for (let i: number = 0; i < entries.length; i++) {
      // 逐条目安全判定（命中即 fail-fast）
      const entry: ZipEntry = entries[i];
      const entryError: AppError | undefined = ZipSafetyValidator.checkEntry(entry, limits, options);
      if (entryError !== undefined) {
        return { ok: false, error: entryError };
      }
      totalUncompressed += entry.uncompressedSize;
    }

    // 解压后总大小上限
    if (totalUncompressed > options.maxExpandedBytes) {
      return ZipSafetyValidator.fail('IMP-003',
        `expanded-too-large:${totalUncompressed}>${options.maxExpandedBytes}`);
    }

    // 整体压缩比兜底（防止单条目均不超标但整体异常膨胀）
    if (archiveByteLength > 0
      && totalUncompressed / archiveByteLength > options.maxCompressionRatio) {
      return ZipSafetyValidator.fail('IMP-004', 'aggregate-ratio-exceeded');
    }

    return {
      ok: true,
      stats: {
        entryCount: entries.length,
        totalUncompressedBytes: totalUncompressed,
        archiveBytes: archiveByteLength
      }
    };
  }

  /**
   * 单条目安全判定：路径穿越(IMP-002) → 路径约束/扩展名/单文件大小(IMP-003) → 压缩比(IMP-004)。
   * @param entry 条目。
   * @param limits 内部资源限制常量。
   * @param options DTO 级阈值（压缩比上限）。
   * @returns 命中阻断时返回 AppError，否则 undefined。
   */
  private static checkEntry(
    entry: ZipEntry, limits: ZipSafetyLimits, options: ValidationOptions): AppError | undefined {
    // 路径穿越（IMP-002）
    const traversalReason: string | undefined = ZipSafetyValidator.detectPathTraversal(entry.fileName);
    if (traversalReason !== undefined) {
      return ZipSafetyValidator.error('IMP-002', `${traversalReason}:${ZipSafetyValidator.brief(entry.fileName)}`);
    }

    // 路径长度约束（IMP-003）
    if (entry.fileName.length > limits.maxPathLength) {
      return ZipSafetyValidator.error('IMP-003',
        `path-too-long:${entry.fileName.length}>${limits.maxPathLength}`);
    }
    // 路径段：深度与单段长度
    const segments: string[] = ZipSafetyValidator.meaningfulSegments(entry.fileName);
    if (segments.length > limits.maxPathDepth) {
      return ZipSafetyValidator.error('IMP-003',
        `path-too-deep:${segments.length}>${limits.maxPathDepth}`);
    }
    for (let i: number = 0; i < segments.length; i++) {
      if (segments[i].length > limits.maxSegmentLength) {
        return ZipSafetyValidator.error('IMP-003',
          `segment-too-long:${segments[i].length}>${limits.maxSegmentLength}`);
      }
    }

    // 目录条目无扩展名/大小/压缩比判定
    if (entry.isDirectory) {
      return undefined;
    }

    // 扩展名允许列表（伪造扩展名防御，IMP-003）
    const ext: string = ZipSafetyValidator.extensionOf(entry.fileName);
    if (ALLOWED_EXTENSIONS.indexOf(ext) < 0) {
      return ZipSafetyValidator.error('IMP-003',
        `extension-not-allowed:${ZipSafetyValidator.brief(ext)}`);
    }

    // 单文件大小（按类型分类上限，IMP-003）
    const maxBytes: number = ZipSafetyValidator.maxBytesForExtension(ext, limits);
    if (entry.uncompressedSize > maxBytes) {
      return ZipSafetyValidator.error('IMP-003',
        `file-too-large:${entry.uncompressedSize}>${maxBytes}`);
    }

    // 压缩比（IMP-004）：压缩为 0 而解压非 0 视为异常；否则比值超限即炸弹
    if (entry.uncompressedSize > 0) {
      if (entry.compressedSize === 0) {
        return ZipSafetyValidator.error('IMP-004', 'zero-compressed-nonzero-expanded');
      }
      if (entry.uncompressedSize / entry.compressedSize > options.maxCompressionRatio) {
        return ZipSafetyValidator.error('IMP-004',
          `entry-ratio-exceeded:${ZipSafetyValidator.brief(entry.fileName)}`);
      }
    }

    return undefined;
  }

  /**
   * 检测路径穿越风险，返回子原因 token；无风险返回 undefined。
   * 拒绝：反斜杠分隔、绝对路径、盘符前缀、`..` 回溯段、非法空段。
   * @param fileName 条目相对路径。
   * @returns 子原因 token 或 undefined。
   */
  private static detectPathTraversal(fileName: string): string | undefined {
    if (fileName.length === 0) {
      return 'empty-name';
    }
    // 反斜杠：ZIP 规范用 `/`，出现 `\` 视为分隔符伪装/ZIP Slip 向量
    if (fileName.indexOf('\\') >= 0) {
      return 'backslash-separator';
    }
    // 绝对路径
    if (fileName.charAt(0) === '/') {
      return 'absolute-path';
    }
    // 盘符前缀（如 C:）
    if (DRIVE_LETTER_PATTERN.test(fileName)) {
      return 'drive-letter';
    }
    // 逐段检查 `..` 与非法空段
    const rawSegments: string[] = fileName.split('/');
    for (let i: number = 0; i < rawSegments.length; i++) {
      // 当前段
      const seg: string = rawSegments[i];
      if (seg === '..') {
        return 'parent-traversal';
      }
      // 末段允许为空（目录条目的尾部 `/`）；其余位置的空段视为非法路径
      if (seg.length === 0 && i !== rawSegments.length - 1) {
        return 'empty-segment';
      }
    }
    return undefined;
  }

  /**
   * 取「有意义」的路径段（剔除 `.` 当前目录段与尾部空段），用于深度与单段长度判定。
   * @param fileName 条目相对路径。
   * @returns 有意义路径段数组。
   */
  private static meaningfulSegments(fileName: string): string[] {
    // 过滤后的段集合
    const result: string[] = [];
    // 原始分段
    const rawSegments: string[] = fileName.split('/');
    for (let i: number = 0; i < rawSegments.length; i++) {
      // 当前段
      const seg: string = rawSegments[i];
      if (seg.length > 0 && seg !== '.') {
        result.push(seg);
      }
    }
    return result;
  }

  /**
   * 取文件名（最后一段）的小写扩展名（含前导点）；无扩展名返回空串。
   * @param fileName 条目相对路径。
   * @returns 小写扩展名或空串。
   */
  private static extensionOf(fileName: string): string {
    // 末段（最后一个 `/` 之后）
    const slash: number = fileName.lastIndexOf('/');
    const lastSegment: string = slash >= 0 ? fileName.substring(slash + 1) : fileName;
    // 末段内最后一个点
    const dot: number = lastSegment.lastIndexOf('.');
    if (dot <= 0) {
      // 无点或以点开头（隐藏文件无扩展名）→ 视为无扩展名
      return '';
    }
    return lastSegment.substring(dot).toLowerCase();
  }

  /**
   * 按扩展名取单文件大小上限：JSON→10MB、图片→8MB、其余允许文件→32MB（§2.1）。
   * @param ext 小写扩展名。
   * @param limits 内部资源限制常量。
   * @returns 该类型单文件字节上限。
   */
  private static maxBytesForExtension(ext: string, limits: ZipSafetyLimits): number {
    if (ext === '.json') {
      return limits.maxJsonBytes;
    }
    if (IMAGE_EXTENSIONS.indexOf(ext) >= 0) {
      return limits.maxImageBytes;
    }
    return limits.maxOtherBytes;
  }

  /**
   * 截断包内相对路径用于诊断（非设备敏感路径，但限长以防异常超长名）。
   * @param value 待截断字符串。
   * @returns 截断到 80 字符内的字符串。
   */
  private static brief(value: string): string {
    return value.length > 80 ? `${value.substring(0, 80)}…` : value;
  }

  /**
   * 构造阻断错误（终态拒绝，不可重试：内容/安全类违规）。
   * @param code IMP 错误码。
   * @param detail 子原因诊断（脱敏后写入）。
   * @returns AppError。
   */
  private static error(code: string, detail: string): AppError {
    return AppErrors.create(code, { retryable: false, detail: detail });
  }

  /**
   * 构造失败结论（包裹 `error`）。
   * @param code IMP 错误码。
   * @param detail 子原因诊断。
   * @returns 失败的 ZipSafetyOutcome。
   */
  private static fail(code: string, detail: string): ZipSafetyOutcome {
    return { ok: false, error: ZipSafetyValidator.error(code, detail) };
  }
}
