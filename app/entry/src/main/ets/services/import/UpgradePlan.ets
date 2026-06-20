/**
 * 升级（upgrade）内容重映射纯规划器（P1-5，LLD §2.7 step2 + 《06-协议到数据库映射规范》§10 R-006）。
 *
 * 单一真值：升级采用「按 `external_id` 原地 UPDATE、内部主键保持稳定」（《06》§10）。`ContentMapper` 对新包
 * 产出的 `BookIndexModel` 携带的是**全新**内部主键；本规划器把它锚定到旧书已存在的内部 id 上，从而
 * `exercise_attempts.{exercise_id,chapter_id}`、`wrong_items.exercise_id`、`review_cards.chapter_id` 等
 * 冗余/外键列自然保持一致，历史答题与错题不丢失（满足 FR-F03-06、验收 5）。
 *
 * 产出 `UpgradePlan`：把新模型按 (chapter/section/exercise) 的 `external_id` 分为
 * 「匹配→UPDATE（沿用旧内部 id）」「新增→INSERT」；旧包存在、新包缺失的练习 `external_id` 落 `removedExerciseIds`
 * （由仓储置 `enabled=0` 并保留其 attempts/wrong_items，不物理删除，《06》§10）。匹配/新增父级下的子行
 * （content_blocks / exercise_blanks / accepted_answers / grading_rules）整体替换，其父引用列已翻译为有效内部 id。
 *
 * 纯函数、零 `@ohos.*`/relationalStore 依赖、可单测：实际读旧索引与执行 UPDATE/INSERT/DELETE 由
 * `BookContentRepository.upgradeBook` 承担（SDK 侧）。本模块只做「新模型 + 旧锚点 → 执行计划」的纯计算。
 *
 * 范围边界（非降级，按规格归属委派）：notes/highlights 的升级重定位（`needs-relocation`/`orphaned`，§3.16/§3.17）
 * 与 reading_progress/section_progress 锚点重映射（§10）由**拥有这些表的 F08/F01** 承担；本规划器只负责内容索引
 * 五张表（books/chapters/sections/content_blocks/exercises 及其子表）的原地锚定，不触碰用户笔迹/进度表。
 */
import {
  BookIndexModel, BookRow, ChapterRow, SectionRow, ContentBlockRow, ExerciseRow,
  ExerciseBlankRow, AcceptedAnswerRow, GradingRuleRow, ReviewCardRow, ContentReviewFlagRow, AssetRow
} from './ContentMapper';

/** 旧章节锚点（升级前从 DB 读出：external_id → 旧内部章节 id）。 */
export interface ExistingChapterAnchor {
  /** 学习包章节 external_id。 */
  externalId: string;
  /** 旧内部章节 id（保持稳定）。 */
  id: string;
}

/** 旧小节锚点（按所属旧章节 id + external_id 唯一）。 */
export interface ExistingSectionAnchor {
  /** 旧内部章节 id。 */
  chapterId: string;
  /** 学习包小节 external_id。 */
  externalId: string;
  /** 旧内部小节 id。 */
  id: string;
}

/** 旧练习锚点（按所属旧章节 id + external_id 唯一）。 */
export interface ExistingExerciseAnchor {
  /** 旧内部章节 id。 */
  chapterId: string;
  /** 学习包练习 external_id。 */
  externalId: string;
  /** 旧内部练习 id。 */
  id: string;
}

/** 升级前的旧书索引锚点集合（由 `BookContentRepository.readExistingIndex` 读出）。 */
export interface ExistingIndex {
  /** 旧章节锚点。 */
  chapters: ExistingChapterAnchor[];
  /** 旧小节锚点。 */
  sections: ExistingSectionAnchor[];
  /** 旧练习锚点。 */
  exercises: ExistingExerciseAnchor[];
}

/** 升级执行计划（供 `BookContentRepository.upgradeBook` 在单事务内逐表落库）。 */
export interface UpgradePlan {
  /** books 行（id 即旧书内部 id；仓储以 UPDATE 落库，保留 imported_at）。 */
  book: BookRow;
  /** 匹配章节（沿用旧内部 id）→ UPDATE。 */
  chaptersUpdate: ChapterRow[];
  /** 新增章节 → INSERT。 */
  chaptersInsert: ChapterRow[];
  /** 匹配小节（沿用旧内部 id，chapterId 已翻译）→ UPDATE。 */
  sectionsUpdate: SectionRow[];
  /** 新增小节（chapterId 已翻译）→ INSERT。 */
  sectionsInsert: SectionRow[];
  /** 全部内容块（sectionId 已翻译；仓储先清 `affectedSectionIds` 旧块再整体插入）。 */
  blocks: ContentBlockRow[];
  /** 匹配练习（沿用旧内部 id，chapterId 已翻译，enabled 取新模型）→ UPDATE。 */
  exercisesUpdate: ExerciseRow[];
  /** 新增练习（chapterId 已翻译）→ INSERT。 */
  exercisesInsert: ExerciseRow[];
  /** 全部空位（exerciseId 已翻译；仓储先清 `affectedExerciseIds` 旧子行再整体插入）。 */
  blanks: ExerciseBlankRow[];
  /** 全部可接受答案（blankId 引用新模型新生成空位 id，无需翻译）。 */
  acceptedAnswers: AcceptedAnswerRow[];
  /** 全部判分规则（exerciseId 已翻译）。 */
  gradingRules: GradingRuleRow[];
  /** 复习卡（chapterId 已翻译；仓储按 source_id upsert，保留调度字段）。 */
  reviewCards: ReviewCardRow[];
  /** 复核标记（仓储按 book_id 整体替换）。 */
  reviewFlags: ContentReviewFlagRow[];
  /** 资源（仓储按 book_id 整体替换）。 */
  assets: AssetRow[];
  /** 旧包存在、新包缺失的练习旧内部 id → 仓储置 enabled=0（保留 attempts/wrong_items）。 */
  removedExerciseIds: string[];
  /** 旧包存在、新包缺失的章节旧内部 id → 仓储保留行（attempts FK 历史）但 order 移出有效区。 */
  removedChapterIds: string[];
  /** 旧包存在、新包缺失的小节旧内部 id → 仓储物理删除（级联其块/section_progress，§10 允许）。 */
  removedSectionIds: string[];
  /** 受影响小节有效内部 id（其旧内容块在插入前被清空替换）。 */
  affectedSectionIds: string[];
  /** 受影响练习有效内部 id（其旧空位/答案/规则在插入前被清空替换）。 */
  affectedExerciseIds: string[];
  /** 警告计数（IMP-015，透传自新模型 → import_jobs.warning_count）。 */
  warningCount: number;
}

/** 复合键分隔符（不会出现在 external_id / 内部 id 中的控制字符）。 */
const KEY_SEP: string = '';

/**
 * 拼复合键（旧章节 id + external_id）用于小节/练习的唯一匹配。
 * @param a 第一段（旧内部章节 id）。
 * @param b 第二段（external_id）。
 * @returns 复合键字符串。
 */
function compositeKey(a: string, b: string): string {
  return a + KEY_SEP + b;
}

/**
 * 升级内容重映射规划：把新 `BookIndexModel` 锚定到旧书已存在内部 id（《06》§10）。
 * @param model `ContentMapper.map` 对新包产出的索引模型（其 `book.id` 必须等于旧书内部 id）。
 * @param existing 旧书 external_id → 旧内部 id 锚点集合。
 * @returns 升级执行计划。
 */
export function planUpgrade(model: BookIndexModel, existing: ExistingIndex): UpgradePlan {
  // 旧章节：external_id → 旧内部章节 id
  const oldChapterByExt: Record<string, string> = {};
  for (let i: number = 0; i < existing.chapters.length; i++) {
    oldChapterByExt[existing.chapters[i].externalId] = existing.chapters[i].id;
  }
  // 旧小节：compositeKey(旧章节 id, external_id) → 旧内部小节 id
  const oldSectionByKey: Record<string, string> = {};
  for (let i: number = 0; i < existing.sections.length; i++) {
    const s: ExistingSectionAnchor = existing.sections[i];
    oldSectionByKey[compositeKey(s.chapterId, s.externalId)] = s.id;
  }
  // 旧练习：compositeKey(旧章节 id, external_id) → 旧内部练习 id
  const oldExerciseByKey: Record<string, string> = {};
  for (let i: number = 0; i < existing.exercises.length; i++) {
    const e: ExistingExerciseAnchor = existing.exercises[i];
    oldExerciseByKey[compositeKey(e.chapterId, e.externalId)] = e.id;
  }

  // 三类父级 id 翻译表：新模型生成的临时 id → 有效内部 id（匹配旧的沿用旧 id，新增的沿用新 id）
  const chapterIdMap: Record<string, string> = {};
  const sectionIdMap: Record<string, string> = {};
  const exerciseIdMap: Record<string, string> = {};

  // 章节：分匹配（UPDATE）/ 新增（INSERT）
  const chaptersUpdate: ChapterRow[] = [];
  const chaptersInsert: ChapterRow[] = [];
  // 新模型覆盖到的章节有效 id 集合（用于推导被删章节）
  const presentChapterIds: Record<string, boolean> = {};
  for (let i: number = 0; i < model.chapters.length; i++) {
    // 当前新章节行
    const ch: ChapterRow = model.chapters[i];
    // 旧匹配内部 id（按 external_id）
    const matched: string | undefined = oldChapterByExt[ch.externalId];
    // 有效内部 id：匹配则沿用旧 id，否则用新 id
    const effId: string = matched !== undefined ? matched : ch.id;
    chapterIdMap[ch.id] = effId;
    presentChapterIds[effId] = true;
    // 翻译后的章节行（仅 id 改为有效 id；book_id 稳定）
    const row: ChapterRow = ch;
    row.id = effId;
    if (matched !== undefined) {
      chaptersUpdate.push(row);
    } else {
      chaptersInsert.push(row);
    }
  }

  // 小节：翻译所属章节 id 后按 (有效章节 id, external_id) 匹配
  const sectionsUpdate: SectionRow[] = [];
  const sectionsInsert: SectionRow[] = [];
  // 受影响小节有效 id（其旧块被替换）——匹配与新增都纳入（新增项删块为 no-op）
  const affectedSectionIds: string[] = [];
  // 新模型覆盖到的小节有效 id 集合（用于推导被删小节）
  const presentSectionIds: Record<string, boolean> = {};
  for (let i: number = 0; i < model.sections.length; i++) {
    // 当前新小节行
    const sec: SectionRow = model.sections[i];
    // 有效所属章节 id
    const effChapterId: string = chapterIdMap[sec.chapterId] !== undefined ? chapterIdMap[sec.chapterId] : sec.chapterId;
    // 旧匹配内部小节 id
    const matched: string | undefined = oldSectionByKey[compositeKey(effChapterId, sec.externalId)];
    // 有效内部小节 id
    const effId: string = matched !== undefined ? matched : sec.id;
    sectionIdMap[sec.id] = effId;
    // 翻译后的小节行
    const row: SectionRow = sec;
    row.id = effId;
    row.chapterId = effChapterId;
    affectedSectionIds.push(effId);
    presentSectionIds[effId] = true;
    if (matched !== undefined) {
      sectionsUpdate.push(row);
    } else {
      sectionsInsert.push(row);
    }
  }

  // 内容块：翻译所属小节 id（id 保持新生成，整体替换）
  const blocks: ContentBlockRow[] = [];
  for (let i: number = 0; i < model.blocks.length; i++) {
    // 当前内容块行
    const blk: ContentBlockRow = model.blocks[i];
    blk.sectionId = sectionIdMap[blk.sectionId] !== undefined ? sectionIdMap[blk.sectionId] : blk.sectionId;
    blocks.push(blk);
  }

  // 练习：翻译所属章节 id 后按 (有效章节 id, external_id) 匹配
  const exercisesUpdate: ExerciseRow[] = [];
  const exercisesInsert: ExerciseRow[] = [];
  // 受影响练习有效 id（其旧子行被替换）
  const affectedExerciseIds: string[] = [];
  // 新模型覆盖到的练习有效 id 集合（用于推导被删练习）
  const presentExerciseIds: Record<string, boolean> = {};
  for (let i: number = 0; i < model.exercises.length; i++) {
    // 当前新练习行
    const ex: ExerciseRow = model.exercises[i];
    // 有效所属章节 id
    const effChapterId: string = chapterIdMap[ex.chapterId] !== undefined ? chapterIdMap[ex.chapterId] : ex.chapterId;
    // 旧匹配内部练习 id
    const matched: string | undefined = oldExerciseByKey[compositeKey(effChapterId, ex.externalId)];
    // 有效内部练习 id
    const effId: string = matched !== undefined ? matched : ex.id;
    exerciseIdMap[ex.id] = effId;
    presentExerciseIds[effId] = true;
    affectedExerciseIds.push(effId);
    // 翻译后的练习行
    const row: ExerciseRow = ex;
    row.id = effId;
    row.chapterId = effChapterId;
    if (matched !== undefined) {
      exercisesUpdate.push(row);
    } else {
      exercisesInsert.push(row);
    }
  }

  // 空位：翻译所属练习 id（id 保持新生成）
  const blanks: ExerciseBlankRow[] = [];
  for (let i: number = 0; i < model.blanks.length; i++) {
    // 当前空位行
    const bl: ExerciseBlankRow = model.blanks[i];
    bl.exerciseId = exerciseIdMap[bl.exerciseId] !== undefined ? exerciseIdMap[bl.exerciseId] : bl.exerciseId;
    blanks.push(bl);
  }

  // 判分规则：翻译所属练习 id（blank_id 引用新生成空位 id，无需翻译）
  const gradingRules: GradingRuleRow[] = [];
  for (let i: number = 0; i < model.gradingRules.length; i++) {
    // 当前规则行
    const gr: GradingRuleRow = model.gradingRules[i];
    gr.exerciseId = exerciseIdMap[gr.exerciseId] !== undefined ? exerciseIdMap[gr.exerciseId] : gr.exerciseId;
    gradingRules.push(gr);
  }

  // 复习卡：翻译所属章节 id（仓储按 source_id upsert 保留调度字段）
  const reviewCards: ReviewCardRow[] = [];
  for (let i: number = 0; i < model.reviewCards.length; i++) {
    // 当前复习卡行
    const rc: ReviewCardRow = model.reviewCards[i];
    rc.chapterId = chapterIdMap[rc.chapterId] !== undefined ? chapterIdMap[rc.chapterId] : rc.chapterId;
    reviewCards.push(rc);
  }

  // 被删练习：旧练习有效 id 不在新模型覆盖集合中 → 置 enabled=0（保留 attempts/wrong_items，《06》§10）
  const removedExerciseIds: string[] = [];
  for (let i: number = 0; i < existing.exercises.length; i++) {
    // 旧练习内部 id
    const oldId: string = existing.exercises[i].id;
    if (presentExerciseIds[oldId] !== true) {
      removedExerciseIds.push(oldId);
    }
  }
  // 被删章节：旧章节不在新模型中 → 保留行（attempts FK 历史），仓储将其 order 移出有效区
  const removedChapterIds: string[] = [];
  for (let i: number = 0; i < existing.chapters.length; i++) {
    // 旧章节内部 id
    const oldId: string = existing.chapters[i].id;
    if (presentChapterIds[oldId] !== true) {
      removedChapterIds.push(oldId);
    }
  }
  // 被删小节：旧小节不在新模型中 → 仓储物理删除（级联块/section_progress，§10 允许）
  const removedSectionIds: string[] = [];
  for (let i: number = 0; i < existing.sections.length; i++) {
    // 旧小节内部 id
    const oldId: string = existing.sections[i].id;
    if (presentSectionIds[oldId] !== true) {
      removedSectionIds.push(oldId);
    }
  }

  return {
    book: model.book,
    chaptersUpdate: chaptersUpdate,
    chaptersInsert: chaptersInsert,
    sectionsUpdate: sectionsUpdate,
    sectionsInsert: sectionsInsert,
    blocks: blocks,
    exercisesUpdate: exercisesUpdate,
    exercisesInsert: exercisesInsert,
    blanks: blanks,
    acceptedAnswers: model.acceptedAnswers,
    gradingRules: gradingRules,
    reviewCards: reviewCards,
    reviewFlags: model.reviewFlags,
    assets: model.assets,
    removedExerciseIds: removedExerciseIds,
    removedChapterIds: removedChapterIds,
    removedSectionIds: removedSectionIds,
    affectedSectionIds: affectedSectionIds,
    affectedExerciseIds: affectedExerciseIds,
    warningCount: model.warningCount
  };
}
