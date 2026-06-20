/**
 * 章节讲解页设计 token（F05，CLAUDE.md §6）。
 *
 * 颜色语义遵 CLAUDE.md §6：红色仅作品牌强调与主操作；正确用绿色、警告用琥珀色。
 * 尺寸以平板横屏 1280×800 vp 为基线（§6），触控目标 ≥48vp。集中此处避免散落硬编码（视觉常量非用户文本，
 * 用户可见文本仍走 `$r('app.string.*')`）。
 */
export class LessonTokens {
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
  /** 抽屉遮罩。 */
  static readonly SCRIM: string = 'rgba(0,0,0,0.35)';
  /** 标题字号（vp）。 */
  static readonly FONT_TITLE: number = 22;
  /** 小标题字号。 */
  static readonly FONT_HEADING: number = 18;
  /** 正文字号（= 练习正文基准 1em=16vp，§1.3 R-035）。 */
  static readonly FONT_BODY: number = 16;
  /** 次要字号。 */
  static readonly FONT_CAPTION: number = 13;
  /** 内容块垂直间距。 */
  static readonly BLOCK_GAP: number = 14;
  /** 页面横向内边距。 */
  static readonly PAGE_PADDING: number = 24;
  /** 触控主操作最小尺寸（§6，手写主操作 ≥56vp，常规 ≥48vp）。 */
  static readonly TOUCH_MIN: number = 48;
}
