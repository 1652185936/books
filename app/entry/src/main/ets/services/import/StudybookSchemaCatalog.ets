/**
 * 内置学习包 Schema 目录（P1-2，LLD §2.4 step8、R-043、信任边界 BR-002）。
 *
 * 三件职责：
 * 1) 把暂存目录内的相对路径**分类**到对应的内置 Schema 种类（manifest/book/chapter/report/checksums）；
 *    其余文件（assets/、以及**包内自带的 `schemas/`**）一律返回 undefined → 不参与 Schema 校验。
 *    **绝不**用包内 `schemas/` 校验包自身（封死信任边界，BR-002）。
 * 2) 声明内置 Schema 的来源契约 `SchemaProvider` 与内存实现 `InMemorySchemaProvider`（便于注入/测试）。
 * 3) 固化每种 Schema 的**应用内置** rawfile 资源路径（应用随包发布的可信副本，独立于不可信包内 `schemas/`）。
 *
 * 实际从 rawfile 读取内置 Schema 的 Provider 依赖 `resourceManager`（HarmonyOS SDK），与 P1-1 字节读取一致，
 * 留待 P1-3 导入状态机接线时实现；本轮提供纯逻辑分类器 + 内存 Provider，保证可测。
 */
import { JsonValue } from './JsonSchemaValidator';

/** 内置 Schema 种类（与 `packages/studybook-schema/` 五个 Schema 一一对应）。 */
export type StudybookSchemaKind = 'manifest' | 'book' | 'chapter' | 'report' | 'checksums';

/**
 * 每种 Schema 的**应用内置** rawfile 资源路径（相对 `resources/rawfile/`）。
 * 这些是应用随包发布的可信副本；导入校验只信任这些，绝不读包内 `schemas/`。
 */
export const BUILTIN_SCHEMA_RAWFILE: Record<StudybookSchemaKind, string> = {
  manifest: 'schemas/manifest.schema.json',
  book: 'schemas/book.schema.json',
  chapter: 'schemas/chapter.schema.json',
  report: 'schemas/report.schema.json',
  checksums: 'schemas/checksums.schema.json'
};

/** 章节文件相对路径模式：`chapters/` 下任意 `.json`（与 book.schema `toc[].file` 模式一致）。 */
const CHAPTER_FILE_PATTERN: RegExp = /^chapters\/.+\.json$/;

/**
 * 把暂存目录内相对路径分类到内置 Schema 种类；非结构化校验目标返回 undefined。
 *
 * - `manifest.json` → manifest；`book.json` → book；`report.json` → report；`checksums.json` → checksums；
 * - `chapters/*.json` → chapter；
 * - 其余（`assets/**`、**`schemas/**`**、未知文件）→ undefined（不在 step8 做 Schema 校验）。
 *
 * @param relativePath 暂存目录内的相对路径（以 `/` 分隔，无前导斜杠）。
 * @returns Schema 种类或 undefined。
 */
export function classifyStagingFile(relativePath: string): StudybookSchemaKind | undefined {
  switch (relativePath) {
    case 'manifest.json':
      return 'manifest';
    case 'book.json':
      return 'book';
    case 'report.json':
      return 'report';
    case 'checksums.json':
      return 'checksums';
    default:
      return CHAPTER_FILE_PATTERN.test(relativePath) ? 'chapter' : undefined;
  }
}

/** 内置 Schema 来源契约（按种类提供已解析的 Schema 对象）。 */
export interface SchemaProvider {
  /**
   * 取指定种类的内置 Schema（已解析为 JSON 值）。
   * @param kind Schema 种类。
   * @returns 已解析的 Schema；不可用时返回 undefined。
   */
  get(kind: StudybookSchemaKind): JsonValue | undefined;
}

/**
 * 内存 Schema Provider：以「种类 → 已解析 Schema」映射初始化。
 * 供单元测试与依赖注入使用；生产环境由 rawfile 读取后构造同形映射注入即可。
 */
export class InMemorySchemaProvider implements SchemaProvider {
  /** 种类 → 已解析 Schema 映射。 */
  private readonly schemas: Record<string, JsonValue>;

  /**
   * @param schemas 「种类 → 已解析 Schema」映射（键取 `StudybookSchemaKind`）。
   */
  constructor(schemas: Record<string, JsonValue>) {
    this.schemas = schemas;
  }

  /**
   * 取指定种类的内置 Schema。
   * @param kind Schema 种类。
   * @returns 已解析的 Schema；缺失返回 undefined。
   */
  get(kind: StudybookSchemaKind): JsonValue | undefined {
    return Object.keys(this.schemas).indexOf(kind) >= 0 ? this.schemas[kind] : undefined;
  }
}
