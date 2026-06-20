/**
 * 空 sections 章节视图（F05，R-034 / LLD §6.5）。
 *
 * `appendix`/`answer-key`/`index` 等 kind 的章节其 `sections` 可为 `[]`（合法态，区别于「章节损坏」）。
 * 此时不渲染讲解正文流，改用本视图展示该章可用内容（答案条目/索引项或「本章为附录，无讲解小节」提示），
 * 不空指针/白屏。按 kind 给出贴切提示文案，所有文本走资源键（CLAUDE.md §5）。
 */
import { ChapterKind } from '../../domain/entities/content';
import { LessonTokens } from './LessonTokens';

@Component
export struct ChapterEmptyView {
  /** 章节 kind（决定提示文案）。 */
  @Prop kind: ChapterKind;

  /**
   * 按 kind 选取空态提示资源键（R-034「展示该章可用内容或『本章为附录，无讲解小节』提示」）。
   * @returns 提示文案资源引用。
   */
  private hintResource(): Resource {
    if (this.kind === 'answer-key') {
      return $r('app.string.lesson_empty_answer_key');
    }
    if (this.kind === 'index') {
      return $r('app.string.lesson_empty_index');
    }
    // appendix 及其它无小节情形统一走附录提示
    return $r('app.string.lesson_empty_appendix');
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.lesson_empty_title'))
        .fontSize(LessonTokens.FONT_HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(LessonTokens.INK)
      Text(this.hintResource())
        .fontSize(LessonTokens.FONT_BODY)
        .fontColor(LessonTokens.INK_SECONDARY)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(LessonTokens.PAGE_PADDING)
  }
}
