/**
 * 书籍内容落库仓储（P1-4，LLD §2.4 step11~step13 + §3.3~§3.25）。
 *
 * 职责：把 `ContentMapper` 产出的 `BookIndexModel` 在**单个事务**内按外键安全顺序写入全部内容表，
 * 并在同一事务内由 `SELECT COUNT(*) FROM chapters WHERE book_id=?` **重算** `books.chapter_count`
 * 写回（§3.3 R-047，不依赖一次性校验值）。事务支持「提交前钩子」`onIndexed`：调用方在此把暂存目录
 * 原子提升到正式目录（§2.4 step12），任一步失败 → 事务整体回滚（绝不残留半本书，§2.6）。
 *
 * 约束：页面/ViewModel 不碰 SQL，一律经本仓储（CLAUDE.md §5）；写入经 `runInTransaction`（LLD §8）。
 * 外键安全顺序：books → assets → chapters → sections → content_blocks → exercises → exercise_blanks
 * → accepted_answers → grading_rules → review_cards → content_review_flags。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore `executeSql`/`querySql`/`ResultSet`/事务 API 以 API 12 为准。
 */
import { relationalStore } from '@kit.ArkData';
import { Database } from '../database/Database';
import { BaseRepository, RowMapper } from './BaseRepository';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import {
  BookIndexModel, BookRow, ChapterRow, SectionRow, ContentBlockRow, ExerciseRow,
  ExerciseBlankRow, AcceptedAnswerRow, GradingRuleRow, ReviewCardRow, ContentReviewFlagRow, AssetRow
} from '../services/import/ContentMapper';
import {
  UpgradePlan, ExistingIndex, ExistingChapterAnchor, ExistingSectionAnchor, ExistingExerciseAnchor
} from '../services/import/UpgradePlan';

/**
 * 提交前钩子：在落库事务内、提交之前执行（用于 §2.4 step12 暂存→正式目录原子提升）。
 * 抛出异常即触发事务回滚。
 */
export type PreCommitHook = () => Promise<void>;

/** 现存书籍摘要（升级前按 package_id 查旧书，定位升级目标与冲突判定）。 */
export interface ExistingBookSummary {
  /** 旧书内部 id（升级原地锚点）。 */
  id: string;
  /** 内容版本（升级时变化）。 */
  contentVersion: string;
  /** 状态（ready/updating/broken/deleted）。 */
  status: string;
}

/** 升级期临时 order 偏移：把匹配/被删父行的 order 暂移出有效区，规避 UNIQUE(order_no) 重排冲突。 */
const UPGRADE_ORDER_OFFSET: number = 1000000;

/**
 * 书籍内容落库仓储。
 */
export class BookContentRepository extends BaseRepository {
  /**
   * @param database 已就绪的数据库封装。
   */
  constructor(database: Database) {
    super(database);
  }

  /**
   * 在单事务内落库整本书的内容索引，重算 `chapter_count`，并在提交前执行原子提升钩子。
   * @param model 待落库的书籍索引模型。
   * @param onIndexed 提交前钩子（原子提升），可选；抛错触发整体回滚。
   * @returns 重算后的章节数（= 实际落库章节行数）。
   * @throws AppError 写入失败或钩子失败时抛出（事务已回滚）。
   */
  async indexBook(model: BookIndexModel, onIndexed?: PreCommitHook): Promise<number> {
    return this.runInTransaction(async (store: relationalStore.RdbStore): Promise<number> => {
      // 1) books（先于所有 FK 子表）
      await BookContentRepository.insertBook(store, model.book);
      // 2) assets（先于 content_blocks 的 asset_id 引用）
      for (let i: number = 0; i < model.assets.length; i++) {
        await BookContentRepository.insertAsset(store, model.assets[i]);
      }
      // 3) chapters
      for (let i: number = 0; i < model.chapters.length; i++) {
        await BookContentRepository.insertChapter(store, model.chapters[i]);
      }
      // 4) sections
      for (let i: number = 0; i < model.sections.length; i++) {
        await BookContentRepository.insertSection(store, model.sections[i]);
      }
      // 5) content_blocks
      for (let i: number = 0; i < model.blocks.length; i++) {
        await BookContentRepository.insertBlock(store, model.blocks[i]);
      }
      // 6) exercises
      for (let i: number = 0; i < model.exercises.length; i++) {
        await BookContentRepository.insertExercise(store, model.exercises[i]);
      }
      // 7) exercise_blanks
      for (let i: number = 0; i < model.blanks.length; i++) {
        await BookContentRepository.insertBlank(store, model.blanks[i]);
      }
      // 8) accepted_answers
      for (let i: number = 0; i < model.acceptedAnswers.length; i++) {
        await BookContentRepository.insertAcceptedAnswer(store, model.acceptedAnswers[i]);
      }
      // 9) grading_rules
      for (let i: number = 0; i < model.gradingRules.length; i++) {
        await BookContentRepository.insertGradingRule(store, model.gradingRules[i]);
      }
      // 10) review_cards（导入 package 来源卡，§3.19.1；唯一冲突时按保留调度字段更新）
      for (let i: number = 0; i < model.reviewCards.length; i++) {
        await BookContentRepository.upsertReviewCard(store, model.reviewCards[i]);
      }
      // 11) content_review_flags
      for (let i: number = 0; i < model.reviewFlags.length; i++) {
        await BookContentRepository.insertReviewFlag(store, model.reviewFlags[i]);
      }

      // 事务内重算 chapter_count 并写回（§3.3 R-047）
      const chapterCount: number = await BookContentRepository.countChapters(store, model.book.id);
      await store.executeSql('UPDATE books SET chapter_count = ? WHERE id = ?', [chapterCount, model.book.id]);

      // 提交前原子提升（§2.4 step12）：失败抛错 → 整体回滚
      if (onIndexed !== undefined) {
        await onIndexed();
      }
      return chapterCount;
    });
  }

  /**
   * 事务内统计某书章节数（§3.3 chapter_count 重算来源）。
   * @param store 事务内数据库实例。
   * @param bookId 书籍 ID。
   * @returns 章节数。
   * @throws AppError 查询失败时抛出。
   */
  private static async countChapters(store: relationalStore.RdbStore, bookId: string): Promise<number> {
    // 统计结果集
    const resultSet: relationalStore.ResultSet =
      await store.querySql('SELECT COUNT(*) AS n FROM chapters WHERE book_id = ?', [bookId]);
    try {
      if (!resultSet.goToFirstRow()) {
        throw AppErrors.create(DB_WRITE_FAILED, { detail: 'chapter-count-query-empty' });
      }
      return resultSet.getLong(resultSet.getColumnIndex('n'));
    } finally {
      resultSet.close();
    }
  }

  /**
   * 插入 books 行。
   * @param store 事务内数据库实例。
   * @param row 书籍行。
   */
  private static async insertBook(store: relationalStore.RdbStore, row: BookRow): Promise<void> {
    // 参数（可空列缺省传 null）
    const args: relationalStore.ValueType[] = [
      row.id, row.packageId, row.contentVersion, row.formatVersion, row.title, row.subtitle,
      row.authorsJson, row.description, row.languagesJson,
      row.coverPath !== undefined ? row.coverPath : null,
      row.chapterCount,
      row.sourcePageCount !== undefined ? row.sourcePageCount : null,
      row.sourceIsScanned, row.status, row.importedAt, row.updatedAt
    ];
    await store.executeSql(
      'INSERT INTO books (id, package_id, content_version, format_version, title, subtitle, '
      + 'authors_json, description, languages_json, cover_path, chapter_count, source_page_count, '
      + 'source_is_scanned, status, imported_at, updated_at) '
      + 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 assets 行。
   * @param store 事务内数据库实例。
   * @param row 资源行。
   */
  private static async insertAsset(store: relationalStore.RdbStore, row: AssetRow): Promise<void> {
    // 参数（宽高可空）
    const args: relationalStore.ValueType[] = [
      row.id, row.bookId, row.relativePath, row.localPath, row.mediaType, row.sha256, row.sizeBytes,
      row.widthPx !== undefined ? row.widthPx : null,
      row.heightPx !== undefined ? row.heightPx : null,
      row.altText
    ];
    await store.executeSql(
      'INSERT INTO assets (id, book_id, relative_path, local_path, media_type, sha256, size_bytes, '
      + 'width_px, height_px, alt_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 chapters 行。
   * @param store 事务内数据库实例。
   * @param row 章节行。
   */
  private static async insertChapter(store: relationalStore.RdbStore, row: ChapterRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.id, row.bookId, row.externalId, row.orderNo, row.kind, row.title, row.titleZh,
      row.estimatedMinutes, row.sourcePagesJson, row.contentFile, row.contentHash, row.reviewStatus,
      row.createdAt, row.updatedAt
    ];
    await store.executeSql(
      'INSERT INTO chapters (id, book_id, external_id, order_no, kind, title, title_zh, '
      + 'estimated_minutes, source_pages_json, content_file, content_hash, review_status, '
      + 'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 sections 行。
   * @param store 事务内数据库实例。
   * @param row 小节行。
   */
  private static async insertSection(store: relationalStore.RdbStore, row: SectionRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.id, row.chapterId, row.externalId, row.orderNo, row.type, row.title,
      row.sourcePagesJson, row.confidence
    ];
    await store.executeSql(
      'INSERT INTO sections (id, chapter_id, external_id, order_no, type, title, '
      + 'source_pages_json, confidence) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 content_blocks 行。
   * @param store 事务内数据库实例。
   * @param row 内容块行。
   */
  private static async insertBlock(store: relationalStore.RdbStore, row: ContentBlockRow): Promise<void> {
    // 参数（external_id / asset_id 可空）
    const args: relationalStore.ValueType[] = [
      row.id, row.sectionId,
      row.externalId !== undefined ? row.externalId : null,
      row.orderNo, row.type, row.payloadJson, row.plainText,
      row.assetId !== undefined ? row.assetId : null,
      row.sourcePagesJson
    ];
    await store.executeSql(
      'INSERT INTO content_blocks (id, section_id, external_id, order_no, type, payload_json, '
      + 'plain_text, asset_id, source_pages_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 exercises 行。
   * @param store 事务内数据库实例。
   * @param row 练习行。
   */
  private static async insertExercise(store: relationalStore.RdbStore, row: ExerciseRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.id, row.chapterId, row.externalId, row.orderNo, row.type, row.instruction, row.promptJson,
      row.contextJson, row.feedbackJson, row.gradingOptionsJson, row.sourceRefJson, row.answerSource,
      row.confidence, row.enabled, row.allowEmpty
    ];
    await store.executeSql(
      'INSERT INTO exercises (id, chapter_id, external_id, order_no, type, instruction, prompt_json, '
      + 'context_json, feedback_json, grading_options_json, source_ref_json, answer_source, '
      + 'confidence, enabled, allow_empty) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 exercise_blanks 行。
   * @param store 事务内数据库实例。
   * @param row 空位行。
   */
  private static async insertBlank(store: relationalStore.RdbStore, row: ExerciseBlankRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.id, row.exerciseId, row.blankKey, row.orderNo, row.widthEm, row.lines,
      row.handwritingMode, row.displayAnswer, row.tokensJson
    ];
    await store.executeSql(
      'INSERT INTO exercise_blanks (id, exercise_id, blank_key, order_no, width_em, lines, '
      + 'handwriting_mode, display_answer, tokens_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 accepted_answers 行。
   * @param store 事务内数据库实例。
   * @param row 答案行。
   */
  private static async insertAcceptedAnswer(
    store: relationalStore.RdbStore, row: AcceptedAnswerRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.id, row.blankId, row.normalizedAnswer, row.displayAnswer, row.isPrimary, row.sortOrder
    ];
    await store.executeSql(
      'INSERT INTO accepted_answers (id, blank_id, normalized_answer, display_answer, is_primary, '
      + 'sort_order) VALUES (?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入 grading_rules 行。
   * @param store 事务内数据库实例。
   * @param row 规则行。
   */
  private static async insertGradingRule(store: relationalStore.RdbStore, row: GradingRuleRow): Promise<void> {
    // 参数（blank_id 可空）
    const args: relationalStore.ValueType[] = [
      row.id, row.exerciseId,
      row.blankId !== undefined ? row.blankId : null,
      row.priority, row.ruleType, row.paramsJson, row.result, row.feedbackCode, row.feedbackZh
    ];
    await store.executeSql(
      'INSERT INTO grading_rules (id, exercise_id, blank_id, priority, rule_type, params_json, '
      + 'result, feedback_code, feedback_zh) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  /**
   * 插入/更新 review_cards 行（§3.19.1：UNIQUE(source_type, source_id) 冲突时保留调度字段、只更新内容）。
   * suspended 卡保持暂停；其余状态保留 state/ease/interval/due/lapses，仅更新 front/back 与 updated_at。
   * @param store 事务内数据库实例。
   * @param row 复习卡行。
   */
  private static async upsertReviewCard(store: relationalStore.RdbStore, row: ReviewCardRow): Promise<void> {
    // 参数（首次插入用全量；冲突分支只更新内容字段）
    const args: relationalStore.ValueType[] = [
      row.id, row.bookId, row.chapterId, row.sourceType, row.sourceId, row.frontJson, row.backJson,
      row.state, row.easeFactor, row.intervalDays, row.dueAt, row.lapses, row.createdAt, row.updatedAt,
      row.frontJson, row.backJson, row.updatedAt
    ];
    await store.executeSql(
      'INSERT INTO review_cards (id, book_id, chapter_id, source_type, source_id, front_json, back_json, '
      + 'state, ease_factor, interval_days, due_at, lapses, created_at, updated_at) '
      + 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      + 'ON CONFLICT(source_type, source_id) DO UPDATE SET '
      + 'front_json = ?, back_json = ?, updated_at = ?', args);
  }

  /**
   * 插入 content_review_flags 行。
   * @param store 事务内数据库实例。
   * @param row 复核标记行。
   */
  private static async insertReviewFlag(
    store: relationalStore.RdbStore, row: ContentReviewFlagRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.id, row.bookId, row.chapterExternalId, row.jsonPath, row.severity, row.type,
      row.message, row.createdAt
    ];
    await store.executeSql(
      'INSERT INTO content_review_flags (id, book_id, chapter_external_id, json_path, severity, type, '
      + 'message, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', args);
  }

  // ===========================================================================
  // 升级（upgrade）路径（P1-5，LLD §2.7 + 《06》§10）：按 external_id 原地 UPDATE，
  // 内部主键保持稳定，attempts/wrong_items/review_cards 等冗余/外键列自然保持一致。
  // ===========================================================================

  /**
   * 按 `package_id` 查现存书籍摘要（升级目标定位；同 package_id 至多一行有效内容版本，§10）。
   * 排除软删除书（`status='deleted'`）：对已删书按新导入处理，不原地升级。
   * @param packageId manifest.packageId。
   * @returns 现存书籍摘要或 undefined（无则为新导入）。
   */
  findBookByPackageId(packageId: string): Promise<ExistingBookSummary | undefined> {
    // 行 → 摘要映射
    const mapper: RowMapper<ExistingBookSummary> =
      (cursor: relationalStore.ResultSet): ExistingBookSummary => ({
        id: cursor.getString(cursor.getColumnIndex('id')),
        contentVersion: cursor.getString(cursor.getColumnIndex('content_version')),
        status: cursor.getString(cursor.getColumnIndex('status'))
      });
    return this.querySingle(
      "SELECT id, content_version, status FROM books WHERE package_id = ? AND status != 'deleted' "
      + 'ORDER BY imported_at DESC LIMIT 1',
      mapper, [packageId]);
  }

  /**
   * 设置书籍状态（升级期 `updating`，成功/失败回到 `ready`，§2.7）。单语句、独立事务。
   * @param bookId 书籍 id。
   * @param status 目标状态（ready/updating/broken/deleted）。
   * @param updatedAt 更新时间戳（epoch ms）。
   * @returns 完成更新的 Promise。
   */
  async setBookStatus(bookId: string, status: string, updatedAt: number): Promise<void> {
    await this.runInTransaction(async (store: relationalStore.RdbStore): Promise<void> => {
      await store.executeSql(
        'UPDATE books SET status = ?, updated_at = ? WHERE id = ?', [status, updatedAt, bookId]);
    });
  }

  /**
   * 读取旧书索引锚点（chapters/sections/exercises 的 external_id → 旧内部 id），供 `planUpgrade` 重映射。
   * @param bookId 旧书内部 id。
   * @returns 旧索引锚点集合。
   * @throws AppError 查询失败时抛出。
   */
  async readExistingIndex(bookId: string): Promise<ExistingIndex> {
    // 旧章节锚点
    const chapters: ExistingChapterAnchor[] = await this.queryList(
      'SELECT external_id, id FROM chapters WHERE book_id = ?',
      (c: relationalStore.ResultSet): ExistingChapterAnchor => ({
        externalId: c.getString(c.getColumnIndex('external_id')),
        id: c.getString(c.getColumnIndex('id'))
      }), [bookId]);
    // 旧小节锚点（经 chapters 关联限定本书）
    const sections: ExistingSectionAnchor[] = await this.queryList(
      'SELECT s.chapter_id AS chapter_id, s.external_id AS external_id, s.id AS id '
      + 'FROM sections s JOIN chapters c ON s.chapter_id = c.id WHERE c.book_id = ?',
      (c: relationalStore.ResultSet): ExistingSectionAnchor => ({
        chapterId: c.getString(c.getColumnIndex('chapter_id')),
        externalId: c.getString(c.getColumnIndex('external_id')),
        id: c.getString(c.getColumnIndex('id'))
      }), [bookId]);
    // 旧练习锚点
    const exercises: ExistingExerciseAnchor[] = await this.queryList(
      'SELECT e.chapter_id AS chapter_id, e.external_id AS external_id, e.id AS id '
      + 'FROM exercises e JOIN chapters c ON e.chapter_id = c.id WHERE c.book_id = ?',
      (c: relationalStore.ResultSet): ExistingExerciseAnchor => ({
        chapterId: c.getString(c.getColumnIndex('chapter_id')),
        externalId: c.getString(c.getColumnIndex('external_id')),
        id: c.getString(c.getColumnIndex('id'))
      }), [bookId]);
    return { chapters: chapters, sections: sections, exercises: exercises };
  }

  /**
   * 在单事务内按升级计划原地落库（§2.7 step2 + 《06》§10），并在提交前执行原子提升钩子。
   *
   * 落库顺序（FK 安全 + UNIQUE(order_no) 重排安全）：
   *   1) UPDATE books（保留 imported_at，更新内容版本/标题等，chapter_count 末尾重算）。
   *   2) assets 整体替换（DELETE by book_id → INSERT；先于内容块以满足 asset_id 外键）。
   *   3) 删除被删小节（级联其内容块/section_progress，§10 允许）。
   *   4) chapters：先把「匹配 + 被删」章节 order 暂移出有效区（规避重排时 UNIQUE 冲突），再 INSERT 新增、UPDATE 匹配；被删章节保留行（attempts FK 历史）。
   *   5) sections：同法 vacate→insert→update。
   *   6) content_blocks：清空受影响小节旧块后整体插入新块。
   *   7) exercises：vacate「匹配 + 被删」order→insert 新增→update 匹配→被删练习 enabled=0（保留 attempts/wrong_items）。
   *   8) exercise_blanks/accepted_answers/grading_rules：清空受影响练习旧子行后整体插入。
   *   9) review_cards upsert（按 source_id 保留调度字段）；content_review_flags 按 book_id 整体替换。
   *   10) 重算 chapter_count，执行提升钩子（失败整体回滚）。
   *
   * @param plan 升级执行计划（`planUpgrade` 产出，父引用列已翻译为有效内部 id）。
   * @param onPromoted 提交前钩子（暂存→正式原子提升）；抛错触发整体回滚。
   * @returns 重算后的章节数（含被删保留章节，§3.3 与 §10 的口径张力见 ADR）。
   * @throws AppError 写入失败或钩子失败时抛出（事务已回滚）。
   */
  async upgradeBook(plan: UpgradePlan, onPromoted?: PreCommitHook): Promise<number> {
    return this.runInTransaction(async (store: relationalStore.RdbStore): Promise<number> => {
      // 1) books（原地 UPDATE，保留 imported_at）
      await BookContentRepository.updateBook(store, plan.book);

      // 2) assets 整体替换（先删后插，先于内容块）
      await BookContentRepository.deleteByColumn(store, 'assets', 'book_id', [plan.book.id]);
      for (let i: number = 0; i < plan.assets.length; i++) {
        await BookContentRepository.insertAsset(store, plan.assets[i]);
      }

      // 3) 删除被删小节（级联块/section_progress）
      await BookContentRepository.deleteByColumn(store, 'sections', 'id', plan.removedSectionIds);

      // 4) chapters：vacate（匹配 + 被删）→ insert 新增 → update 匹配
      const chapterVacate: string[] = BookContentRepository.collectIds(plan.chaptersUpdate).concat(plan.removedChapterIds);
      await BookContentRepository.vacateOrder(store, 'chapters', chapterVacate);
      for (let i: number = 0; i < plan.chaptersInsert.length; i++) {
        await BookContentRepository.insertChapter(store, plan.chaptersInsert[i]);
      }
      for (let i: number = 0; i < plan.chaptersUpdate.length; i++) {
        await BookContentRepository.updateChapter(store, plan.chaptersUpdate[i]);
      }

      // 5) sections：vacate 匹配 → insert 新增 → update 匹配
      await BookContentRepository.vacateOrder(store, 'sections', BookContentRepository.collectIds(plan.sectionsUpdate));
      for (let i: number = 0; i < plan.sectionsInsert.length; i++) {
        await BookContentRepository.insertSection(store, plan.sectionsInsert[i]);
      }
      for (let i: number = 0; i < plan.sectionsUpdate.length; i++) {
        await BookContentRepository.updateSection(store, plan.sectionsUpdate[i]);
      }

      // 6) content_blocks：清空受影响小节旧块 → 整体插入新块
      await BookContentRepository.deleteByColumn(store, 'content_blocks', 'section_id', plan.affectedSectionIds);
      for (let i: number = 0; i < plan.blocks.length; i++) {
        await BookContentRepository.insertBlock(store, plan.blocks[i]);
      }

      // 7) exercises：vacate（匹配 + 被删）→ insert 新增 → update 匹配 → 被删 enabled=0
      const exerciseVacate: string[] = BookContentRepository.collectIds(plan.exercisesUpdate).concat(plan.removedExerciseIds);
      await BookContentRepository.vacateOrder(store, 'exercises', exerciseVacate);
      for (let i: number = 0; i < plan.exercisesInsert.length; i++) {
        await BookContentRepository.insertExercise(store, plan.exercisesInsert[i]);
      }
      for (let i: number = 0; i < plan.exercisesUpdate.length; i++) {
        await BookContentRepository.updateExercise(store, plan.exercisesUpdate[i]);
      }
      await BookContentRepository.disableExercises(store, plan.removedExerciseIds);

      // 8) 练习子行（blanks/answers/rules）：清空受影响练习旧子行 → 整体插入
      await BookContentRepository.deleteByColumn(store, 'grading_rules', 'exercise_id', plan.affectedExerciseIds);
      // 删除空位即级联 accepted_answers（FK ON DELETE CASCADE）
      await BookContentRepository.deleteByColumn(store, 'exercise_blanks', 'exercise_id', plan.affectedExerciseIds);
      for (let i: number = 0; i < plan.blanks.length; i++) {
        await BookContentRepository.insertBlank(store, plan.blanks[i]);
      }
      for (let i: number = 0; i < plan.acceptedAnswers.length; i++) {
        await BookContentRepository.insertAcceptedAnswer(store, plan.acceptedAnswers[i]);
      }
      for (let i: number = 0; i < plan.gradingRules.length; i++) {
        await BookContentRepository.insertGradingRule(store, plan.gradingRules[i]);
      }

      // 9) review_cards upsert（保留调度字段）；content_review_flags 整体替换
      for (let i: number = 0; i < plan.reviewCards.length; i++) {
        await BookContentRepository.upsertReviewCard(store, plan.reviewCards[i]);
      }
      await BookContentRepository.deleteByColumn(store, 'content_review_flags', 'book_id', [plan.book.id]);
      for (let i: number = 0; i < plan.reviewFlags.length; i++) {
        await BookContentRepository.insertReviewFlag(store, plan.reviewFlags[i]);
      }

      // 10) 重算 chapter_count，提交前原子提升（失败整体回滚）
      const chapterCount: number = await BookContentRepository.countChapters(store, plan.book.id);
      await store.executeSql('UPDATE books SET chapter_count = ? WHERE id = ?', [chapterCount, plan.book.id]);
      if (onPromoted !== undefined) {
        await onPromoted();
      }
      return chapterCount;
    });
  }

  /**
   * 收集行数组的 id 列（泛型约束 `id: string` 字段，兼容 Chapter/Section/Exercise 行类型）。
   * @param rows 含 id 字段的行数组。
   * @returns id 数组。
   */
  private static collectIds<T extends BookContentRow>(rows: T[]): string[] {
    // 结果 id 列
    const ids: string[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      ids.push(rows[i].id);
    }
    return ids;
  }

  /**
   * 把若干行的 `order_no` 暂移出有效区（`UPGRADE_ORDER_OFFSET + 序号`），规避重排时 UNIQUE(order_no) 瞬时冲突。
   * @param store 事务内数据库实例。
   * @param table 表名（chapters/sections/exercises）。
   * @param ids 待 vacate 的内部 id 数组（可空）。
   * @returns 完成的 Promise。
   */
  private static async vacateOrder(store: relationalStore.RdbStore, table: string, ids: string[]): Promise<void> {
    for (let i: number = 0; i < ids.length; i++) {
      await store.executeSql(
        `UPDATE ${table} SET order_no = ? WHERE id = ?`, [UPGRADE_ORDER_OFFSET + i, ids[i]]);
    }
  }

  /**
   * 把被删练习置 `enabled=0`（保留行与 attempts/wrong_items，《06》§10）。其 order 已由 vacate 移出有效区。
   * @param store 事务内数据库实例。
   * @param ids 被删练习内部 id 数组（可空）。
   * @returns 完成的 Promise。
   */
  private static async disableExercises(store: relationalStore.RdbStore, ids: string[]): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    // IN 占位符
    const placeholders: string = ids.map((): string => '?').join(', ');
    const args: relationalStore.ValueType[] = ids.slice();
    await store.executeSql(`UPDATE exercises SET enabled = 0 WHERE id IN (${placeholders})`, args);
  }

  /**
   * 按某列值集合删除行（升级期的整体替换/级联清理）。
   * @param store 事务内数据库实例。
   * @param table 表名。
   * @param column 过滤列名。
   * @param values 列值集合（空则不执行）。
   * @returns 完成的 Promise。
   */
  private static async deleteByColumn(
    store: relationalStore.RdbStore, table: string, column: string, values: string[]): Promise<void> {
    if (values.length === 0) {
      return;
    }
    // IN 占位符
    const placeholders: string = values.map((): string => '?').join(', ');
    const args: relationalStore.ValueType[] = values.slice();
    await store.executeSql(`DELETE FROM ${table} WHERE ${column} IN (${placeholders})`, args);
  }

  /**
   * 原地 UPDATE books（保留 imported_at/last_opened_at/deleted_at；chapter_count 末尾重算）。
   * @param store 事务内数据库实例。
   * @param row 书籍行（升级后内容）。
   * @returns 完成的 Promise。
   */
  private static async updateBook(store: relationalStore.RdbStore, row: BookRow): Promise<void> {
    // 参数（可空列缺省传 null）
    const args: relationalStore.ValueType[] = [
      row.packageId, row.contentVersion, row.formatVersion, row.title, row.subtitle,
      row.authorsJson, row.description, row.languagesJson,
      row.coverPath !== undefined ? row.coverPath : null,
      row.sourcePageCount !== undefined ? row.sourcePageCount : null,
      row.sourceIsScanned, row.status, row.updatedAt, row.id
    ];
    await store.executeSql(
      'UPDATE books SET package_id = ?, content_version = ?, format_version = ?, title = ?, subtitle = ?, '
      + 'authors_json = ?, description = ?, languages_json = ?, cover_path = ?, source_page_count = ?, '
      + 'source_is_scanned = ?, status = ?, updated_at = ? WHERE id = ?', args);
  }

  /**
   * 原地 UPDATE chapters（保留 created_at/book_id；external_id 为匹配键，值不变）。
   * @param store 事务内数据库实例。
   * @param row 章节行。
   * @returns 完成的 Promise。
   */
  private static async updateChapter(store: relationalStore.RdbStore, row: ChapterRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.orderNo, row.kind, row.title, row.titleZh, row.estimatedMinutes, row.sourcePagesJson,
      row.contentFile, row.contentHash, row.reviewStatus, row.updatedAt, row.id
    ];
    await store.executeSql(
      'UPDATE chapters SET order_no = ?, kind = ?, title = ?, title_zh = ?, estimated_minutes = ?, '
      + 'source_pages_json = ?, content_file = ?, content_hash = ?, review_status = ?, updated_at = ? '
      + 'WHERE id = ?', args);
  }

  /**
   * 原地 UPDATE sections（chapter_id/external_id 为匹配锚点，值不变）。
   * @param store 事务内数据库实例。
   * @param row 小节行。
   * @returns 完成的 Promise。
   */
  private static async updateSection(store: relationalStore.RdbStore, row: SectionRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.orderNo, row.type, row.title, row.sourcePagesJson, row.confidence, row.id
    ];
    await store.executeSql(
      'UPDATE sections SET order_no = ?, type = ?, title = ?, source_pages_json = ?, confidence = ? '
      + 'WHERE id = ?', args);
  }

  /**
   * 原地 UPDATE exercises（chapter_id/external_id 为匹配锚点，值不变；enabled 取新模型）。
   * @param store 事务内数据库实例。
   * @param row 练习行。
   * @returns 完成的 Promise。
   */
  private static async updateExercise(store: relationalStore.RdbStore, row: ExerciseRow): Promise<void> {
    // 参数
    const args: relationalStore.ValueType[] = [
      row.orderNo, row.type, row.instruction, row.promptJson, row.contextJson, row.feedbackJson,
      row.gradingOptionsJson, row.sourceRefJson, row.answerSource, row.confidence, row.enabled,
      row.allowEmpty, row.id
    ];
    await store.executeSql(
      'UPDATE exercises SET order_no = ?, type = ?, instruction = ?, prompt_json = ?, context_json = ?, '
      + 'feedback_json = ?, grading_options_json = ?, source_ref_json = ?, answer_source = ?, '
      + 'confidence = ?, enabled = ?, allow_empty = ? WHERE id = ?', args);
  }
}

/** 仅含 id 字段的最小行接口（供 `collectIds` 在不同行类型上复用）。 */
interface BookContentRow {
  /** 内部主键。 */
  id: string;
}
