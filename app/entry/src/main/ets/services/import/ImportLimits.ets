/**
 * 学习包 ZIP 资源限制常量（P1-1，LLD §2.1「ZIP 资源限制」表 + 允许扩展名）。
 *
 * 唯一真值：LLD §2.1。本文件仅把规格表中的阈值固化为可被校验器消费的常量，
 * 不得在此自造或调整阈值语义；若与规格冲突须先在《已知冲突与裁决记录》登记。
 *
 * 取值依据（逐项对齐 §2.1 表，R-072）：
 * - 压缩包大小 ≤ 500 MB；解压后总大小 ≤ 2 GB；ZIP 条目数 ≤ 10,000；
 * - 单个 JSON ≤ 10 MB；单张图片 ≤ 8 MB；单个其他允许文件 ≤ 32 MB；
 * - 最大压缩比 100:1；路径深度 ≤ 8；单段文件名 ≤ 120 字符；完整相对路径 ≤ 240 字符。
 *
 * 允许扩展名：`.json .webp .png .jpg .jpeg`（§2.1）；第一版禁止 `.svg`、HTML、脚本、
 * 动态库、可执行文件和嵌套 ZIP——非允许列表内的扩展名一律拒绝（伪造扩展名防御，NFR-S-002）。
 */
import { ValidationOptions } from '../../domain/entities/import';

/** 1 KiB 字节数（仅用于阈值表达，避免散落的魔法数）。 */
const KIB: number = 1024;
/** 1 MiB 字节数。 */
const MIB: number = KIB * 1024;
/** 1 GiB 字节数。 */
const GIB: number = MIB * 1024;

/** §2.1 ZIP 资源限制阈值集合（实现内部常量，非跨模块 DTO）。 */
export interface ZipSafetyLimits {
  /** 压缩包大小上限（字节，§2.1 ≤ 500 MB）。 */
  maxArchiveBytes: number;
  /** 解压后总大小上限（字节，§2.1 ≤ 2 GB）。 */
  maxExpandedBytes: number;
  /** 条目数上限（§2.1 ≤ 10,000）。 */
  maxEntries: number;
  /** 单个 JSON 文件上限（字节，§2.1 ≤ 10 MB）。 */
  maxJsonBytes: number;
  /** 单张图片上限（字节，§2.1 ≤ 8 MB）。 */
  maxImageBytes: number;
  /** 单个其他允许文件上限（字节，§2.1 ≤ 32 MB）。 */
  maxOtherBytes: number;
  /** 最大压缩比（§2.1 100:1）。 */
  maxCompressionRatio: number;
  /** 路径深度上限（§2.1 ≤ 8）。 */
  maxPathDepth: number;
  /** 单段文件名长度上限（字符，§2.1 ≤ 120）。 */
  maxSegmentLength: number;
  /** 完整相对路径长度上限（字符，§2.1 ≤ 240）。 */
  maxPathLength: number;
}

/** §2.1 阈值固化值（唯一真值为规格表；改动须先改规格并登记裁决）。 */
export const ZIP_SAFETY_LIMITS: ZipSafetyLimits = {
  maxArchiveBytes: 500 * MIB,
  maxExpandedBytes: 2 * GIB,
  maxEntries: 10000,
  maxJsonBytes: 10 * MIB,
  maxImageBytes: 8 * MIB,
  maxOtherBytes: 32 * MIB,
  maxCompressionRatio: 100,
  maxPathDepth: 8,
  maxSegmentLength: 120,
  maxPathLength: 240
};

/** 允许扩展名（小写，含前导点；§2.1）。 */
export const ALLOWED_EXTENSIONS: string[] = ['.json', '.webp', '.png', '.jpg', '.jpeg'];

/** 图片扩展名子集（用于单文件大小分类，§2.1 单张图片 ≤ 8 MB）。 */
export const IMAGE_EXTENSIONS: string[] = ['.webp', '.png', '.jpg', '.jpeg'];

/** 支持的协议主版本号集合（manifest.schema `formatVersion` 形如 `1.x.y`，故主版本为 1）。 */
export const SUPPORTED_FORMAT_MAJORS: number[] = [1];

/**
 * 构造默认校验阈值参数（满足《04 契约》§2 `ValidationOptions` DTO）。
 * 仅暴露 DTO 定义的四个阈值 + 支持主版本；路径/扩展名/分类大小等内部约束见 `ZIP_SAFETY_LIMITS`。
 * @returns 与 §2.1 一致的默认 `ValidationOptions`。
 */
export function defaultValidationOptions(): ValidationOptions {
  // 默认阈值对象（逐字段取自 §2.1 固化值）
  const options: ValidationOptions = {
    maxArchiveBytes: ZIP_SAFETY_LIMITS.maxArchiveBytes,
    maxExpandedBytes: ZIP_SAFETY_LIMITS.maxExpandedBytes,
    maxEntries: ZIP_SAFETY_LIMITS.maxEntries,
    maxCompressionRatio: ZIP_SAFETY_LIMITS.maxCompressionRatio,
    supportedFormatMajors: SUPPORTED_FORMAT_MAJORS.slice()
  };
  return options;
}
