import { relationalStore } from '@kit.ArkData';
import { Database } from '../database/Database';
import { BaseRepository, RowMapper } from './BaseRepository';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import { Id } from '../domain/entities/common';
import {
  BookSummary,
  BookDetail,
  BookListQuery,
  BookStatus,
  ContinueTarget,
  ChapterSummary,
  ChapterKind,
  SearchResult,
  BooksRepository as IBooksRepository
} from '../domain/entities/content';

/**
 * 书架与书籍仓储（F01，LLD §6.1 / 04 契约 §3）。
 *
 * 实现 `list`/`get`/`markBroken`（F01）与 `listChapters`/`searchChapters`（F04，章节级，LLD §6.4 / 04 契约 §3）。
 * 全部读取经 `BaseRepository.queryList`/`querySingle`，写入经 `runInTransaction`；页面/ViewModel 不直接执行 SQL（CLAUDE.md §5）。
 *
 * 派生口径（唯一真值）：
 * - `completionPercent` = `bookCompletion`：`kind IN ('lesson','review')` 章节的 `reading_progress.completion_percent`
 *   算术平均（LLD §3.12.1；该集合为空时为 0），保留 1 位小数四舍五入。
 * - `continueTarget` = 该书 `reading_progress` 中 `last_opened_at` 最大、且 `completion_percent < 100` 的章节定位
 *   （LLD §6.1「继续学习进入上次章节」/ FR-F01-03）；无可续读章节时省略。
 * - `coverUri` 取 `books.cover_path`（沙箱相对路径，§1.3：只存相对路径）。
 * - 查询默认排除 `status='deleted'`（§1.3 / §8.1：软删书全入口隐藏）；`includeBroken` 为 true 时纳入 `status='broken'`，
 *   否则连损坏书一并排除（书架默认只显示 ready/updating，broken 经「书籍损坏」态显隐由查询参数控制）。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore `querySql`/`executeSql`/`ResultSet` API 以 API 12 为准。
 */
export class BooksRepository extends BaseRepository implements IBooksRepository {
  /**
   * 构造书籍仓储。
   * @param database 已完成迁移、就绪的数据库封装。
   */
  constructor(database: Database) {
    super(database);
  }

  /**
   * 列出书架书籍（默认排除已删除；按 `includeBroken` 决定是否含损坏书）。
   *
   * 聚合 `books` 与每本书的 `reading_progress` 派生 `completionPercent`/`continueTarget`，
   * 关键字命中 `title`/`subtitle`（不区分大小写），排序由 `query.sort` 决定。
   * @param query 列表查询（排序 / 关键字 / 是否含损坏书）。
   * @returns 书籍摘要数组（不含已删除书；按指定排序）。
   * @throws AppError 查询失败时抛出 `DB_QUERY_FAILED`。
   */
  async list(query: BookListQuery): Promise<BookSummary[]> {
    // 是否纳入 status='broken' 的损坏书（默认仅 ready/updating）
    const includeBroken: boolean = query.includeBroken === true;
    // 关键字过滤（去空白后非空才生效）；空串/纯空白视为不过滤
    const keyword: string = (query.keyword ?? '').trim();
    // SQL 绑定参数（与占位符 ? 一一对应）
    const bindArgs: relationalStore.ValueType[] = [];
    // 状态过滤子句：永远排除 deleted；不含 broken 时再排除 broken
    let statusClause: string = "b.status != 'deleted'";
    if (!includeBroken) {
      statusClause += " AND b.status != 'broken'";
    }
    // 关键字子句：命中主/副标题（SQLite LIKE 对 ASCII 不区分大小写）
    let keywordClause: string = '';
    if (keyword.length > 0) {
      keywordClause = ' AND (b.title LIKE ? OR b.subtitle LIKE ?)';
      // LIKE 通配参数：左右各加 % 做包含匹配
      const like: string = `%${BooksRepository.escapeLike(keyword)}%`;
      bindArgs.push(like);
      bindArgs.push(like);
    }
    // 排序子句（白名单映射，避免 SQL 注入；非法值回退 last-opened）
    const orderClause: string = BooksRepository.orderClauseFor(query.sort);
    // 单次聚合查询：books 左连其 lesson/review 章节的 reading_progress 求平均完成度
    const sql: string =
      'SELECT b.id AS id, b.package_id AS package_id, b.content_version AS content_version,' +
      ' b.title AS title, b.subtitle AS subtitle, b.authors_json AS authors_json,' +
      ' b.cover_path AS cover_path, b.chapter_count AS chapter_count, b.status AS status,' +
      ' b.last_opened_at AS last_opened_at,' +
      ' COALESCE(comp.avg_percent, 0) AS completion_percent' +
      ' FROM books b' +
      ' LEFT JOIN (' +
      '   SELECT rp.book_id AS book_id, AVG(rp.completion_percent) AS avg_percent' +
      '   FROM reading_progress rp' +
      '   JOIN chapters c ON c.id = rp.chapter_id' +
      "   WHERE c.kind IN ('lesson', 'review')" +
      '   GROUP BY rp.book_id' +
      ' ) comp ON comp.book_id = b.id' +
      ` WHERE ${statusClause}${keywordClause}` +
      ` ORDER BY ${orderClause}`;
    // 行映射器：列 → BookSummary（不含 continueTarget，下一步逐本补齐）
    const mapper: RowMapper<BookSummary> = (cursor: relationalStore.ResultSet): BookSummary =>
      BooksRepository.mapSummaryRow(cursor);
    // 基础摘要列表
    const summaries: BookSummary[] = await this.queryList(sql, mapper, bindArgs);
    // 逐本补齐 continueTarget（按最近打开且未完成的章节）
    for (const summary of summaries) {
      // 当前书的续读目标（无则保持 undefined）
      const target: ContinueTarget | undefined = await this.findContinueTarget(summary.id);
      if (target !== undefined) {
        summary.continueTarget = target;
      }
    }
    return summaries;
  }

  /**
   * 取书籍详情（在摘要基础上补充 description/languages/importedAt/updatedAt）。
   *
   * 默认排除已删除书：传入已删除 / 不存在的 bookId 时抛出查询失败领域错误，不返回脏数据。
   * @param bookId 书籍内部主键。
   * @returns 书籍详情。
   * @throws AppError 书籍不存在或已删除时抛出 `DB_QUERY_FAILED`。
   */
  async get(bookId: Id): Promise<BookDetail> {
    // 详情查询：补充 description/languages_json/imported_at/updated_at；排除已删除
    const sql: string =
      'SELECT b.id AS id, b.package_id AS package_id, b.content_version AS content_version,' +
      ' b.title AS title, b.subtitle AS subtitle, b.authors_json AS authors_json,' +
      ' b.cover_path AS cover_path, b.chapter_count AS chapter_count, b.status AS status,' +
      ' b.last_opened_at AS last_opened_at, b.description AS description,' +
      ' b.languages_json AS languages_json, b.imported_at AS imported_at, b.updated_at AS updated_at,' +
      ' COALESCE(comp.avg_percent, 0) AS completion_percent' +
      ' FROM books b' +
      ' LEFT JOIN (' +
      '   SELECT rp.book_id AS book_id, AVG(rp.completion_percent) AS avg_percent' +
      '   FROM reading_progress rp' +
      '   JOIN chapters c ON c.id = rp.chapter_id' +
      "   WHERE c.kind IN ('lesson', 'review')" +
      '   GROUP BY rp.book_id' +
      ' ) comp ON comp.book_id = b.id' +
      " WHERE b.id = ? AND b.status != 'deleted'";
    // 详情行映射器：在摘要列基础上叠加详情字段
    const mapper: RowMapper<BookDetail> = (cursor: relationalStore.ResultSet): BookDetail =>
      BooksRepository.mapDetailRow(cursor);
    // 单本详情（不存在/已删除时为 undefined）
    const detail: BookDetail | undefined = await this.querySingle(sql, mapper, [bookId]);
    if (detail === undefined) {
      // 不存在或已删除：抛查询失败领域错误（不返回脏数据）
      throw AppErrors.create('DB_QUERY_FAILED', { detail: 'book-not-found-or-deleted' });
    }
    // 补齐续读目标
    const target: ContinueTarget | undefined = await this.findContinueTarget(detail.id);
    if (target !== undefined) {
      detail.continueTarget = target;
    }
    return detail;
  }

  /**
   * 标记书籍为损坏态（写 `status='broken'` 并刷新 `updated_at`）。
   *
   * 仅对未删除书生效（不复活已删除书）；`reasonCode` 仅用于结构化诊断，不写库（books 无原因列），
   * 故只取其形态用于日志/调用约定，不输出用户内容（CLAUDE.md §5）。写入经事务，可回滚。
   * @param bookId 书籍内部主键。
   * @param reasonCode 损坏原因码（调用方提供，用于上层诊断；本方法不持久化）。
   * @returns 无返回值（写入完成即 resolve）。
   * @throws AppError 写入失败时抛出 `DB_WRITE_FAILED`。
   */
  async markBroken(bookId: Id, reasonCode: string): Promise<void> {
    // reasonCode 当前仅参与调用契约，不落库（避免在 books 表臆造列，CLAUDE.md §8）；读取以满足无用形参告警
    void reasonCode;
    // 当前时间戳（UTC epoch ms，§1.3）
    const now: number = Date.now();
    await this.runInTransaction(async (store: relationalStore.RdbStore): Promise<void> => {
      // 置 broken 并刷新 updated_at；排除已删除书，避免软删书被复活为 broken
      await store.executeSql(
        "UPDATE books SET status = 'broken', updated_at = ? WHERE id = ? AND status != 'deleted'",
        [now, bookId]
      );
    }).catch((cause: Object): never => {
      // 事务封装已归一为领域错误，这里二次兜底为写入失败码（已是 AppError 则透传）
      throw AppErrors.from(cause, DB_WRITE_FAILED);
    });
  }

  /**
   * 列出某书全部章节摘要（目录页 ChapterList，F04 / LLD §6.4，04 契约 §3 `listChapters`）。
   *
   * 单次 `chapters LEFT JOIN reading_progress` 聚合派生口径（唯一真值，LLD §6.4「数据」列）：
   * - `completionPercent` 取该章 `reading_progress.completion_percent`，无进度行缺省 0；
   * - `progressStatus` 取该章 `reading_progress.status`，无进度行缺省 'not-started'；
   * - `reviewStatus` 取 `chapters.review_status`。
   * 章节全集纳入（含 appendix/answer-key/index 等所有 kind，目录需完整展示），按 `order_no` 升序。
   * @param bookId 书籍内部主键。
   * @returns 章节摘要数组（按 order_no 升序；进度字段来自 reading_progress，缺行用默认值）。
   * @throws AppError 查询失败时抛出 `DB_QUERY_FAILED`。
   */
  async listChapters(bookId: Id): Promise<ChapterSummary[]> {
    // LEFT JOIN 进度表：无进度行时 status/completion_percent 为 NULL，由映射器 readOptionalDouble/toProgressStatus 兜底默认值
    const sql: string =
      'SELECT c.id AS id, c.external_id AS external_id, c.book_id AS book_id,' +
      ' c.order_no AS order_no, c.kind AS kind, c.title AS title, c.title_zh AS title_zh,' +
      ' c.estimated_minutes AS estimated_minutes, c.review_status AS review_status,' +
      ' rp.completion_percent AS completion_percent, rp.status AS progress_status' +
      ' FROM chapters c' +
      ' LEFT JOIN reading_progress rp ON rp.chapter_id = c.id AND rp.book_id = c.book_id' +
      ' WHERE c.book_id = ?' +
      ' ORDER BY c.order_no ASC';
    // 行映射器：列 → ChapterSummary（进度字段缺行用默认值）
    const mapper: RowMapper<ChapterSummary> = (cursor: relationalStore.ResultSet): ChapterSummary =>
      BooksRepository.mapChapterSummaryRow(cursor);
    return this.queryList(sql, mapper, [bookId]);
  }

  /**
   * 章节级搜索（目录页 ChapterSearch，F04 / LLD §6.4，04 契约 §3 `searchChapters`）。
   *
   * 命中 `title` / `title_zh`（不区分大小写，LIKE 包含匹配，复用 `escapeLike` 防通配放大）。
   * `matchedField` 优先取 `title`（命中 title）否则 `titleZh`（命中 title_zh）；`matchedText` 取对应命中字段的原文。
   * 关键字去空白后为空 → 视为「未发起搜索」，返回空数组（由 VM 据此回落到「正常」全量列表态，不与「无匹配」混淆，LLD §6.4）。
   * @param bookId 书籍内部主键。
   * @param keyword 用户输入关键字（含首尾空白，内部去空白）。
   * @returns 搜索结果数组（按 order_no 升序）；空关键字返回空数组。
   * @throws AppError 查询失败时抛出 `DB_QUERY_FAILED`。
   */
  async searchChapters(bookId: Id, keyword: string): Promise<SearchResult[]> {
    // 去空白后的关键字（空则不发起搜索，返回空数组）
    const trimmed: string = keyword.trim();
    if (trimmed.length === 0) {
      return [];
    }
    // LIKE 通配参数：左右各加 %（escapeLike 转义关键字内 %/_，避免放大匹配）
    const like: string = `%${BooksRepository.escapeLike(trimmed)}%`;
    // 命中 title 或 title_zh（SQLite LIKE 对 ASCII 不区分大小写），按 order_no 升序返回
    const sql: string =
      'SELECT c.id AS id, c.external_id AS external_id, c.order_no AS order_no,' +
      ' c.title AS title, c.title_zh AS title_zh' +
      ' FROM chapters c' +
      ' WHERE c.book_id = ? AND (c.title LIKE ? OR c.title_zh LIKE ?)' +
      ' ORDER BY c.order_no ASC';
    // 行映射器：列 + 关键字 → SearchResult（matchedField/matchedText 据命中字段判定）
    const mapper: RowMapper<SearchResult> = (cursor: relationalStore.ResultSet): SearchResult =>
      BooksRepository.mapSearchResultRow(cursor, trimmed);
    return this.queryList(sql, mapper, [bookId, like, like]);
  }

  /**
   * 查询某书的续读目标：取该书 `reading_progress` 中 `last_opened_at` 最大、
   * 且 `completion_percent < 100` 的章节定位（LLD §6.1 / FR-F01-03）。
   * @param bookId 书籍内部主键。
   * @returns 续读目标（章节/小节/内容块）；无未完成的已打开章节时为 undefined。
   * @throws AppError 查询失败时抛出 `DB_QUERY_FAILED`。
   */
  private async findContinueTarget(bookId: Id): Promise<ContinueTarget | undefined> {
    // 续读目标查询：未完成且最近打开优先；NULL 的 last_opened_at 排在最后
    const sql: string =
      'SELECT rp.chapter_id AS chapter_id, rp.last_section_id AS last_section_id,' +
      ' rp.last_block_id AS last_block_id' +
      ' FROM reading_progress rp' +
      ' WHERE rp.book_id = ? AND rp.completion_percent < 100 AND rp.last_opened_at IS NOT NULL' +
      ' ORDER BY rp.last_opened_at DESC' +
      ' LIMIT 1';
    // 续读目标行映射器
    const mapper: RowMapper<ContinueTarget> = (cursor: relationalStore.ResultSet): ContinueTarget =>
      BooksRepository.mapContinueTargetRow(cursor);
    return this.querySingle(sql, mapper, [bookId]);
  }

  /**
   * 把 `BookListQuery.sort` 映射为 SQL ORDER BY 子句（白名单，杜绝注入）。
   * @param sort 排序方式（last-opened / title / imported-at）。
   * @returns ORDER BY 后的列与方向子句。
   */
  private static orderClauseFor(sort: BookListQuery['sort']): string {
    if (sort === 'title') {
      // 按标题升序（同名再按导入时间降序稳定排序）
      return 'b.title ASC, b.imported_at DESC';
    }
    if (sort === 'imported-at') {
      // 按导入时间降序（新导入在前）
      return 'b.imported_at DESC';
    }
    // 默认 last-opened：最近打开在前，从未打开（NULL）排最后，再按导入时间降序兜底
    return 'b.last_opened_at IS NULL ASC, b.last_opened_at DESC, b.imported_at DESC';
  }

  /**
   * 转义 LIKE 模式中的通配符（% 与 _）及转义符自身，配合默认 `\` 转义字符使用。
   * 注：本仓储的 LIKE 子句未显式声明 ESCAPE，转义仅为防止用户关键字中的 %/_ 改变匹配语义而做的保守处理。
   * @param raw 用户原始关键字。
   * @returns 转义后的关键字片段。
   */
  private static escapeLike(raw: string): string {
    // 依次转义 \、%、_，避免关键字内通配符放大匹配范围
    return raw.split('\\').join('\\\\').split('%').join('\\%').split('_').join('\\_');
  }

  /**
   * 把结果集当前行映射为 `BookSummary`（不含 continueTarget，由调用方补齐）。
   * @param cursor 结果集（停在目标行）。
   * @returns 书籍摘要。
   */
  private static mapSummaryRow(cursor: relationalStore.ResultSet): BookSummary {
    // 完成度：聚合平均后保留 1 位小数四舍五入（§3.12.1）
    const completionPercent: number = BooksRepository.round1(cursor.getDouble(cursor.getColumnIndex('completion_percent')));
    // 封面相对路径：cover_path 可空，空值映射为 undefined
    const coverUri: string | undefined = BooksRepository.readOptionalText(cursor, 'cover_path');
    // 上次打开时间：last_opened_at 可空
    const lastOpenedAt: number | undefined = BooksRepository.readOptionalLong(cursor, 'last_opened_at');
    // 组装摘要（continueTarget 由上层补齐）
    const summary: BookSummary = {
      id: cursor.getString(cursor.getColumnIndex('id')),
      packageId: cursor.getString(cursor.getColumnIndex('package_id')),
      contentVersion: cursor.getString(cursor.getColumnIndex('content_version')),
      title: cursor.getString(cursor.getColumnIndex('title')),
      subtitle: cursor.getString(cursor.getColumnIndex('subtitle')),
      authors: BooksRepository.parseStringArray(cursor.getString(cursor.getColumnIndex('authors_json'))),
      chapterCount: cursor.getLong(cursor.getColumnIndex('chapter_count')),
      completionPercent: completionPercent,
      status: BooksRepository.toBookStatus(cursor.getString(cursor.getColumnIndex('status')))
    };
    if (coverUri !== undefined) {
      summary.coverUri = coverUri;
    }
    if (lastOpenedAt !== undefined) {
      summary.lastOpenedAt = lastOpenedAt;
    }
    return summary;
  }

  /**
   * 把结果集当前行映射为 `BookDetail`（先取摘要列，再叠加详情列）。
   * @param cursor 结果集（停在目标行）。
   * @returns 书籍详情。
   */
  private static mapDetailRow(cursor: relationalStore.ResultSet): BookDetail {
    // 复用摘要映射取公共字段
    const base: BookSummary = BooksRepository.mapSummaryRow(cursor);
    // 叠加详情字段，构造完整 BookDetail
    const detail: BookDetail = {
      id: base.id,
      packageId: base.packageId,
      contentVersion: base.contentVersion,
      title: base.title,
      subtitle: base.subtitle,
      authors: base.authors,
      chapterCount: base.chapterCount,
      completionPercent: base.completionPercent,
      status: base.status,
      description: cursor.getString(cursor.getColumnIndex('description')),
      languages: BooksRepository.parseStringArray(cursor.getString(cursor.getColumnIndex('languages_json'))),
      importedAt: cursor.getLong(cursor.getColumnIndex('imported_at')),
      updatedAt: cursor.getLong(cursor.getColumnIndex('updated_at'))
    };
    if (base.coverUri !== undefined) {
      detail.coverUri = base.coverUri;
    }
    if (base.lastOpenedAt !== undefined) {
      detail.lastOpenedAt = base.lastOpenedAt;
    }
    return detail;
  }

  /**
   * 把结果集当前行映射为 `ContinueTarget`（chapterId 必有，section/block 可空）。
   * @param cursor 结果集（停在目标行）。
   * @returns 续读目标。
   */
  private static mapContinueTargetRow(cursor: relationalStore.ResultSet): ContinueTarget {
    // 续读小节（可空）
    const sectionId: string | undefined = BooksRepository.readOptionalText(cursor, 'last_section_id');
    // 续读内容块（可空）
    const blockId: string | undefined = BooksRepository.readOptionalText(cursor, 'last_block_id');
    // 组装续读目标（章节必有）
    const target: ContinueTarget = {
      chapterId: cursor.getString(cursor.getColumnIndex('chapter_id'))
    };
    if (sectionId !== undefined) {
      target.sectionId = sectionId;
    }
    if (blockId !== undefined) {
      target.blockId = blockId;
    }
    return target;
  }

  /**
   * 把结果集当前行映射为 `ChapterSummary`（listChapters 用）。
   * 进度字段来自 LEFT JOIN 的 reading_progress：无进度行（列为 NULL）时回落 completionPercent=0 / progressStatus='not-started'。
   * @param cursor 结果集（停在目标行）。
   * @returns 章节摘要。
   */
  private static mapChapterSummaryRow(cursor: relationalStore.ResultSet): ChapterSummary {
    // 完成度：reading_progress.completion_percent，缺行（NULL）为 0
    const completionPercent: number = BooksRepository.readOptionalDouble(cursor, 'completion_percent') ?? 0;
    // 进度状态：reading_progress.status，缺行（NULL）为 'not-started'
    const progressStatus: string | undefined = BooksRepository.readOptionalText(cursor, 'progress_status');
    return {
      id: cursor.getString(cursor.getColumnIndex('id')),
      externalId: cursor.getString(cursor.getColumnIndex('external_id')),
      bookId: cursor.getString(cursor.getColumnIndex('book_id')),
      orderNo: cursor.getLong(cursor.getColumnIndex('order_no')),
      kind: BooksRepository.toChapterKind(cursor.getString(cursor.getColumnIndex('kind'))),
      title: cursor.getString(cursor.getColumnIndex('title')),
      titleZh: cursor.getString(cursor.getColumnIndex('title_zh')),
      estimatedMinutes: cursor.getLong(cursor.getColumnIndex('estimated_minutes')),
      completionPercent: completionPercent,
      progressStatus: BooksRepository.toProgressStatus(progressStatus),
      reviewStatus: BooksRepository.toReviewStatus(cursor.getString(cursor.getColumnIndex('review_status')))
    };
  }

  /**
   * 把结果集当前行映射为 `SearchResult`（searchChapters 用）。
   * `matchedField`/`matchedText` 据关键字命中字段判定：优先 title，否则 titleZh。
   * @param cursor 结果集（停在目标行）。
   * @param keyword 去空白后的关键字（不区分大小写做命中判定）。
   * @returns 搜索结果。
   */
  private static mapSearchResultRow(cursor: relationalStore.ResultSet, keyword: string): SearchResult {
    // 章节英文/中文标题
    const title: string = cursor.getString(cursor.getColumnIndex('title'));
    const titleZh: string = cursor.getString(cursor.getColumnIndex('title_zh'));
    // 不区分大小写命中判定（与 SQL LIKE 的 ASCII 大小写不敏感口径一致）
    const needle: string = keyword.toLowerCase();
    const titleHit: boolean = title.toLowerCase().indexOf(needle) >= 0;
    // 命中字段与命中文本：title 优先，否则 titleZh
    const matchedField: SearchResult['matchedField'] = titleHit ? 'title' : 'titleZh';
    const matchedText: string = titleHit ? title : titleZh;
    return {
      chapterId: cursor.getString(cursor.getColumnIndex('id')),
      externalId: cursor.getString(cursor.getColumnIndex('external_id')),
      title: title,
      titleZh: titleZh,
      orderNo: cursor.getLong(cursor.getColumnIndex('order_no')),
      matchedField: matchedField,
      matchedText: matchedText
    };
  }

  /**
   * 读取可空 TEXT 列：列为 NULL 时返回 undefined，否则返回字符串。
   * @param cursor 结果集（停在目标行）。
   * @param column 列名。
   * @returns 字符串或 undefined。
   */
  private static readOptionalText(cursor: relationalStore.ResultSet, column: string): string | undefined {
    // 列下标
    const index: number = cursor.getColumnIndex(column);
    // 显式判 NULL（relationalStore.isColumnNull 区分 NULL 与空串）
    if (cursor.isColumnNull(index)) {
      return undefined;
    }
    return cursor.getString(index);
  }

  /**
   * 读取可空 INTEGER 列：列为 NULL 时返回 undefined，否则返回数值。
   * @param cursor 结果集（停在目标行）。
   * @param column 列名。
   * @returns 数值或 undefined。
   */
  private static readOptionalLong(cursor: relationalStore.ResultSet, column: string): number | undefined {
    // 列下标
    const index: number = cursor.getColumnIndex(column);
    if (cursor.isColumnNull(index)) {
      return undefined;
    }
    return cursor.getLong(index);
  }

  /**
   * 读取可空 REAL 列：列为 NULL 时返回 undefined，否则返回浮点数。
   * @param cursor 结果集（停在目标行）。
   * @param column 列名。
   * @returns 浮点数或 undefined。
   */
  private static readOptionalDouble(cursor: relationalStore.ResultSet, column: string): number | undefined {
    // 列下标
    const index: number = cursor.getColumnIndex(column);
    if (cursor.isColumnNull(index)) {
      return undefined;
    }
    return cursor.getDouble(index);
  }

  /**
   * 解析 `authors_json`/`languages_json` 为字符串数组（非数组或解析失败回退空数组）。
   * @param json JSON 文本（应为字符串数组）。
   * @returns 仅含字符串元素的数组。
   */
  private static parseStringArray(json: string): string[] {
    try {
      // 解析后的候选值（可能不是数组）
      const parsed: Object = JSON.parse(json) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      // 仅保留字符串元素，过滤非法项
      return (parsed as Object[]).filter((item: Object): boolean => typeof item === 'string') as string[];
    } catch (cause) {
      // 脏 JSON 不应导致书架崩溃：回退空数组（结构性容错，不输出内容）
      return [];
    }
  }

  /**
   * 把 DB 中的 status 文本收敛为 `BookStatus` 联合类型（CHECK 已保证取值，但显式收敛以满足严格类型）。
   * @param raw status 列原始文本。
   * @returns 合法的 BookStatus。
   */
  private static toBookStatus(raw: string): BookStatus {
    if (raw === 'ready' || raw === 'updating' || raw === 'broken' || raw === 'deleted') {
      return raw;
    }
    // 理论不可达（DB CHECK 兜底）：保守回退 broken，避免静默落空
    return 'broken';
  }

  /**
   * 把 DB 中的 chapters.kind 文本收敛为 `ChapterKind` 联合类型（CHECK 已保证取值，显式收敛满足严格类型）。
   * @param raw kind 列原始文本。
   * @returns 合法的 ChapterKind（非法值保守回退 'lesson'）。
   */
  private static toChapterKind(raw: string): ChapterKind {
    if (raw === 'lesson' || raw === 'review' || raw === 'appendix' || raw === 'answer-key' || raw === 'index') {
      return raw;
    }
    // 理论不可达（DB CHECK 兜底）：回退 'lesson'，避免静默落空
    return 'lesson';
  }

  /**
   * 把 DB 中的 reading_progress.status 文本（可空）收敛为 `ChapterSummary.progressStatus` 联合类型。
   * @param raw status 列原始文本（无进度行时为 undefined）。
   * @returns 合法的 progressStatus（缺行/非法回退 'not-started'）。
   */
  private static toProgressStatus(raw: string | undefined): ChapterSummary['progressStatus'] {
    if (raw === 'not-started' || raw === 'learning' || raw === 'completed' || raw === 'review-due') {
      return raw;
    }
    // 无进度行或非法值：回退 'not-started'（LLD §6.4 缺省口径）
    return 'not-started';
  }

  /**
   * 把 DB 中的 chapters.review_status 文本收敛为 `ChapterSummary.reviewStatus` 联合类型。
   * @param raw review_status 列原始文本。
   * @returns 合法的 reviewStatus（非法回退 'unreviewed'）。
   */
  private static toReviewStatus(raw: string): ChapterSummary['reviewStatus'] {
    if (raw === 'unreviewed' || raw === 'needs-review' || raw === 'reviewed') {
      return raw;
    }
    // 理论不可达（DB CHECK 兜底）：回退 'unreviewed'
    return 'unreviewed';
  }

  /**
   * 保留 1 位小数四舍五入（§3.12.1：完成度 0..100，1 位小数）。
   * @param value 原始百分比。
   * @returns 1 位小数的百分比。
   */
  private static round1(value: number): number {
    // 乘 10 取整再除回，规避部分浮点表示误差
    return Math.round(value * 10) / 10;
  }
}
