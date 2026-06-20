/**
 * 练习与判分 DTO 契约（《04-接口与DTO契约》§6）。
 * v1 保留全部九种题型（R-063）：五种 *-handwriting 完整实现作答与判分；四种非手写题型导入后保留并占位，
 * 其作答交互列入后续迭代，不得砍除或静默丢弃（CLAUDE.md §2-11）。
 * 适配 ArkTS：ExerciseDetail.gradingOptions 内联对象拆为具名接口 GradingOptions；
 * 04 中 ExerciseRules.gradingOptions 的索引访问类型 ExerciseDetail['gradingOptions'] 改为直接引用 GradingOptions。
 */
import { Id, EpochMs, JsonObject } from './common';
import { HandwritingMode } from './handwriting';

/** 练习题型（九种，04 §6）。 */
export type ExerciseType =
  | 'fill-blank-handwriting'
  | 'multi-blank-handwriting'
  | 'rewrite-sentence-handwriting'
  | 'short-answer-handwriting'
  | 'choice'
  | 'true-false'
  | 'match'
  | 'order-words'
  | 'correction-handwriting';

/** 练习空位。 */
export interface ExerciseBlank {
  /** 空位内部 ID。 */
  id: Id;
  /** 空位键。 */
  blankKey: string;
  /** 空位序号。 */
  orderNo: number;
  /** 宽度（em，相对正文字号；emToVp(em)=em×16，LLD §1.3 R-035）。 */
  widthEm: number;
  /** 行数。 */
  lines: number;
  /** 手写识别模式。 */
  handwritingMode: HandwritingMode;
  /** 主答案（展示用）。 */
  displayAnswer: string;
  /** 可接受答案集合（去重后，《06》§答案去重）。 */
  acceptedAnswers: string[];
}

/** 判分选项。 */
export interface GradingOptions {
  /** 是否区分大小写。 */
  caseSensitive: boolean;
  /** 是否去除首尾空白。 */
  trimWhitespace: boolean;
  /** 是否折叠连续空白。 */
  collapseWhitespace: boolean;
  /** 是否忽略句末标点。 */
  ignoreTerminalPunctuation: boolean;
  /** 是否归一化撇号。 */
  normalizeApostrophes: boolean;
  /** 最大允许编辑距离。 */
  maxEditDistance: number;
}

/** 练习详情。 */
export interface ExerciseDetail {
  /** 练习内部 ID。 */
  id: Id;
  /** 学习包外部练习 ID。 */
  externalId: string;
  /** 所属书籍 ID。 */
  bookId: Id;
  /** 所属章节 ID。 */
  chapterId: Id;
  /** 练习序号。 */
  orderNo: number;
  /** 题型。 */
  type: ExerciseType;
  /** 题干指令。 */
  instruction: string;
  /** 题面载体。 */
  prompt: JsonObject;
  /** 上下文载体。 */
  context: JsonObject;
  /** 空位列表。 */
  blanks: ExerciseBlank[];
  /** 判分选项。 */
  gradingOptions: GradingOptions;
}

/** 已确认答案（识别成功后构造；失败不构造、不调用判分，04 §12 规则3）。 */
export interface ConfirmedAnswer {
  /** 空位键。 */
  blankKey: string;
  /** 识别文本。 */
  recognizedText: string;
  /** 关联 handwriting_records（原始笔迹与识别文本分存）。 */
  strokeRecordId: Id;
}

/** 单空判分结果。 */
export interface BlankGradeResult {
  /** 空位键。 */
  blankKey: string;
  /** 识别文本。 */
  recognizedText: string;
  /** 归一化文本。 */
  normalizedText: string;
  /** 判定结果。 */
  result: 'correct' | 'partial' | 'incorrect';
  /** 得分（0 / 0.5 / 1）。 */
  score: 0 | 0.5 | 1;
  /** 反馈码。 */
  feedbackCode: string;
  /** 中文反馈。 */
  feedbackZh: string;
  /** 期望答案展示。 */
  expectedDisplay: string;
}

/** 整体判分结果。 */
export interface GradeResult {
  /** 整体判定。 */
  overall: 'correct' | 'partial' | 'incorrect';
  /** 总分：各空 score 算术平均，0..1（04 §12 规则2）。 */
  score: number;
  /** 逐空结果（多空题必返回，04 §12 规则2）。 */
  perBlank: BlankGradeResult[];
  /** 提交时间。 */
  submittedAt: EpochMs;
}

/** 练习作答草稿。 */
export interface ExerciseAttemptDraft {
  /** 作答 ID。 */
  attemptId: Id;
  /** 练习 ID。 */
  exerciseId: Id;
  /** 开始时间。 */
  startedAt: EpochMs;
  /** 已确认答案集合。 */
  answers: ConfirmedAnswer[];
}

/** 练习仓储契约。 */
export interface ExerciseRepository {
  /**
   * 取练习详情。
   * @param exerciseId 练习 ID
   * @returns 练习详情
   */
  getExercise(exerciseId: Id): Promise<ExerciseDetail>;
  /**
   * 创建作答草稿。
   * @param exerciseId 练习 ID
   * @returns 作答草稿
   */
  createDraft(exerciseId: Id): Promise<ExerciseAttemptDraft>;
  /**
   * 保存判分结果。
   * @param attemptId 作答 ID
   * @param result 判分结果
   */
  saveGrade(attemptId: Id, result: GradeResult): Promise<void>;
}

/** 判分服务（异步取数 + 持久化编排，04 §12 规则1）。 */
export interface GradingService {
  /**
   * 判分。
   * @param exerciseId 练习 ID
   * @param answers 已确认答案集合
   * @returns 判分结果
   */
  grade(exerciseId: Id, answers: ConfirmedAnswer[]): Promise<GradeResult>;
}

/** 纯判分引擎入参规则（无 IO）。 */
export interface ExerciseRules {
  /** 空位列表。 */
  blanks: ExerciseBlank[];
  /** 判分选项。 */
  gradingOptions: GradingOptions;
  /** 判分规则载体（regex 等，运行期防 ReDoS，LLD §3.11）。 */
  rules: JsonObject[];
}

/** 纯判分引擎（同步纯函数，04 §12 规则1）。 */
export interface GradingEngine {
  /**
   * 同步判分。
   * @param rules 判分规则
   * @param answers 已确认答案集合
   * @returns 判分结果
   */
  grade(rules: ExerciseRules, answers: ConfirmedAnswer[]): GradeResult;
}
