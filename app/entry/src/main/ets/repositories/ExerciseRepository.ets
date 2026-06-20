/**
 * 练习仓储（F06，LLD §6.6 + §3.8~§3.10/§3.14；契约见《04-接口与DTO契约》§6 `ExerciseRepository`）。
 *
 * 职责：把 `exercises` / `exercise_blanks` / `accepted_answers` 各表行组装为 Presentation 层使用的
 * `ExerciseDetail`（题面 + 判分选项 + 空位列表，每空带可接受答案聚合），并提供作答草稿创建与判分结果落库。
 * 读取统一经 `BaseRepository.queryList/querySingle`（页面/ViewModel 不碰 SQL，CLAUDE.md §5）。
 *
 * 组装口径（与 ContentMapper 落库口径对偶）：
 * - `blanks` 按 `exercise_blanks.order_no` 升序，多空题逐空独立画布/焦点的顺序据此确定（§6.6 R-018）。
 * - `acceptedAnswers` 由 `accepted_answers` 按 `sort_order` 升序聚合（主答案优先入库口径见《06》答案去重 R-040）。
 * - `gradingOptions` 从 `exercises.grading_options_json` 解析；缺字段以契约 §6 的合理缺省补齐（解析失败整体兜底）。
 * - `prompt`/`context` 由 `prompt_json`/`context_json` 安全解析为 `JsonObject`（损坏降级空对象，不阻断作答）。
 * - `type` 原样带出（含四种非手写题型）：F06 手写主流程针对五种 `*-handwriting`；非手写四种保留占位，
 *   作答交互列入后续迭代（R-063，不砍除/不静默丢弃，CLAUDE.md §2-11）。
 *
 * 写入（事务/可回滚，CLAUDE.md §5 / LLD §8）：
 * - `createDraft`：进入练习书写即创建 `grade='draft'`、`recognition_status='not-requested'` 的 attempt 行作为
 *   快照锚（§4.1 / R-021），返回空答案的 `ExerciseAttemptDraft`。
 * - `saveGrade`：把 `GradeResult` 落 `exercise_attempts`（聚合整题 grade/score/feedback + 逐空 `blank_results_json`）。
 *   **本仓储仅落库，不做判分逻辑**——判分是 F07 `GradingEngine`/`GradingService` 的职责（04 §12 规则1）。
 *   原始笔迹由 `handwriting_records` 独立保留、识别文本与判分结果分存（CLAUDE.md §2.9 / §3.15），本仓储不触碰笔迹文件。
 *
 * 未编译验证（缺 HarmonyOS SDK）：relationalStore `querySql`/`ResultSet`/`executeSql` API 以 API 12 为准；
 * SQL 组装 / gradingOptions 解析 / blanks 聚合口径已用 Node 端口 + 真实 SQLite 在 `.ralph/f06-test/` 回归。
 */
import { relationalStore } from '@kit.ArkData';
import { Database } from '../database/Database';
import { BaseRepository, RowMapper } from './BaseRepository';
import { AppErrors, DB_QUERY_FAILED, DB_WRITE_FAILED } from '../utils/AppErrors';
import { Id, EpochMs, JsonObject } from '../domain/entities/common';
import { HandwritingMode } from '../domain/entities/handwriting';
import {
  ExerciseRepository, ExerciseDetail, ExerciseBlank, ExerciseType, ExerciseAttemptDraft,
  GradeResult, GradingOptions, BlankGradeResult
} from '../domain/entities/exercise';
import { IdFactory } from '../services/import/ContentMapper';

/** 题型受控集合（§3.8 CHECK / 04 §6，九种；用于把 DB 字符串安全收敛到联合类型）。 */
const EXERCISE_TYPES: ExerciseType[] = [
  'fill-blank-handwriting', 'multi-blank-handwriting', 'rewrite-sentence-handwriting',
  'short-answer-handwriting', 'choice', 'true-false', 'match', 'order-words', 'correction-handwriting'
];

/** 手写识别模式受控集合（§3.9 CHECK / 04 §5）。 */
const HANDWRITING_MODES: HandwritingMode[] = ['english', 'number', 'mixed'];

/**
 * 判分选项缺省值（契约 §6；`grading_options_json` 缺字段或整体损坏时回退）。
 * 取值依据《06》答案规范化默认口径：忽略首尾/折叠空白、忽略句末标点、归一撇号，编辑距离仅产生提示不改判（§4.2/LLD §3.14）。
 */
const DEFAULT_GRADING_OPTIONS: GradingOptions = {
  caseSensitive: false,
  trimWhitespace: true,
  collapseWhitespace: true,
  ignoreTerminalPunctuation: true,
  normalizeApostrophes: true,
  maxEditDistance: 0
};

/**
 * 练习仓储实现。
 */
export class ExerciseRepositoryImpl extends BaseRepository implements ExerciseRepository {
  /** 主键生成器（attempt 行 ID；构造注入，与导入落库一致，不在仓储内触 SDK）。 */
  private readonly idFactory: IdFactory;
  /** 时间源（epoch ms；构造注入便于确定性测试，缺省取系统时钟）。 */
  private readonly now: () => EpochMs;

  /**
   * @param database 已就绪的数据库封装。
   * @param idFactory 主键生成器（attempt 行 ID）。
   * @param now 时间源（缺省 `() => Date.now()`）。
   */
  constructor(database: Database, idFactory: IdFactory, now?: () => EpochMs) {
    super(database);
    this.idFactory = idFactory;
    this.now = now !== undefined ? now : (): EpochMs => Date.now();
  }

  /**
   * 取练习详情（题面 + 判分选项 + 空位列表，每空带可接受答案聚合）。
   * @param exerciseId 练习内部主键。
   * @returns 练习详情。
   * @throws AppError 练习不存在或查询失败时抛出（DB_QUERY_FAILED）。
   */
  async getExercise(exerciseId: Id): Promise<ExerciseDetail> {
    // 练习主行（不存在视为查询失败，由上层映射为「题目损坏」态）
    const detail: ExerciseDetail | undefined = await this.queryExerciseRow(exerciseId);
    if (detail === undefined) {
      throw AppErrors.create(DB_QUERY_FAILED, { detail: `exercise-not-found:${exerciseId}` });
    }
    // 空位列表（按 order_no 升序；每空聚合 acceptedAnswers）
    detail.blanks = await this.queryBlanks(exerciseId);
    return detail;
  }

  /**
   * 创建作答草稿：落 `grade='draft'`、`recognition_status='not-requested'` 的 attempt 行作为快照锚（§4.1 / R-021）。
   * @param exerciseId 练习内部主键。
   * @returns 作答草稿（空答案，answers 由识别成功后逐空补齐——F07）。
   * @throws AppError 练习不存在或写入失败时抛出（DB_WRITE_FAILED）。
   */
  async createDraft(exerciseId: Id): Promise<ExerciseAttemptDraft> {
    // 取练习归属（attempt 需要 book_id/chapter_id，NOT NULL 外键）
    const owner: ExerciseOwner | undefined = await this.queryExerciseOwner(exerciseId);
    if (owner === undefined) {
      throw AppErrors.create(DB_WRITE_FAILED, { detail: `exercise-not-found:${exerciseId}` });
    }
    // 草稿标识与开始时间
    const attemptId: Id = this.idFactory.newId();
    const startedAt: EpochMs = this.now();
    try {
      // 单语句插入起始行（draft/not-requested 由列默认值与显式入参共同保证，可重启恢复，§4.1）
      await this.store.executeSql(
        'INSERT INTO exercise_attempts '
        + '(id, exercise_id, book_id, chapter_id, started_at, recognition_status, grade) '
        + "VALUES (?, ?, ?, ?, ?, 'not-requested', 'draft')",
        [attemptId, exerciseId, owner.bookId, owner.chapterId, startedAt]);
    } catch (cause) {
      throw AppErrors.from(cause, DB_WRITE_FAILED);
    }
    return { attemptId, exerciseId, startedAt, answers: [] };
  }

  /**
   * 保存判分结果（仅落库，不做判分逻辑——判分属 F07 GradingEngine）。
   *
   * 落库口径（§3.14 / R-055）：`blank_results_json` 为逐空权威存储；整题 `grade`/`score`/`feedback_code`
   * 是聚合后的整题值；`recognition_status='succeeded'`、`submitted_at` 置提交时间。原始笔迹与识别文本由
   * `handwriting_records`/`recognized_text_json` 分存，本方法不覆盖笔迹（CLAUDE.md §2.9 / §3.15）。
   *
   * @param attemptId 作答内部主键（createDraft 产出的快照锚）。
   * @param result 判分结果（由 F07 GradingService 产出）。
   * @throws AppError 写入失败时抛出（DB_WRITE_FAILED）。
   */
  async saveGrade(attemptId: Id, result: GradeResult): Promise<void> {
    // 逐空结果序列化（权威存储，R-055）
    const blankResultsJson: string = JSON.stringify(result.perBlank);
    // 整题反馈码：取首个非空逐空反馈码作为整题聚合码（无逐空时为空串，落 NULL 由列允许）
    const feedbackCode: string = ExerciseRepositoryImpl.aggregateFeedbackCode(result.perBlank);
    try {
      // 整题聚合落库：grade/score/feedback + 逐空 JSON + 识别成功态 + 提交时间
      await this.store.executeSql(
        'UPDATE exercise_attempts SET '
        + 'submitted_at = ?, grade = ?, score = ?, feedback_code = ?, '
        + "recognition_status = 'succeeded', blank_results_json = ? "
        + 'WHERE id = ?',
        [result.submittedAt, result.overall, result.score, feedbackCode, blankResultsJson, attemptId]);
    } catch (cause) {
      throw AppErrors.from(cause, DB_WRITE_FAILED);
    }
  }

  /**
   * 查询练习主行并组装为 `ExerciseDetail`（blanks 暂为空，由 getExercise 后续填充）。
   * @param exerciseId 练习内部主键。
   * @returns 练习详情（blanks=[]）或 undefined。
   * @throws AppError 查询失败时抛出。
   */
  private async queryExerciseRow(exerciseId: Id): Promise<ExerciseDetail | undefined> {
    // 练习行 → ExerciseDetail 映射器（联表取 book_id：exercises 仅含 chapter_id，book_id 经 chapters 带出）
    const mapper: RowMapper<ExerciseDetail> = (c: relationalStore.ResultSet): ExerciseDetail => ({
      id: c.getString(c.getColumnIndex('id')),
      externalId: c.getString(c.getColumnIndex('external_id')),
      bookId: c.getString(c.getColumnIndex('book_id')),
      chapterId: c.getString(c.getColumnIndex('chapter_id')),
      orderNo: c.getLong(c.getColumnIndex('order_no')),
      type: ExerciseRepositoryImpl.toExerciseType(c.getString(c.getColumnIndex('type'))),
      instruction: c.getString(c.getColumnIndex('instruction')),
      prompt: ExerciseRepositoryImpl.parseJsonObject(c.getString(c.getColumnIndex('prompt_json'))),
      context: ExerciseRepositoryImpl.parseJsonObject(c.getString(c.getColumnIndex('context_json'))),
      blanks: [],
      gradingOptions:
        ExerciseRepositoryImpl.parseGradingOptions(c.getString(c.getColumnIndex('grading_options_json')))
    });
    return this.querySingle(
      'SELECT e.id AS id, e.external_id AS external_id, c.book_id AS book_id, '
      + 'e.chapter_id AS chapter_id, e.order_no AS order_no, e.type AS type, '
      + 'e.instruction AS instruction, e.prompt_json AS prompt_json, e.context_json AS context_json, '
      + 'e.grading_options_json AS grading_options_json '
      + 'FROM exercises e JOIN chapters c ON e.chapter_id = c.id WHERE e.id = ?',
      mapper, [exerciseId]);
  }

  /**
   * 查询练习归属（book_id/chapter_id，供 createDraft 写 attempt 的 NOT NULL 外键）。
   * @param exerciseId 练习内部主键。
   * @returns 归属或 undefined。
   * @throws AppError 查询失败时抛出。
   */
  private async queryExerciseOwner(exerciseId: Id): Promise<ExerciseOwner | undefined> {
    return this.querySingle(
      'SELECT c.book_id AS book_id, e.chapter_id AS chapter_id '
      + 'FROM exercises e JOIN chapters c ON e.chapter_id = c.id WHERE e.id = ?',
      (c: relationalStore.ResultSet): ExerciseOwner => ({
        bookId: c.getString(c.getColumnIndex('book_id')),
        chapterId: c.getString(c.getColumnIndex('chapter_id'))
      }),
      [exerciseId]);
  }

  /**
   * 查询练习全部空位（按 order_no 升序），每空聚合可接受答案。
   * @param exerciseId 练习内部主键。
   * @returns 空位数组。
   * @throws AppError 查询失败时抛出。
   */
  private async queryBlanks(exerciseId: Id): Promise<ExerciseBlank[]> {
    // 空位行 → ExerciseBlank 映射器（acceptedAnswers 待逐空填充）
    const blanks: ExerciseBlank[] = await this.queryList(
      'SELECT id, blank_key, order_no, width_em, lines, handwriting_mode, display_answer '
      + 'FROM exercise_blanks WHERE exercise_id = ? ORDER BY order_no ASC',
      (c: relationalStore.ResultSet): ExerciseBlank => ({
        id: c.getString(c.getColumnIndex('id')),
        blankKey: c.getString(c.getColumnIndex('blank_key')),
        orderNo: c.getLong(c.getColumnIndex('order_no')),
        widthEm: c.getDouble(c.getColumnIndex('width_em')),
        lines: c.getLong(c.getColumnIndex('lines')),
        handwritingMode:
          ExerciseRepositoryImpl.toHandwritingMode(c.getString(c.getColumnIndex('handwriting_mode'))),
        displayAnswer: c.getString(c.getColumnIndex('display_answer')),
        acceptedAnswers: []
      }),
      [exerciseId]);
    // 逐空聚合可接受答案（空位数有限，按空单查保证归属与 sort_order 顺序清晰）
    for (let i: number = 0; i < blanks.length; i++) {
      blanks[i].acceptedAnswers = await this.queryAcceptedAnswers(blanks[i].id);
    }
    return blanks;
  }

  /**
   * 查询某空位的可接受答案集合（按 sort_order 升序，去重已在导入落库时完成 R-040）。
   * @param blankId 空位内部主键。
   * @returns 展示答案数组（display_answer，去重去序）。
   * @throws AppError 查询失败时抛出。
   */
  private async queryAcceptedAnswers(blankId: Id): Promise<string[]> {
    return this.queryList(
      'SELECT display_answer FROM accepted_answers WHERE blank_id = ? ORDER BY sort_order ASC, id ASC',
      (c: relationalStore.ResultSet): string => c.getString(c.getColumnIndex('display_answer')),
      [blankId]);
  }

  /**
   * 取整题聚合反馈码：取首个非空逐空反馈码（无逐空结果时为空串）。
   * @param perBlank 逐空判分结果。
   * @returns 整题反馈码字符串。
   */
  private static aggregateFeedbackCode(perBlank: BlankGradeResult[]): string {
    for (let i: number = 0; i < perBlank.length; i++) {
      if (perBlank[i].feedbackCode.length > 0) {
        return perBlank[i].feedbackCode;
      }
    }
    return '';
  }

  /**
   * 把 DB 读出的 type 字符串安全收敛到九种题型联合类型；非法值回退 'fill-blank-handwriting'。
   * @param value DB 列值。
   * @returns 合法 ExerciseType。
   */
  private static toExerciseType(value: string): ExerciseType {
    return EXERCISE_TYPES.indexOf(value as ExerciseType) >= 0
      ? (value as ExerciseType) : 'fill-blank-handwriting';
  }

  /**
   * 把 DB 读出的 handwriting_mode 字符串安全收敛到联合类型；非法值回退 'english'。
   * @param value DB 列值。
   * @returns 合法 HandwritingMode。
   */
  private static toHandwritingMode(value: string): HandwritingMode {
    return HANDWRITING_MODES.indexOf(value as HandwritingMode) >= 0
      ? (value as HandwritingMode) : 'english';
  }

  /**
   * 安全解析 JSON 对象串（prompt_json / context_json）；解析失败或非对象时回退空对象（优雅降级，不阻断作答）。
   * @param raw JSON 串。
   * @returns JsonObject。
   */
  private static parseJsonObject(raw: string): JsonObject {
    try {
      // 解析结果（可能为对象/数组/原始值）
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed as JsonObject;
      }
      return {};
    } catch (cause) {
      return {};
    }
  }

  /**
   * 解析 `grading_options_json` 为 `GradingOptions`，缺字段以契约缺省补齐；整体损坏回退全缺省。
   * @param raw grading_options_json 原始串。
   * @returns 判分选项（字段齐全）。
   */
  private static parseGradingOptions(raw: string): GradingOptions {
    try {
      // 解析为可空字段的中间对象（逐字段按存在性回退缺省）
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return ExerciseRepositoryImpl.cloneDefaultGradingOptions();
      }
      // 以索引访问读取可空字段（类型不符时回退缺省）
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      return {
        caseSensitive: ExerciseRepositoryImpl.readBool(obj, 'caseSensitive', DEFAULT_GRADING_OPTIONS.caseSensitive),
        trimWhitespace: ExerciseRepositoryImpl.readBool(obj, 'trimWhitespace', DEFAULT_GRADING_OPTIONS.trimWhitespace),
        collapseWhitespace:
          ExerciseRepositoryImpl.readBool(obj, 'collapseWhitespace', DEFAULT_GRADING_OPTIONS.collapseWhitespace),
        ignoreTerminalPunctuation:
          ExerciseRepositoryImpl.readBool(obj, 'ignoreTerminalPunctuation', DEFAULT_GRADING_OPTIONS.ignoreTerminalPunctuation),
        normalizeApostrophes:
          ExerciseRepositoryImpl.readBool(obj, 'normalizeApostrophes', DEFAULT_GRADING_OPTIONS.normalizeApostrophes),
        maxEditDistance:
          ExerciseRepositoryImpl.readNumber(obj, 'maxEditDistance', DEFAULT_GRADING_OPTIONS.maxEditDistance)
      };
    } catch (cause) {
      return ExerciseRepositoryImpl.cloneDefaultGradingOptions();
    }
  }

  /**
   * 克隆缺省判分选项（避免共享可变引用）。
   * @returns 缺省判分选项副本。
   */
  private static cloneDefaultGradingOptions(): GradingOptions {
    return {
      caseSensitive: DEFAULT_GRADING_OPTIONS.caseSensitive,
      trimWhitespace: DEFAULT_GRADING_OPTIONS.trimWhitespace,
      collapseWhitespace: DEFAULT_GRADING_OPTIONS.collapseWhitespace,
      ignoreTerminalPunctuation: DEFAULT_GRADING_OPTIONS.ignoreTerminalPunctuation,
      normalizeApostrophes: DEFAULT_GRADING_OPTIONS.normalizeApostrophes,
      maxEditDistance: DEFAULT_GRADING_OPTIONS.maxEditDistance
    };
  }

  /**
   * 从中间对象读取布尔字段；缺失或类型不符时回退缺省。
   * @param obj 解析后的中间对象。
   * @param key 字段名。
   * @param fallback 缺省值。
   * @returns 布尔值。
   */
  private static readBool(obj: Record<string, Object>, key: string, fallback: boolean): boolean {
    // 字段值（可能 undefined / 非布尔）
    const value: Object = obj[key];
    return typeof value === 'boolean' ? value : fallback;
  }

  /**
   * 从中间对象读取数值字段；缺失或类型不符时回退缺省。
   * @param obj 解析后的中间对象。
   * @param key 字段名。
   * @param fallback 缺省值。
   * @returns 数值。
   */
  private static readNumber(obj: Record<string, Object>, key: string, fallback: number): number {
    // 字段值（可能 undefined / 非数值）
    const value: Object = obj[key];
    return typeof value === 'number' ? value : fallback;
  }
}

/** 练习归属（book_id/chapter_id，attempt 的 NOT NULL 外键来源）。 */
interface ExerciseOwner {
  /** 所属书籍内部主键。 */
  bookId: Id;
  /** 所属章节内部主键。 */
  chapterId: Id;
}
