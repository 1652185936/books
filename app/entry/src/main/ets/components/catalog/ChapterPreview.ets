/**
 * 书籍目录页 章节预览（F04，LLD §6.4 主组件 ChapterPreview）。
 *
 * 右侧预览区：展示选中章节的标题（中英）、类型、预计时长、完成度与进度状态，并提供「开始学习」主操作
 * （跳转 P-F05 章节讲解页）。损坏章节禁用「开始学习」并给出损坏提示；未选中章节时给出空提示。
 * 「开始学习」为主操作（品牌红，CLAUDE.md §6），触控目标 ≥56vp；可见文本走资源键（CLAUDE.md §5）。
 */
import { ChapterSummary } from '../../domain/entities/content';
import { Id } from '../../domain/entities/common';
import { LessonTokens } from '../lesson/LessonTokens';

@Component
export struct ChapterPreview {
  /** 选中章节摘要（未选中为 undefined）。 */
  @Prop chapter?: ChapterSummary;
  /** 选中章节是否内容损坏（禁用「开始学习」）。 */
  @Prop broken: boolean = false;
  /** 开始学习回调（跳转章节讲解页）。 */
  onStartLearning: (chapterId: Id) => void = () => {};

  /**
   * kind 文案资源键（章节类型徽标）。
   * @param kind 章节类型。
   * @returns 文案资源键。
   */
  private kindLabel(kind: ChapterSummary['kind']): ResourceStr {
    if (kind === 'review') {
      return $r('app.string.catalog_kind_review');
    }
    if (kind === 'appendix') {
      return $r('app.string.catalog_kind_appendix');
    }
    if (kind === 'answer-key') {
      return $r('app.string.catalog_kind_answer_key');
    }
    if (kind === 'index') {
      return $r('app.string.catalog_kind_index');
    }
    return $r('app.string.catalog_kind_lesson');
  }

  /**
   * 元信息行（标签 + 资源值）。
   * @param label 标签文案资源。
   * @param value 值文案资源。
   */
  @Builder
  metaRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(LessonTokens.FONT_CAPTION)
        .fontColor(LessonTokens.INK_MUTED)
      Text(value)
        .fontSize(LessonTokens.FONT_CAPTION)
        .fontColor(LessonTokens.INK_SECONDARY)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 元信息行（标签 + 数字值 + 单位标签，单位走资源键避免硬编码）。
   * @param label 标签文案资源。
   * @param value 数字值文本（如时长/百分比）。
   * @param unit 单位文案资源。
   */
  @Builder
  metaRowWithUnit(label: ResourceStr, value: string, unit: ResourceStr) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(LessonTokens.FONT_CAPTION)
        .fontColor(LessonTokens.INK_MUTED)
      Row({ space: 2 }) {
        Text(value)
          .fontSize(LessonTokens.FONT_CAPTION)
          .fontColor(LessonTokens.INK_SECONDARY)
        Text(unit)
          .fontSize(LessonTokens.FONT_CAPTION)
          .fontColor(LessonTokens.INK_SECONDARY)
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      if (this.chapter === undefined) {
        // 未选中章节：空提示（不白屏）
        Column() {
          Text($r('app.string.catalog_preview_empty'))
            .fontSize(LessonTokens.FONT_BODY)
            .fontColor(LessonTokens.INK_MUTED)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        // 预览主体（取本地常量避免在多分支重复访问可空字段）
        Column({ space: 14 }) {
          // 标题（中文优先回退英文）
          Text((this.chapter as ChapterSummary).titleZh.length > 0
            ? (this.chapter as ChapterSummary).titleZh
            : (this.chapter as ChapterSummary).title)
            .fontSize(LessonTokens.FONT_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(LessonTokens.INK)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 英文副标题（中英都有时展示）
          if ((this.chapter as ChapterSummary).titleZh.length > 0
            && (this.chapter as ChapterSummary).title.length > 0) {
            Text((this.chapter as ChapterSummary).title)
              .fontSize(LessonTokens.FONT_CAPTION + 1)
              .fontColor(LessonTokens.INK_SECONDARY)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          // 元信息：类型 / 预计时长 / 进度
          this.metaRow($r('app.string.catalog_meta_kind'), this.kindLabel((this.chapter as ChapterSummary).kind))
          this.metaRowWithUnit($r('app.string.catalog_meta_minutes'),
            `${(this.chapter as ChapterSummary).estimatedMinutes}`, $r('app.string.catalog_minutes_unit'))
          this.metaRowWithUnit($r('app.string.catalog_meta_completion'),
            `${Math.round((this.chapter as ChapterSummary).completionPercent)}`, $r('app.string.catalog_percent_unit'))

          // 损坏提示（损坏章节）
          if (this.broken) {
            Text($r('app.string.catalog_chapter_broken_hint'))
              .fontSize(LessonTokens.FONT_CAPTION)
              .fontColor(LessonTokens.WARN_AMBER)
          }

          Blank()

          // 开始学习（主操作，品牌红；损坏章节禁用）
          Button($r('app.string.catalog_start_learning'))
            .type(ButtonType.Capsule)
            .width('100%')
            .height(56)
            .fontSize(LessonTokens.FONT_BODY)
            .fontColor(Color.White)
            .backgroundColor(this.broken ? LessonTokens.INK_MUTED : LessonTokens.BRAND_RED)
            .enabled(!this.broken)
            .onClick(() => {
              if (!this.broken && this.chapter !== undefined) {
                this.onStartLearning((this.chapter as ChapterSummary).id);
              }
            })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .padding(LessonTokens.PAGE_PADDING)
    .backgroundColor(Color.White)
  }
}
