/**
 * 内容块 payload 安全取值工具（F05，LLD §6.5 / 《06》§3.2）。
 *
 * `ContentBlock.payload` 是 `JsonObject`（任意 JSON 形状）。各渲染组件按各自 `type` 的 payload 形状
 * 取字段；为满足 ArkTS 严格类型（禁无理由 any）且对缺字段优雅降级（CLAUDE.md §5），统一经本工具的
 * 静态取值器读 payload，缺字段/类型不符一律回退安全默认，绝不抛错或崩溃（R-036 配套）。
 *
 * payload 各 type 字段形状以协议 `chapter.schema.json` 的 block 与《06》§3.2 派生表为准；
 * 渲染端「按形状取字段」，schema 未强约束 block 内部结构时按最佳努力多候选字段名兼容。
 */
import { JsonObject } from '../../domain/entities/common';

/** 单个内容块的轻量视图模型基类字段（各组件按需扩展）。 */
export interface ExamplePair {
  /** 英文/原文。 */
  english: string;
  /** 中文/译文。 */
  chinese: string;
}

/** 公式片段（formula.parts[]）。 */
export interface FormulaPart {
  /** 片段文本。 */
  text: string;
  /** 片段角色（如 'subject'/'verb'/'operator'，用于着色，可空）。 */
  role: string;
}

/** 时间轴节点（timeline.events[] / nodes[]）。 */
export interface TimelineNode {
  /** 节点标题。 */
  title: string;
  /** 节点说明。 */
  description: string;
}

/** 表格视图（table.columns + rows）。 */
export interface TableView {
  /** 表头列。 */
  columns: string[];
  /** 数据行（每行单元格字符串数组）。 */
  rows: string[][];
}

/**
 * payload 安全取值器（静态方法集合，纯函数）。
 */
export class BlockPayload {
  /**
   * 读字符串字段；缺失/非串回退默认值。
   * @param payload 内容块 payload。
   * @param key 字段名。
   * @param fallback 默认值，缺省空串。
   * @returns 字符串。
   */
  static str(payload: JsonObject, key: string, fallback: string = ''): string {
    // 原始值
    const value: Object | null | undefined = payload[key];
    return typeof value === 'string' ? value : fallback;
  }

  /**
   * 按候选键顺序读首个存在的字符串字段；全缺失回退默认值。
   * @param payload 内容块 payload。
   * @param keys 候选字段名。
   * @param fallback 默认值，缺省空串。
   * @returns 字符串。
   */
  static strFirst(payload: JsonObject, keys: string[], fallback: string = ''): string {
    for (let i: number = 0; i < keys.length; i++) {
      // 当前候选值
      const value: Object | null | undefined = payload[keys[i]];
      if (typeof value === 'string') {
        return value;
      }
    }
    return fallback;
  }

  /**
   * 读数字字段；缺失/非数字回退默认值。
   * @param payload 内容块 payload。
   * @param key 字段名。
   * @param fallback 默认值。
   * @returns 数字。
   */
  static num(payload: JsonObject, key: string, fallback: number): number {
    // 原始值
    const value: Object | null | undefined = payload[key];
    return typeof value === 'number' ? value : fallback;
  }

  /**
   * 读布尔字段；缺失/非布尔回退默认值。
   * @param payload 内容块 payload。
   * @param key 字段名。
   * @param fallback 默认值，缺省 false。
   * @returns 布尔。
   */
  static bool(payload: JsonObject, key: string, fallback: boolean = false): boolean {
    // 原始值
    const value: Object | null | undefined = payload[key];
    return typeof value === 'boolean' ? value : fallback;
  }

  /**
   * 读字符串数组字段（仅保留字符串项）；缺失/非数组回退空数组。
   * @param payload 内容块 payload。
   * @param key 字段名。
   * @returns 字符串数组。
   */
  static strArray(payload: JsonObject, key: string): string[] {
    // 原始值
    const value: Object | null | undefined = payload[key];
    if (!Array.isArray(value)) {
      return [];
    }
    // 结果数组
    const out: string[] = [];
    for (let i: number = 0; i < value.length; i++) {
      // 当前项
      const item: Object = value[i] as Object;
      if (typeof item === 'string') {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 读对象数组字段（仅保留对象项）；缺失/非数组回退空数组。
   * @param payload 内容块 payload。
   * @param key 字段名。
   * @returns 对象数组。
   */
  static objArray(payload: JsonObject, key: string): JsonObject[] {
    // 原始值
    const value: Object | null | undefined = payload[key];
    if (!Array.isArray(value)) {
      return [];
    }
    // 结果数组
    const out: JsonObject[] = [];
    for (let i: number = 0; i < value.length; i++) {
      // 当前项
      const item: Object = value[i] as Object;
      if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
        out.push(item as JsonObject);
      }
    }
    return out;
  }

  /**
   * 把列表项数组（项可为字符串或 `{text}` 对象）收敛为字符串数组（bullet-list 用）。
   * @param payload 内容块 payload。
   * @param key 字段名（默认 'items'）。
   * @returns 列表项文本数组。
   */
  static listItems(payload: JsonObject, key: string = 'items'): string[] {
    // 原始值
    const value: Object | null | undefined = payload[key];
    if (!Array.isArray(value)) {
      return [];
    }
    // 结果数组
    const out: string[] = [];
    for (let i: number = 0; i < value.length; i++) {
      // 当前项
      const item: Object = value[i] as Object;
      if (typeof item === 'string') {
        out.push(item);
      } else if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
        out.push(BlockPayload.str(item as JsonObject, 'text', ''));
      }
    }
    return out;
  }

  /**
   * 解析 formula.parts[] 为 FormulaPart 数组。
   * @param payload 内容块 payload。
   * @returns 公式片段数组。
   */
  static formulaParts(payload: JsonObject): FormulaPart[] {
    // 原始对象数组
    const items: JsonObject[] = BlockPayload.objArray(payload, 'parts');
    // 结果数组
    const out: FormulaPart[] = [];
    for (let i: number = 0; i < items.length; i++) {
      out.push({
        text: BlockPayload.str(items[i], 'text', ''),
        role: BlockPayload.str(items[i], 'role', '')
      });
    }
    return out;
  }

  /**
   * 解析 example/example-list 的样例对（english + chinese）。
   * @param payload 内容块 payload（单个 example 对象或 example-list 中的元素）。
   * @returns 样例对。
   */
  static examplePair(payload: JsonObject): ExamplePair {
    return {
      english: BlockPayload.strFirst(payload, ['english', 'en', 'source'], ''),
      chinese: BlockPayload.strFirst(payload, ['chinese', 'zh', 'translation'], '')
    };
  }

  /**
   * 解析 example-list.examples[] 为样例对数组。
   * @param payload 内容块 payload。
   * @returns 样例对数组。
   */
  static exampleList(payload: JsonObject): ExamplePair[] {
    // 原始对象数组
    const items: JsonObject[] = BlockPayload.objArray(payload, 'examples');
    // 结果数组
    const out: ExamplePair[] = [];
    for (let i: number = 0; i < items.length; i++) {
      out.push(BlockPayload.examplePair(items[i]));
    }
    return out;
  }

  /**
   * 解析 timeline.events[] / nodes[] 为节点数组。
   * @param payload 内容块 payload。
   * @returns 时间轴节点数组。
   */
  static timelineNodes(payload: JsonObject): TimelineNode[] {
    // 优先 events，回退 nodes（《06》§3.2 兼容两种字段名）
    let items: JsonObject[] = BlockPayload.objArray(payload, 'events');
    if (items.length === 0) {
      items = BlockPayload.objArray(payload, 'nodes');
    }
    // 结果数组
    const out: TimelineNode[] = [];
    for (let i: number = 0; i < items.length; i++) {
      out.push({
        title: BlockPayload.str(items[i], 'title', ''),
        description: BlockPayload.strFirst(items[i], ['description', 'desc', 'detail'], '')
      });
    }
    return out;
  }

  /**
   * 解析 table.columns + rows 为表格视图（rows 内单元格收敛为字符串）。
   * @param payload 内容块 payload。
   * @returns 表格视图。
   */
  static table(payload: JsonObject): TableView {
    // 表头列
    const columns: string[] = BlockPayload.strArray(payload, 'columns');
    // 原始行
    const rawRows: Object | null | undefined = payload['rows'];
    // 结果行
    const rows: string[][] = [];
    if (Array.isArray(rawRows)) {
      for (let i: number = 0; i < rawRows.length; i++) {
        // 当前行（应为字符串数组）
        const row: Object = rawRows[i] as Object;
        // 单元格收敛
        const cells: string[] = [];
        if (Array.isArray(row)) {
          for (let j: number = 0; j < row.length; j++) {
            // 当前单元格（字符串/数字均转字符串展示）
            const cell: Object = row[j] as Object;
            if (typeof cell === 'string') {
              cells.push(cell);
            } else if (typeof cell === 'number' || typeof cell === 'boolean') {
              cells.push(String(cell));
            } else {
              cells.push('');
            }
          }
        }
        rows.push(cells);
      }
    }
    return { columns, rows };
  }
}
