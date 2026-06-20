/**
 * 未支持内容块兜底组件（F05，R-036 / LLD §3.6 / §6.5）。
 *
 * 内容块 `type` 不在协议 §5.2 的 11 种渲染白名单内时，显示「暂不支持的内容块」占位而**非崩溃**，
 * 不静默丢弃、不白屏。降级展示 plainText（若有），保证无障碍朗读仍可读到派生文本。
 */
import { ContentBlock } from '../../domain/entities/content';
import { LessonTokens } from './LessonTokens';

@Component
export struct UnsupportedBlock {
  /** 未支持的内容块。 */
  @Prop block: ContentBlock;

  build() {
    Column({ space: 6 }) {
      Text($r('app.string.lesson_block_unsupported'))
        .fontSize(LessonTokens.FONT_CAPTION + 1)
        .fontColor(LessonTokens.WARN_AMBER)
        .width('100%')
      // 降级展示派生纯文本（若有），保留可读内容
      if (this.block.plainText.length > 0) {
        Text(this.block.plainText)
          .fontSize(LessonTokens.FONT_CAPTION)
          .fontColor(LessonTokens.INK_MUTED)
          .width('100%')
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(LessonTokens.SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LessonTokens.BORDER })
  }
}
