/**
 * 导入隔离暂存区（P1-3，LLD §2.2 目录布局 + §2.4 step6/step12 + §2.6 清理）。
 *
 * 职责：
 * - 纯函数派生「任务隔离暂存目录」与「正式包目录」的沙箱路径（§2.2）；暂存在 `temp/import/<jobId>/`，
 *   对书架不可见、唯一隔离；正式目录在 `files/books/<bookId>/`。
 * - 校验 `jobId`/`bookId` 作为单一路径段的安全性（拒绝 `/`、`\`、`..`、空段），从源头封死路径注入。
 * - 经注入的文件系统端口 `ImportFs` 提供暂存区的准备/清理/读取/递归枚举（实际 `@ohos.file.fs` 适配器留待
 *   SDK 接线；纯路径逻辑可用内存假实现单测）。
 *
 * 仅 POSIX 风格 `/` 拼接：HarmonyOS 沙箱路径以 `/` 分隔；`baseDir` 由运行期 `context.tempDir`/`context.filesDir`
 * 提供（绝对沙箱前缀，不进日志——CLAUDE.md §5）。
 */
import { AppError } from '../../domain/entities/common';
import { AppErrors } from '../../utils/AppErrors';

/** 暂存父目录名（位于 `tempDir` 下，§2.2 `temp/import/<jobId>/`）。 */
const STAGING_PARENT: string = 'import';
/** 正式书籍父目录名（位于 `filesDir` 下，§2.2 `files/books/<bookId>/`）。 */
const BOOKS_PARENT: string = 'books';
/** 正式包子目录名（§2.2 `.../package/`）。 */
const PACKAGE_DIR: string = 'package';
/** 派生资源子目录名（§2.2 `.../derived/`）。 */
const DERIVED_DIR: string = 'derived';

/**
 * 以 `/` 拼接路径段，剔除空段并归一化多余分隔符（不做 `..` 解析——非法段在 `assertSafeSegment` 处已拦截）。
 * @param parts 路径段数组。
 * @returns 拼接后的路径。
 */
function joinPath(parts: string[]): string {
  // 收集非空、去除首尾 `/` 的有效段
  const cleaned: string[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    // 当前段去除首尾分隔符
    let seg: string = parts[i];
    while (seg.length > 0 && seg.charAt(0) === '/') {
      seg = seg.substring(1);
    }
    while (seg.length > 0 && seg.charAt(seg.length - 1) === '/') {
      seg = seg.substring(0, seg.length - 1);
    }
    if (seg.length > 0) {
      cleaned.push(seg);
    }
  }
  // 保留原 baseDir 的前导 `/`（绝对沙箱路径）
  const prefix: string = parts.length > 0 && parts[0].charAt(0) === '/' ? '/' : '';
  return prefix + cleaned.join('/');
}

/**
 * 校验字符串可安全用作**单一路径段**（jobId/bookId）；非法即抛错，杜绝路径注入。
 * 拒绝：空串、含 `/` 或 `\` 分隔符、`.`/`..` 相对段。
 * @param segment 待校验路径段。
 * @param label 诊断标签（如 `jobId`）。
 * @throws AppError 非法时抛出 `DB_WRITE_FAILED`（脱敏 detail）。
 */
function assertSafeSegment(segment: string, label: string): void {
  // 非法条件：空 / 含分隔符 / 相对目录段
  const illegal: boolean = segment.length === 0
    || segment.indexOf('/') >= 0
    || segment.indexOf('\\') >= 0
    || segment === '.'
    || segment === '..';
  if (illegal) {
    throw AppErrors.create('DB_WRITE_FAILED', { detail: `unsafe-path-segment:${label}` });
  }
}

/**
 * 导入沙箱路径派生（全部为纯函数；`baseDir` 取运行期 `context.tempDir`/`context.filesDir`）。
 */
export class ImportPaths {
  /**
   * 任务隔离暂存根目录：`<tempDir>/import/<jobId>`（§2.2、§2.4 step6）。
   * @param tempDir 运行期临时目录绝对路径（`context.tempDir`）。
   * @param jobId 导入任务 ID（单一安全路径段）。
   * @returns 暂存根目录绝对路径。
   */
  static stagingRoot(tempDir: string, jobId: string): string {
    assertSafeSegment(jobId, 'jobId');
    return joinPath([tempDir, STAGING_PARENT, jobId]);
  }

  /**
   * 暂存区内某相对路径的绝对路径：`<stagingRoot>/<relativePath>`。
   * `relativePath` 应为已通过 P1-1 路径穿越校验的包内相对路径（此处再做一次防御性段校验）。
   * @param tempDir 运行期临时目录。
   * @param jobId 导入任务 ID。
   * @param relativePath 包内相对路径（`/` 分隔、无前导斜杠、无 `..`）。
   * @returns 绝对路径。
   * @throws AppError 相对路径含 `..`/反斜杠/绝对前缀时抛出。
   */
  static stagingFile(tempDir: string, jobId: string, relativePath: string): string {
    // 防御性校验相对路径（与 ZipSafetyValidator 同口径：拒绝穿越向量）
    ImportPaths.assertSafeRelative(relativePath);
    return joinPath([ImportPaths.stagingRoot(tempDir, jobId), relativePath]);
  }

  /**
   * 正式书籍根目录：`<filesDir>/books/<bookId>`（§2.2）。
   * @param filesDir 运行期文件目录绝对路径（`context.filesDir`）。
   * @param bookId 内部书籍 ID（单一安全路径段）。
   * @returns 书籍根目录绝对路径。
   */
  static bookRoot(filesDir: string, bookId: string): string {
    assertSafeSegment(bookId, 'bookId');
    return joinPath([filesDir, BOOKS_PARENT, bookId]);
  }

  /**
   * 正式包目录：`<filesDir>/books/<bookId>/package`（§2.4 step12 提升目标）。
   * @param filesDir 运行期文件目录。
   * @param bookId 内部书籍 ID。
   * @returns 正式包目录绝对路径。
   */
  static packageDir(filesDir: string, bookId: string): string {
    return joinPath([ImportPaths.bookRoot(filesDir, bookId), PACKAGE_DIR]);
  }

  /**
   * 派生资源目录：`<filesDir>/books/<bookId>/derived`（§2.2）。
   * @param filesDir 运行期文件目录。
   * @param bookId 内部书籍 ID。
   * @returns 派生资源目录绝对路径。
   */
  static derivedDir(filesDir: string, bookId: string): string {
    return joinPath([ImportPaths.bookRoot(filesDir, bookId), DERIVED_DIR]);
  }

  /**
   * 防御性校验包内相对路径不含穿越向量（绝对前缀 / `..` / 反斜杠 / 非法空段）。
   * @param relativePath 包内相对路径。
   * @throws AppError 含穿越向量时抛出 `DB_WRITE_FAILED`。
   */
  static assertSafeRelative(relativePath: string): void {
    // 非法整体形态：空 / 绝对路径 / 反斜杠分隔
    if (relativePath.length === 0 || relativePath.charAt(0) === '/' || relativePath.indexOf('\\') >= 0) {
      throw AppErrors.create('DB_WRITE_FAILED', { detail: 'unsafe-relative-path' });
    }
    // 逐段拒绝 `..`
    const segments: string[] = relativePath.split('/');
    for (let i: number = 0; i < segments.length; i++) {
      if (segments[i] === '..') {
        throw AppErrors.create('DB_WRITE_FAILED', { detail: 'unsafe-relative-path' });
      }
    }
  }
}

/**
 * 文件系统端口（导入流程所需的最小操作集）。
 * 生产实现以 `@ohos.file.fs`（`@kit.CoreFileKit`）适配；单测以内存假实现注入。
 * 所有路径均为运行期绝对沙箱路径。
 */
export interface ImportFs {
  /**
   * 路径是否存在。
   * @param path 绝对路径。
   * @returns 存在返回 true。
   */
  exists(path: string): Promise<boolean>;
  /**
   * 递归创建目录（已存在视为成功）。
   * @param path 目录绝对路径。
   */
  mkdirs(path: string): Promise<void>;
  /**
   * 递归删除文件或目录（不存在视为成功）。
   * @param path 绝对路径。
   */
  remove(path: string): Promise<void>;
  /**
   * 原子移动/重命名（用于 §2.4 step12 暂存→正式提升）。
   * @param from 源绝对路径。
   * @param to 目标绝对路径。
   */
  move(from: string, to: string): Promise<void>;
  /**
   * 读取文本（UTF-8）。
   * @param path 文件绝对路径。
   * @returns 文本内容。
   */
  readText(path: string): Promise<string>;
  /**
   * 读取字节。
   * @param path 文件绝对路径。
   * @returns 字节缓冲。
   */
  readBytes(path: string): Promise<Uint8Array>;
  /**
   * 递归枚举目录下所有**文件**（不含目录项）的相对路径（相对 `root`，`/` 分隔、无前导斜杠）。
   * @param root 目录绝对路径。
   * @returns 文件相对路径数组（顺序不保证）。
   */
  listFilesRecursive(root: string): Promise<string[]>;
}

/**
 * 单个导入任务的隔离暂存区句柄：绑定 `jobId` 与底层文件系统端口，封装准备/清理/读取/枚举。
 * 路径派生纯函数可单测；FS 操作经注入端口，便于内存假实现验证编排逻辑。
 */
export class StagingArea {
  /** 底层文件系统端口。 */
  private readonly fs: ImportFs;
  /** 运行期临时目录绝对路径（`context.tempDir`）。 */
  private readonly tempDir: string;
  /** 导入任务 ID。 */
  private readonly jobId: string;
  /** 本任务暂存根目录绝对路径（构造时一次性派生）。 */
  private readonly root: string;

  /**
   * @param fs 文件系统端口。
   * @param tempDir 运行期临时目录。
   * @param jobId 导入任务 ID（单一安全路径段）。
   */
  constructor(fs: ImportFs, tempDir: string, jobId: string) {
    this.fs = fs;
    this.tempDir = tempDir;
    this.jobId = jobId;
    this.root = ImportPaths.stagingRoot(tempDir, jobId);
  }

  /**
   * 暂存根目录绝对路径。
   * @returns 绝对路径。
   */
  getRoot(): string {
    return this.root;
  }

  /**
   * 暂存区内相对路径的绝对路径。
   * @param relativePath 包内相对路径。
   * @returns 绝对路径。
   */
  resolve(relativePath: string): string {
    return ImportPaths.stagingFile(this.tempDir, this.jobId, relativePath);
  }

  /**
   * 准备干净的隔离暂存目录：若残留则先整体删除，再重建（支持重试复用同一 jobId，R-015）。
   */
  async prepare(): Promise<void> {
    await this.fs.remove(this.root);
    await this.fs.mkdirs(this.root);
  }

  /**
   * 清理暂存目录（取消/失败统一清理，§2.6）。
   */
  async cleanup(): Promise<void> {
    await this.fs.remove(this.root);
  }

  /**
   * 递归枚举暂存区内所有文件的相对路径。
   * @returns 文件相对路径数组。
   */
  listFiles(): Promise<string[]> {
    return this.fs.listFilesRecursive(this.root);
  }

  /**
   * 读取暂存文件文本。
   * @param relativePath 包内相对路径。
   * @returns 文本内容。
   */
  readText(relativePath: string): Promise<string> {
    return this.fs.readText(this.resolve(relativePath));
  }

  /**
   * 读取暂存文件字节。
   * @param relativePath 包内相对路径。
   * @returns 字节缓冲。
   */
  readBytes(relativePath: string): Promise<Uint8Array> {
    return this.fs.readBytes(this.resolve(relativePath));
  }
}
