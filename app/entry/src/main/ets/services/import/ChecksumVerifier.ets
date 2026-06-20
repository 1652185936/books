/**
 * 暂存区 SHA-256 比对（P1-3，LLD §2.4 step7，错误码 IMP-009）。
 *
 * §2.4 step7：「对暂存目录内文件逐个计算 SHA-256 并比对 `checksums.json`」。本模块拆为两层：
 * - **纯比对逻辑** `verify(...)`：输入「已解析的 checksums 清单」+「实际哈希映射」+「暂存实际存在的文件列表」，
 *   产出结构化结论（算法是否为 sha256、哈希不符项、清单声明却缺失项、暂存多出的未列项），零 SDK 依赖、可单测。
 * - **字节哈希计算** 经注入端口 `HashComputer`（生产以 `@kit.CryptoArchitectureKit` 实现，留待 SDK 接线）。
 *
 * 判定口径（保守、确定性）：
 * - 算法必须为 `sha256`（checksums.schema `algorithm` const）；否则视为校验失败。
 * - 清单中声明的每个文件：缺失（暂存中无）或哈希不一致 → 阻断（IMP-009）。
 * - 暂存中存在但清单未列的文件：仅作 `unlisted` 诊断上报，step7 不因此失败（清单以 `additionalProperties:true`
 *   不闭合枚举；完整性归后续业务校验/引用校验，避免在哈希阶段越权判定）。
 *
 * 错误码与文案：IMP-009 为内容类**终态拒绝**（不可重试，R-015）；用户可读文案走 §3.14A 映射。
 * 脱敏：detail 仅含「计数 + 前若干条相对路径」，**绝不含任何哈希值或文件内容**（CLAUDE.md §5）。
 */
import { AppError } from '../../domain/entities/common';
import { ImportStateMachine } from './ImportStateMachine';
import { StagingArea } from './ImportStaging';

/** 已解析的 `checksums.json` 清单（仅取比对所需字段；其余字段忽略）。 */
export interface ChecksumsManifest {
  /** 哈希算法（须为 `sha256`）。 */
  algorithm: string;
  /** 文件相对路径 → 期望十六进制 SHA-256（64 位）。 */
  files: Record<string, string>;
}

/** SHA-256 比对结论（结构化，供编排层决策与脱敏摘要）。 */
export interface ChecksumVerifyResult {
  /** 是否通过（algorithm 正确且无缺失、无不符）。 */
  ok: boolean;
  /** 算法是否为 sha256。 */
  algorithmOk: boolean;
  /** 哈希不一致的相对路径列表。 */
  mismatched: string[];
  /** 清单声明却在暂存中缺失的相对路径列表。 */
  missing: string[];
  /** 暂存中存在但清单未列的相对路径列表（仅诊断，不阻断）。 */
  unlisted: string[];
}

/**
 * SHA-256 计算端口：对字节缓冲计算十六进制摘要（小写）。
 * 生产实现以 `@kit.CryptoArchitectureKit`（`cryptoFramework.createMd('SHA256')`）适配；单测以确定性假实现注入。
 */
export interface HashComputer {
  /**
   * 计算字节缓冲的 SHA-256 十六进制摘要（小写、64 字符）。
   * @param bytes 待哈希字节缓冲。
   * @returns 十六进制摘要字符串。
   */
  sha256(bytes: Uint8Array): Promise<string>;
}

/** 写入 IMP-009 `detail` 的相对路径条数上限（其余仅计数，控制体积与可读性）。 */
const MAX_DETAIL_PATHS: number = 5;
/** 清单不应包含其自身（`checksums.json` 不为自己计哈希）；比对/枚举时统一排除。 */
const SELF_FILE: string = 'checksums.json';

/**
 * 暂存区 SHA-256 校验器（静态方法集合）。
 */
export class ChecksumVerifier {
  /**
   * 纯比对：清单 vs 实际哈希 vs 暂存文件列表。
   * @param manifest 已解析的 checksums 清单。
   * @param actualHashes 暂存文件相对路径 → 实际十六进制 SHA-256（应已由 HashComputer 计算）。
   * @param presentFiles 暂存中实际存在的文件相对路径列表（用于检出 `unlisted`）。
   * @returns 结构化比对结论。
   */
  static verify(
    manifest: ChecksumsManifest, actualHashes: Record<string, string>, presentFiles: string[]): ChecksumVerifyResult {
    // 算法校验（大小写不敏感比较，规范声明为小写 const 'sha256'）
    const algorithmOk: boolean = typeof manifest.algorithm === 'string'
      && manifest.algorithm.toLowerCase() === 'sha256';

    // 哈希不符 / 缺失项
    const mismatched: string[] = [];
    const missing: string[] = [];
    // 遍历清单声明的每个文件
    const declared: string[] = Object.keys(manifest.files);
    for (let i: number = 0; i < declared.length; i++) {
      // 当前声明的相对路径
      const path: string = declared[i];
      if (path === SELF_FILE) {
        continue;
      }
      // 实际哈希（缺失为 undefined）
      const actual: string | undefined = actualHashes[path];
      if (actual === undefined) {
        missing.push(path);
        continue;
      }
      // 期望哈希（小写归一比较）
      const expected: string = manifest.files[path];
      if (actual.toLowerCase() !== expected.toLowerCase()) {
        mismatched.push(path);
      }
    }

    // 暂存多出（清单未列）项：仅诊断，不阻断
    const unlisted: string[] = [];
    for (let i: number = 0; i < presentFiles.length; i++) {
      // 当前暂存文件相对路径
      const present: string = presentFiles[i];
      if (present === SELF_FILE) {
        continue;
      }
      if (Object.keys(manifest.files).indexOf(present) < 0) {
        unlisted.push(present);
      }
    }

    // 通过条件：算法正确 + 无不符 + 无缺失
    const ok: boolean = algorithmOk && mismatched.length === 0 && missing.length === 0;
    return { ok: ok, algorithmOk: algorithmOk, mismatched: mismatched, missing: missing, unlisted: unlisted };
  }

  /**
   * 把失败的比对结论压缩为脱敏 IMP-009 错误（仅计数 + 前若干相对路径，绝不含哈希值）。
   * @param result 比对结论（应 `ok=false`）。
   * @returns 阻断错误 AppError（IMP-009，不可重试）。
   */
  static toError(result: ChecksumVerifyResult): AppError {
    // 失败子原因摘要片段
    const parts: string[] = [];
    if (!result.algorithmOk) {
      parts.push('algorithm-not-sha256');
    }
    parts.push(`mismatched=${result.mismatched.length}`);
    parts.push(`missing=${result.missing.length}`);
    // 附前若干条受影响相对路径（合并不符与缺失，去重前缀，控制条数）
    const affected: string[] = result.mismatched.concat(result.missing);
    const shown: number = Math.min(affected.length, MAX_DETAIL_PATHS);
    for (let i: number = 0; i < shown; i++) {
      parts.push(`path=${affected[i]}`);
    }
    // 经状态机统一构造（IMP-009 不可重试，文案走 §3.14A）
    return ImportStateMachine.buildFailure('IMP-009', parts.join(';'));
  }

  /**
   * 计算暂存区全部文件的 SHA-256 映射（逐文件读字节并哈希；排除 `checksums.json` 自身）。
   * 经注入的 `HashComputer` 实现，依赖暂存读取（SDK 字节读取，留待接线）；纯比对请用 `verify`。
   * @param staging 暂存区句柄。
   * @param files 暂存文件相对路径列表（一般取 `staging.listFiles()`）。
   * @param hasher SHA-256 计算端口。
   * @returns 相对路径 → 实际十六进制 SHA-256 映射。
   */
  static async computeStagingHashes(
    staging: StagingArea, files: string[], hasher: HashComputer): Promise<Record<string, string>> {
    // 结果映射
    const hashes: Record<string, string> = {};
    for (let i: number = 0; i < files.length; i++) {
      // 当前文件相对路径
      const path: string = files[i];
      if (path === SELF_FILE) {
        continue;
      }
      // 读取字节并计算摘要
      const bytes: Uint8Array = await staging.readBytes(path);
      hashes[path] = await hasher.sha256(bytes);
    }
    return hashes;
  }
}
