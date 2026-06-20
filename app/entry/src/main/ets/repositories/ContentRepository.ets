/**
 * 章节内容仓储（F05，LLD §6.5 + §3.4~§3.7；契约见《04-接口与DTO契约》§3 `ContentRepository`）。
 *
 * 职责：把 `chapters` / `sections` / `content_blocks` / `exercises` / `assets` 各表行组装为
 * Presentation 层使用的 `ChapterContent`（章节摘要 + 小节流 + 练习 ID 列表），并提供资源与封面
 * 沙箱相对路径查询。读取统一经 `BaseRepository.queryList/querySingle`（页面/ViewModel 不碰 SQL，
 * CLAUDE.md §5），`payload_json` 安全解析为 `JsonObject`，`source_pages_json` 还原为整数数组。
 *
 * 组装口径（与 ContentMapper 落库口径对偶）：
 * - `chapters.completion_percent` / `progress_status` 等进度字段是 `reading_progress` 的派生值，
 *   本仓储不负责进度（F-progress），章节摘要的进度字段以「无进度记录」默认值填充（completionPercent=0、
 *   progressStatus='not-started'），由进度模块后续覆盖，避免越权读 reading_progress。
 * - `sections` 与 `content_blocks` 均按 `order_no` 升序，保证渲染顺序与协议数组顺序一致（R-034）。
 * - `content_blocks.type` 不在此处做白名单过滤：未知 type 原样带出，由渲染层按 R-036 走 UnsupportedBlock。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore `querySql`/`ResultSet` API 以 API 12 为准；
 * SQL 组装/payload 解析/默认小节 R-034 逻辑已用 Node 端口 + 真实 SQLite 在 `.ralph/f05-test/` 回归。
 */
import { relationalStore } from '@kit.ArkData';
import { Database } from '../database/Database';
import { BaseRepository, RowMapper } from './BaseRepository';
import { AppErrors, DB_QUERY_FAILED } from '../utils/AppErrors';
import { Id, JsonObject } from '../domain/entities/common';
import {
  ChapterContent, ChapterSummary, SectionContent, ContentBlock, ContentRepository, ChapterKind
} from '../domain/entities/content';

/** 章节 kind 受控集合（§3.4 CHECK；用于把 DB 读出的字符串安全收敛到联合类型）。 */
const CHAPTER_KINDS: ChapterKind[] = ['lesson', 'review', 'appendix', 'answer-key', 'index'];

/** 内容块 type 受控集合（§5.2 协议白名单 / 04 契约 `ContentBlock.type`，11 种）。 */
const BLOCK_TYPES: ContentBlock['type'][] = [
  'heading', 'paragraph', 'formula', 'example', 'example-list',
  'bullet-list', 'table', 'timeline', 'callout', 'illustration', 'audio-text'
];

/**
 * 章节内容仓储实现。
 */
export class ContentRepositoryImpl extends BaseRepository implements ContentRepository {
  /**
   * @param database 已就绪的数据库封装。
   */
  constructor(database: Database) {
    super(database);
  }

  /**
   * 组装并返回某章节的完整内容（章节摘要 + 小节流 + 练习 ID 列表）。
   * @param chapterId 章节内部主键。
   * @returns 章节完整内容。
   * @throws AppError 章节不存在或查询失败时抛出（DB_QUERY_FAILED）。
   */
  async getChapter(chapterId: Id): Promise<ChapterContent> {
    // 章节摘要（不存在即视为查询失败，由上层映射为「章节损坏」态）
    const chapter: ChapterSummary | undefined = await this.queryChapterSummary(chapterId);
    if (chapter === undefined) {
      throw AppErrors.create(DB_QUERY_FAILED, { detail: `chapter-not-found:${chapterId}` });
    }
    // 小节列表（按 order_no 升序；空数组为合法态，走 ChapterEmptyView）
    const sections: SectionContent[] = await this.querySections(chapterId);
    // 练习 ID 列表（按 order_no 升序；含 enabled=0 的占位练习，渲染层据 enabled 决定占位提示）
    const exerciseIds: Id[] = await this.queryExerciseIds(chapterId);
    return { chapter, sections, exerciseIds };
  }

  /**
   * 列出某书全部章节摘要（按 order_no 升序），供 F05 目录抽屉换章与上一章/下一章导航。
   *
   * 说明：章节级目录的正式契约为 `BooksRepository.listChapters`（04 §3，含进度聚合）。该仓储在 F04 落地；
   * 在其落地前，F05 换章导航仅需「章节顺序 + 标题 + kind」，故本仓储提供一个**仅取章节表字段**的轻量列表
   * （进度字段以无进度默认值填充，不越权读 reading_progress），F04 BooksRepository 落地后页面可平滑切换其实现。
   *
   * @param bookId 书籍内部主键。
   * @returns 章节摘要数组（按 order 升序；进度字段为无进度默认值）。
   * @throws AppError 查询失败时抛出。
   */
  async listChapters(bookId: Id): Promise<ChapterSummary[]> {
    // 章节行 → 章节摘要映射器（进度字段置无进度默认值）
    const mapper: RowMapper<ChapterSummary> = (c: relationalStore.ResultSet): ChapterSummary => ({
      id: c.getString(c.getColumnIndex('id')),
      externalId: c.getString(c.getColumnIndex('external_id')),
      bookId: c.getString(c.getColumnIndex('book_id')),
      orderNo: c.getLong(c.getColumnIndex('order_no')),
      kind: ContentRepositoryImpl.toChapterKind(c.getString(c.getColumnIndex('kind'))),
      title: c.getString(c.getColumnIndex('title')),
      titleZh: c.getString(c.getColumnIndex('title_zh')),
      estimatedMinutes: c.getLong(c.getColumnIndex('estimated_minutes')),
      completionPercent: 0,
      progressStatus: 'not-started',
      reviewStatus: ContentRepositoryImpl.toReviewStatus(c.getString(c.getColumnIndex('review_status')))
    });
    return this.queryList(
      'SELECT id, external_id, book_id, order_no, kind, title, title_zh, estimated_minutes, '
      + 'review_status FROM chapters WHERE book_id = ? ORDER BY order_no ASC',
      mapper, [bookId]);
  }

  /**
   * 取资源沙箱相对路径（illustration / audio-text 等内容块的 assetUri 来源）。
   * @param assetId 资源内部主键。
   * @returns 沙箱相对路径；资源不存在时返回 undefined（渲染层走资源缺失态）。
   * @throws AppError 查询失败时抛出。
   */
  async getAssetUri(assetId: Id): Promise<string | undefined> {
    // 取 local_path（沙箱相对路径，不含设备绝对路径，CLAUDE.md §5）
    return this.querySingle(
      'SELECT local_path FROM assets WHERE id = ?',
      (c: relationalStore.ResultSet): string => c.getString(c.getColumnIndex('local_path')),
      [assetId]);
  }

  /**
   * 取书籍封面沙箱相对路径。
   * @param bookId 书籍内部主键。
   * @returns 封面沙箱相对路径；无封面或书籍不存在时返回 undefined。
   * @throws AppError 查询失败时抛出。
   */
  async getCoverUri(bookId: Id): Promise<string | undefined> {
    // cover_path 可空：读出 null 时映射为 undefined（缺封面走默认占位）
    return this.querySingle(
      'SELECT cover_path FROM books WHERE id = ?',
      (c: relationalStore.ResultSet): string | undefined => {
        // 列下标
        const idx: number = c.getColumnIndex('cover_path');
        return c.isColumnNull(idx) ? undefined : c.getString(idx);
      },
      [bookId]);
  }

  /**
   * 查询章节摘要（进度字段以「无进度」默认值填充，由进度模块后续覆盖）。
   * @param chapterId 章节内部主键。
   * @returns 章节摘要或 undefined。
   * @throws AppError 查询失败时抛出。
   */
  private async queryChapterSummary(chapterId: Id): Promise<ChapterSummary | undefined> {
    // 章节行 → 章节摘要映射器
    const mapper: RowMapper<ChapterSummary> = (c: relationalStore.ResultSet): ChapterSummary => ({
      id: c.getString(c.getColumnIndex('id')),
      externalId: c.getString(c.getColumnIndex('external_id')),
      bookId: c.getString(c.getColumnIndex('book_id')),
      orderNo: c.getLong(c.getColumnIndex('order_no')),
      kind: ContentRepositoryImpl.toChapterKind(c.getString(c.getColumnIndex('kind'))),
      title: c.getString(c.getColumnIndex('title')),
      titleZh: c.getString(c.getColumnIndex('title_zh')),
      estimatedMinutes: c.getLong(c.getColumnIndex('estimated_minutes')),
      // 进度字段：本仓储不读 reading_progress，置无进度默认值（F-progress 覆盖）
      completionPercent: 0,
      progressStatus: 'not-started',
      reviewStatus: ContentRepositoryImpl.toReviewStatus(c.getString(c.getColumnIndex('review_status')))
    });
    return this.querySingle(
      'SELECT id, external_id, book_id, order_no, kind, title, title_zh, estimated_minutes, '
      + 'review_status FROM chapters WHERE id = ?',
      mapper, [chapterId]);
  }

  /**
   * 查询章节下全部小节及其内容块（小节/块均按 order_no 升序）。
   * @param chapterId 章节内部主键。
   * @returns 小节内容数组（空数组为合法态）。
   * @throws AppError 查询失败时抛出。
   */
  private async querySections(chapterId: Id): Promise<SectionContent[]> {
    // 小节行（壳，blocks 待填充）
    const sections: SectionContent[] = await this.queryList(
      'SELECT id, external_id, type, title FROM sections WHERE chapter_id = ? ORDER BY order_no ASC',
      (c: relationalStore.ResultSet): SectionContent => ({
        id: c.getString(c.getColumnIndex('id')),
        externalId: c.getString(c.getColumnIndex('external_id')),
        type: c.getString(c.getColumnIndex('type')),
        title: c.getString(c.getColumnIndex('title')),
        blocks: []
      }),
      [chapterId]);
    // 逐小节填充内容块（小节数有限，按小节单查保证 order 与归属清晰）
    for (let i: number = 0; i < sections.length; i++) {
      sections[i].blocks = await this.queryBlocks(sections[i].id);
    }
    return sections;
  }

  /**
   * 查询某小节下的内容块（按 order_no 升序，payload 解析、source_pages 还原、assetUri 联表）。
   * @param sectionId 小节内部主键。
   * @returns 内容块数组。
   * @throws AppError 查询失败时抛出。
   */
  private async queryBlocks(sectionId: Id): Promise<ContentBlock[]> {
    // 内容块行 → DTO 映射器（payload_json 解析为 JsonObject；asset 经 LEFT JOIN 带出 local_path）
    const mapper: RowMapper<ContentBlock> = (c: relationalStore.ResultSet): ContentBlock => {
      // 块 DTO（type 原样带出，未知 type 由渲染层 R-036 兜底）
      const block: ContentBlock = {
        id: c.getString(c.getColumnIndex('id')),
        sectionId: c.getString(c.getColumnIndex('section_id')),
        orderNo: c.getLong(c.getColumnIndex('order_no')),
        type: ContentRepositoryImpl.toBlockType(c.getString(c.getColumnIndex('type'))),
        payload: ContentRepositoryImpl.parsePayload(c.getString(c.getColumnIndex('payload_json'))),
        plainText: c.getString(c.getColumnIndex('plain_text')),
        sourcePages: ContentRepositoryImpl.parseIntArray(c.getString(c.getColumnIndex('source_pages_json')))
      };
      // 可空：资源沙箱相对路径（asset_id 为空或资源缺失时 local_path 为 NULL）
      const assetIdx: number = c.getColumnIndex('asset_local_path');
      if (!c.isColumnNull(assetIdx)) {
        block.assetUri = c.getString(assetIdx);
      }
      return block;
    };
    return this.queryList(
      'SELECT b.id AS id, b.section_id AS section_id, b.order_no AS order_no, b.type AS type, '
      + 'b.payload_json AS payload_json, b.plain_text AS plain_text, '
      + 'b.source_pages_json AS source_pages_json, a.local_path AS asset_local_path '
      + 'FROM content_blocks b LEFT JOIN assets a ON b.asset_id = a.id '
      + 'WHERE b.section_id = ? ORDER BY b.order_no ASC',
      mapper, [sectionId]);
  }

  /**
   * 查询章节练习 ID 列表（按 order_no 升序，含 enabled=0 占位题，由渲染层据 enabled 决定占位提示）。
   * @param chapterId 章节内部主键。
   * @returns 练习内部主键数组。
   * @throws AppError 查询失败时抛出。
   */
  private async queryExerciseIds(chapterId: Id): Promise<Id[]> {
    return this.queryList(
      'SELECT id FROM exercises WHERE chapter_id = ? ORDER BY order_no ASC',
      (c: relationalStore.ResultSet): Id => c.getString(c.getColumnIndex('id')),
      [chapterId]);
  }

  /**
   * 把 DB 读出的 kind 字符串安全收敛到 `ChapterKind` 联合类型；非法值回退 'lesson'。
   * @param value DB 列值。
   * @returns 合法 ChapterKind。
   */
  private static toChapterKind(value: string): ChapterKind {
    return CHAPTER_KINDS.indexOf(value as ChapterKind) >= 0 ? (value as ChapterKind) : 'lesson';
  }

  /**
   * 把 DB 读出的 review_status 字符串安全收敛到 reviewStatus 联合类型；非法值回退 'unreviewed'。
   * @param value DB 列值。
   * @returns 合法 reviewStatus。
   */
  private static toReviewStatus(value: string): 'unreviewed' | 'needs-review' | 'reviewed' {
    return value === 'needs-review' || value === 'reviewed' ? value : 'unreviewed';
  }

  /**
   * 把 DB 读出的 block type 字符串安全收敛到 11 种白名单联合类型；未知 type 原样断言保留（R-036 由渲染层兜底）。
   * @param value DB 列值。
   * @returns 块类型（白名单内为对应字面量，白名单外原样断言，渲染层走 UnsupportedBlock）。
   */
  private static toBlockType(value: string): ContentBlock['type'] {
    // 未知 type 不在此处丢弃：保留原值供渲染层 R-036 判定（断言为联合类型，渲染分发再次校验）
    return BLOCK_TYPES.indexOf(value as ContentBlock['type']) >= 0
      ? (value as ContentBlock['type']) : (value as ContentBlock['type']);
  }

  /**
   * 安全解析 `payload_json` 为 `JsonObject`；解析失败或非对象时回退空对象（优雅降级，不崩溃）。
   * @param raw payload_json 原始串。
   * @returns JsonObject。
   */
  private static parsePayload(raw: string): JsonObject {
    try {
      // 解析结果（可能为对象/数组/原始值）
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as JsonObject;
      }
      return {};
    } catch (cause) {
      // payload 损坏不阻断整章渲染：降级为空对象，由渲染组件按缺字段优雅降级
      return {};
    }
  }

  /**
   * 安全解析整数数组 JSON 串（source_pages_json）；失败/非数组回退空数组。
   * @param raw 整数数组 JSON 串。
   * @returns 整数数组。
   */
  private static parseIntArray(raw: string): number[] {
    try {
      // 解析结果
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      // 仅保留数字项
      const out: number[] = [];
      for (let i: number = 0; i < parsed.length; i++) {
        // 当前项
        const item: Object = parsed[i] as Object;
        if (typeof item === 'number') {
          out.push(Math.trunc(item));
        }
      }
      return out;
    } catch (cause) {
      return [];
    }
  }
}
