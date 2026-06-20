/**
 * 学习包 Schema 校验编排器（P1-2，LLD §2.4 step7→step8 衔接，错误码 IMP-007 / IMP-008）。
 *
 * 把通用引擎 `JsonSchemaValidator` 与目录分类 `classifyStagingFile`/`SchemaProvider` 组合为导入流程可直接消费的两步：
 * - `parseJson`：把暂存文件文本解析为 JSON；解析失败记 **IMP-007**（不含解析器原文，防内容泄露）。
 * - `validateAgainstSchema`：按文件相对路径选内置 Schema 做结构校验；任一违规记 **IMP-008**（仅结构化摘要，无实例值）。
 *
 * 设计取舍：本编排器仍是**纯逻辑**（输入文本/已解析 JSON + 注入的 `SchemaProvider`），不读文件、不依赖 SDK；
 * 暂存文件的字节读取与三次落盘时序由 P1-3 导入状态机接线（与 P1-1 不解压安全内核同样的分层）。
 *
 * 错误码归属（不新增/不改写语义，仅在既有 IMP 表内分派）：
 * - JSON 解析失败 → IMP-007（§2.5）；Schema 结构校验失败 → IMP-008（§2.4 step8、§2.5）。
 * - 二者均为**阻断、终态拒绝**（内容类，不可重试，与 §2.6 重试分类一致）。
 */
import { AppError } from '../../domain/entities/common';
import { AppErrors } from '../../utils/AppErrors';
import { JsonSchemaValidator, JsonValue, SchemaViolation } from './JsonSchemaValidator';
import { classifyStagingFile, SchemaProvider, StudybookSchemaKind } from './StudybookSchemaCatalog';

/** JSON 解析结果（成功带值，失败带 IMP-007 错误）。 */
export interface JsonParseOutcome {
  /** 是否解析成功。 */
  ok: boolean;
  /** 解析所得 JSON 值（`ok=true` 时存在）。 */
  value?: JsonValue;
  /** 解析失败错误（`ok=false` 时存在，IMP-007）。 */
  error?: AppError;
}

/** Schema 校验结果（通过或带 IMP-008 错误）。 */
export interface SchemaCheckOutcome {
  /** 是否通过（未分类文件视为「不适用」也置 true）。 */
  ok: boolean;
  /** 命中的 Schema 种类（已分类时存在）。 */
  kind?: StudybookSchemaKind;
  /** 校验失败错误（`ok=false` 时存在，IMP-008）。 */
  error?: AppError;
}

/** 写入 IMP-008 `detail` 的违规摘要条数上限（其余仅计数，控制 detail 体积与可读性）。 */
const MAX_DETAIL_VIOLATIONS: number = 3;

/**
 * 学习包 Schema 校验编排器（静态方法集合）。
 */
export class PackageSchemaValidator {
  /**
   * 解析暂存文件文本为 JSON；失败归一为 IMP-007。
   * @param relativePath 暂存目录内相对路径（仅用于诊断定位，不含设备敏感路径）。
   * @param text 文件文本内容。
   * @returns 解析结果。
   */
  static parseJson(relativePath: string, text: string): JsonParseOutcome {
    try {
      // 解析所得 JSON 值（ArkTS JSON.parse 返回 Object，按 JsonValue 下行转型）
      const value: JsonValue = JSON.parse(text) as JsonValue;
      return { ok: true, value: value };
    } catch (e) {
      // 仅记录文件名定位，不带解析器原文（可能含正文片段，CLAUDE.md §5）
      return {
        ok: false,
        error: AppErrors.create('IMP-007', { retryable: false, detail: `json-parse-failed:${relativePath}` })
      };
    }
  }

  /**
   * 按文件相对路径选内置 Schema 校验已解析 JSON；任一违规归一为 IMP-008。
   * 未分类文件（assets/、包内 schemas/ 等）视为「不适用」直接通过——信任边界 BR-002。
   * @param relativePath 暂存目录内相对路径。
   * @param parsed 已解析的 JSON 值。
   * @param provider 内置 Schema 来源（仅用应用内置可信副本）。
   * @returns 校验结果。
   */
  static validateAgainstSchema(
    relativePath: string, parsed: JsonValue, provider: SchemaProvider): SchemaCheckOutcome {
    // 文件分类（未分类→不适用，直接通过）
    const kind: StudybookSchemaKind | undefined = classifyStagingFile(relativePath);
    if (kind === undefined) {
      return { ok: true };
    }
    // 内置 Schema（缺失视为环境/构建缺陷，按 Schema 失败处理，避免漏校验放行）
    const schema: JsonValue | undefined = provider.get(kind);
    if (schema === undefined) {
      return {
        ok: false,
        kind: kind,
        error: AppErrors.create('IMP-008', { retryable: false, detail: `builtin-schema-missing:${kind}` })
      };
    }
    // 违规列表
    const violations: SchemaViolation[] = JsonSchemaValidator.validate(schema, parsed);
    if (violations.length === 0) {
      return { ok: true, kind: kind };
    }
    return {
      ok: false,
      kind: kind,
      error: AppErrors.create('IMP-008', {
        retryable: false,
        detail: PackageSchemaValidator.summarize(kind, relativePath, violations)
      })
    };
  }

  /**
   * 一步式：解析 + 校验（先 IMP-007 再 IMP-008），供导入流程直接调用。
   * @param relativePath 暂存目录内相对路径。
   * @param text 文件文本内容。
   * @param provider 内置 Schema 来源。
   * @returns 失败时返回首个阻断错误（IMP-007 或 IMP-008）；通过返回 undefined。
   */
  static parseAndValidate(relativePath: string, text: string, provider: SchemaProvider): AppError | undefined {
    // 解析结果
    const parseOutcome: JsonParseOutcome = PackageSchemaValidator.parseJson(relativePath, text);
    if (!parseOutcome.ok || parseOutcome.value === undefined) {
      return parseOutcome.error;
    }
    // 校验结果
    const checkOutcome: SchemaCheckOutcome =
      PackageSchemaValidator.validateAgainstSchema(relativePath, parseOutcome.value, provider);
    return checkOutcome.ok ? undefined : checkOutcome.error;
  }

  /**
   * 把违规列表压缩为脱敏摘要：`schema=<kind>;file=<path>;violations=<n>;` + 前若干条 `path keyword:hint`。
   * 仅含结构化信息（路径/关键字/原因），不含任何实例值。
   * @param kind Schema 种类。
   * @param relativePath 文件相对路径。
   * @param violations 违规列表。
   * @returns 脱敏摘要字符串（最终再经 AppErrors 截断 ≤1000）。
   */
  private static summarize(
    kind: StudybookSchemaKind, relativePath: string, violations: SchemaViolation[]): string {
    // 摘要片段
    const parts: string[] = [`schema=${kind}`, `file=${relativePath}`, `violations=${violations.length}`];
    // 取前 MAX_DETAIL_VIOLATIONS 条逐条拼接
    const shown: number = Math.min(violations.length, MAX_DETAIL_VIOLATIONS);
    for (let i: number = 0; i < shown; i++) {
      // 当前违规
      const v: SchemaViolation = violations[i];
      parts.push(`${v.path} ${v.keyword}:${v.hint}`);
    }
    return parts.join(';');
  }
}
