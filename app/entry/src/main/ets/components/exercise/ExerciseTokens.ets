/**
 * 手写练习页设计 token 与单位换算助手（F06，LLD §6.6 / §1.3 R-035 / CLAUDE.md §6）。
 *
 * 颜色语义遵 CLAUDE.md §6：红色仅作品牌强调与主操作；正确用绿色、警告用琥珀色。尺寸以平板横屏
 * 1280×800 vp 基线（§6），常规触控 ≥48vp、手写主操作 ≥56vp、手写横线有效书写高度 ≥88vp。集中此处
 * 避免散落硬编码（视觉常量非用户文本，用户可见文本仍走 `$r('app.string.*')`）。
 *
 * 单位换算（LLD §1.3 R-035）：`exercise_blanks.width_em` 的 `em` 相对练习正文字号，固定 `1em=16vp`；
 * `widthEm∈[3,40]` 经 `emToVp` 换算到 `[48,640]vp`，再经 `clampBlankWidthVp` 夹到 `[96,360]vp`（§6.6）。
 * `emToVp`/`clampBlankWidthVp` 为纯函数（无 ArkUI/`@ohos.*` 依赖），便于 `.ralph/f06-test/` 断言。
 */
export class ExerciseTokens {
  /** 练习正文基准字号（= 1em；`emToVp` 的换算基准，§1.3 R-035）。 */
  static readonly EM_BASE_VP: number = 16;
  /** blank 渲染宽度下限（vp，§6.6 clamp 下界）。 */
  static readonly BLANK_MIN_WIDTH_VP: number = 96;
  /** blank 渲染宽度上限（vp，§6.6 clamp 上界）。 */
  static readonly BLANK_MAX_WIDTH_VP: number = 360;
  /** 手写横线单行有效书写高度（vp，CLAUDE.md §6 / §6.6 ≥88vp）。 */
  static readonly BLANK_LINE_HEIGHT_VP: number = 88;

  /** 品牌强调红（主操作/强调，§6）。 */
  static readonly BRAND_RED: string = '#C8102E';
  /** 正文主色（深墨）。 */
  static readonly INK: string = '#1A1A1A';
  /** 次要文字色。 */
  static readonly INK_SECONDARY: string = '#5C5C5C';
  /** 弱化/占位文字色。 */
  static readonly INK_MUTED: string = '#9A9A9A';
  /** 正确绿（§6）。 */
  static readonly CORRECT_GREEN: string = '#2E7D32';
  /** 警告琥珀（§6）。 */
  static readonly WARN_AMBER: string = '#B26A00';
  /** 卡片/分隔背景。 */
  static readonly SURFACE: string = '#F5F5F7';
  /** 卡片边框。 */
  static readonly BORDER: string = '#E3E3E6';
  /** blank 默认边框（非激活态）。 */
  static readonly BLANK_BORDER: string = '#C9C9CE';
  /** blank 激活态强调边框（当前空，§6.6「当前 blank 使用强调边框」）。 */
  static readonly BLANK_ACTIVE_BORDER: string = '#C8102E';
  /** 墨迹默认颜色（与 §4.1 示例一致，可由设置覆盖 handwriting.penColor，F12）。 */
  static readonly PEN_COLOR: string = '#2F65A4';
  /** 默认笔宽（vp，settings handwriting.penWidth 缺省）。 */
  static readonly PEN_WIDTH: number = 3;

  /** 标题字号（vp）。 */
  static readonly FONT_TITLE: number = 22;
  /** 小标题/指令字号。 */
  static readonly FONT_HEADING: number = 18;
  /** 正文/题面字号（= 1em=16vp，§1.3 R-035）。 */
  static readonly FONT_BODY: number = 16;
  /** 次要字号。 */
  static readonly FONT_CAPTION: number = 13;
  /** 页面横向内边距。 */
  static readonly PAGE_PADDING: number = 24;
  /** 主体内容块垂直间距。 */
  static readonly BLOCK_GAP: number = 16;
  /** 常规触控最小尺寸（§6，≥48vp）。 */
  static readonly TOUCH_MIN: number = 48;
  /** 手写主操作最小尺寸（§6，≥56vp，确认答案/笔工具栏主按钮）。 */
  static readonly TOUCH_HANDWRITING_MIN: number = 56;
}

/**
 * em → vp 换算（LLD §1.3 R-035：固定 `1em=16vp`，`emToVp(em)=em×16`）。
 * 任何把 `widthEm` 与 vp 比较/取值的表达式必须先经本函数换算。
 * @param em 相对正文字号的倍数（exercise_blanks.width_em，协议约束 ∈[3,40]）。
 * @returns 换算后的 vp 值（未夹取）。
 */
export function emToVp(em: number): number {
  // 线性换算：相对字号倍数 × 正文基准字号
  return em * ExerciseTokens.EM_BASE_VP;
}

/**
 * 计算 blank 的渲染宽度（vp）：先 `emToVp` 换算，再夹到 `[96,360]vp`（§6.6 `clamp(emToVp(widthEm),96,360)`，R-035）。
 * @param widthEm 空位宽度（em；协议 width_em∈[3,40]，越界由本夹取兜底）。
 * @returns 夹取后的渲染宽度（vp）。
 */
export function clampBlankWidthVp(widthEm: number): number {
  // 先换算到 vp（widthEm∈[3,40] → [48,640]vp）
  const raw: number = emToVp(widthEm);
  // 再夹到 [96,360]vp（下界优先于上界，保证 min≤max 时结果落在闭区间）
  if (raw < ExerciseTokens.BLANK_MIN_WIDTH_VP) {
    return ExerciseTokens.BLANK_MIN_WIDTH_VP;
  }
  if (raw > ExerciseTokens.BLANK_MAX_WIDTH_VP) {
    return ExerciseTokens.BLANK_MAX_WIDTH_VP;
  }
  return raw;
}

/**
 * 计算 blank 的渲染高度（vp）：每行有效书写高度 ≥88vp（§6.6 / CLAUDE.md §6），多行按行数线性累加。
 * @param lines 行数（exercise_blanks.lines∈[1,5]）。
 * @returns 渲染高度（vp）。
 */
export function blankHeightVp(lines: number): number {
  // 至少 1 行；每行不低于有效书写高度（保证手写空间充足）
  const safeLines: number = lines >= 1 ? lines : 1;
  return safeLines * ExerciseTokens.BLANK_LINE_HEIGHT_VP;
}
