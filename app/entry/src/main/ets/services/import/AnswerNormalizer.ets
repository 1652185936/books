/**
 * 答案标准化（LLD §4.3）。导入端（P1-4 生成 `accepted_answers.normalized_answer`）与
 * 判分端（F07 GradingEngine）**必须共用本实现**（《06》§4.2 第 1 条：导入与判分用完全相同的标准化函数），
 * 否则同一答案在两端归一不一致会导致主答案选取/去重与运行期判分错位。
 *
 * 标准化顺序严格对齐 §4.3 七步：
 *   1. Unicode NFC 规范化。
 *   2. 去除首尾空白（`trimWhitespace`，默认开）。
 *   3. 连续空白压缩为单个空格（`collapseWhitespace`，默认开）。
 *   4. 弯引号统一为直引号（双引号恒转；单引号/撇号在 `normalizeApostrophes` 开时转 —— 默认开，
 *      用于解决协议自带示例 `"'s drinking"`（直撇号）与 `"’s drinking"`（弯撇号）归一后撞同一 normalized 的去重，R-035）。
 *   5. 按题目配置忽略大小写（`!caseSensitive`，默认忽略 → 转小写）。
 *   6. 按题目配置忽略末尾句号/问号/感叹号（`ignoreTerminalPunctuation`，默认关）。
 *   7. 保留内部撇号，不把 `is` 与 `'s` 无条件互换（本步为「不做某事」，无操作）。
 *
 * 纯函数、零 `@ohos.*` 依赖、可单测。开关来源为 `exercises.grading_options_json`（《06》§4.1），
 * 判分引擎不得硬编码默认值；本模块的默认值仅在协议未声明对应键时生效，并集中固化于 `DEFAULT_NORMALIZE_OPTIONS`。
 */
import { JsonValue } from './JsonSchemaValidator';

/**
 * 标准化开关（§4.1 `gradingOptions` 中与文本归一相关的子集）。
 * `mode`/`maxEditDistance` 不影响标准化，故不在此结构内。
 */
export interface NormalizeOptions {
  /** 是否区分大小写（默认 false：忽略大小写 → 转小写）。 */
  caseSensitive: boolean;
  /** 是否去除首尾空白（默认 true）。 */
  trimWhitespace: boolean;
  /** 是否压缩连续空白为单空格（默认 true）。 */
  collapseWhitespace: boolean;
  /** 是否忽略末尾终止标点 `.`/`?`/`!`（默认 false）。 */
  ignoreTerminalPunctuation: boolean;
  /** 是否归一撇号（弯撇号 → 直撇号，默认 true）。 */
  normalizeApostrophes: boolean;
}

/** 标准化默认开关（协议未声明对应 `gradingOptions` 键时使用，§4.1）。 */
export const DEFAULT_NORMALIZE_OPTIONS: NormalizeOptions = {
  caseSensitive: false,
  trimWhitespace: true,
  collapseWhitespace: true,
  ignoreTerminalPunctuation: false,
  normalizeApostrophes: true
};

/** 弯双引号（含书名号式）字符集合 → 统一为直双引号 `"`。 */
const CURLY_DOUBLE_QUOTES: RegExp = /[“”„‟«»]/g;
/** 弯单引号/撇号/角分符/反引号集合 → 统一为直撇号 `'`。 */
const CURLY_SINGLE_QUOTES: RegExp = /[‘’‚‛′´`]/g;
/** 连续空白（含换行/制表）匹配。 */
const WHITESPACE_RUN: RegExp = /\s+/g;
/** 末尾终止标点（一个或多个 `.`/`?`/`!`）。 */
const TERMINAL_PUNCTUATION: RegExp = /[.?!]+$/;
/** 末尾残留空白（去除终止标点后可能出现）。 */
const TRAILING_WHITESPACE: RegExp = /\s+$/;

/**
 * 答案标准化工具（静态方法集合，纯函数）。
 */
export class AnswerNormalizer {
  /**
   * 从协议 `grading` 对象解析标准化开关；缺省键回退到 `DEFAULT_NORMALIZE_OPTIONS`（§4.1 不硬编码默认值即指此回退）。
   * @param grading 协议 `exercise.grading` 对象（已 Schema 校验，可能为 undefined）。
   * @returns 解析后的标准化开关。
   */
  static optionsFrom(grading: Record<string, JsonValue> | undefined): NormalizeOptions {
    // 无 grading 时全部取默认
    if (grading === undefined) {
      return DEFAULT_NORMALIZE_OPTIONS;
    }
    return {
      caseSensitive: AnswerNormalizer.boolOr(grading.caseSensitive, DEFAULT_NORMALIZE_OPTIONS.caseSensitive),
      trimWhitespace: AnswerNormalizer.boolOr(grading.trimWhitespace, DEFAULT_NORMALIZE_OPTIONS.trimWhitespace),
      collapseWhitespace:
        AnswerNormalizer.boolOr(grading.collapseWhitespace, DEFAULT_NORMALIZE_OPTIONS.collapseWhitespace),
      ignoreTerminalPunctuation:
        AnswerNormalizer.boolOr(grading.ignoreTerminalPunctuation, DEFAULT_NORMALIZE_OPTIONS.ignoreTerminalPunctuation),
      normalizeApostrophes:
        AnswerNormalizer.boolOr(grading.normalizeApostrophes, DEFAULT_NORMALIZE_OPTIONS.normalizeApostrophes)
    };
  }

  /**
   * 按 §4.3 七步对文本做标准化。
   * @param text 原始文本（协议 `display` 或某条 `accepted`）。
   * @param options 标准化开关。
   * @returns 标准化后的文本。
   */
  static normalize(text: string, options: NormalizeOptions): string {
    // 步骤 1：Unicode NFC
    let s: string = text.normalize('NFC');
    // 步骤 2：去首尾空白
    if (options.trimWhitespace) {
      s = s.trim();
    }
    // 步骤 3：压缩连续空白为单空格
    if (options.collapseWhitespace) {
      s = s.replace(WHITESPACE_RUN, ' ');
    }
    // 步骤 4：弯引号 → 直引号（双引号恒转；撇号按开关）
    s = s.replace(CURLY_DOUBLE_QUOTES, '"');
    if (options.normalizeApostrophes) {
      s = s.replace(CURLY_SINGLE_QUOTES, "'");
    }
    // 步骤 5：忽略大小写
    if (!options.caseSensitive) {
      s = s.toLowerCase();
    }
    // 步骤 6：忽略末尾终止标点（并清理因此产生的末尾空白）
    if (options.ignoreTerminalPunctuation) {
      s = s.replace(TERMINAL_PUNCTUATION, '');
      if (options.trimWhitespace) {
        s = s.replace(TRAILING_WHITESPACE, '');
      }
    }
    // 步骤 7：保留内部撇号，不做 is/'s 互换（无操作）
    return s;
  }

  /**
   * 读取 JSON 值为布尔，非布尔时回退默认值。
   * @param value JSON 值（可能为 undefined）。
   * @param fallback 回退默认值。
   * @returns 布尔结果。
   */
  private static boolOr(value: JsonValue | undefined, fallback: boolean): boolean {
    return typeof value === 'boolean' ? value : fallback;
  }
}
