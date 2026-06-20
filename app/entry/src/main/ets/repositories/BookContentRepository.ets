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
import { BaseRepository } from './BaseRepository';
import { AppErrors, DB_WRITE_FAILED } from '../utils/AppErrors';
import {
  BookIndexModel, BookRow, ChapterRow, SectionRow, ContentBlockRow, ExerciseRow,
  ExerciseBlankRow, AcceptedAnswerRow, GradingRuleRow, ReviewCardRow, ContentReviewFlagRow, AssetRow
} from '../services/import/ContentMapper';

/**
 * 提交前钩子：在落库事务内、提交之前执行（用于 §2.4 step12 暂存→正式目录原子提升）。
 * 抛出异常即触发事务回滚。
 */
export type PreCommitHook = () => Promise<void>;

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
}
