/**
 * callout 内容块渲染组件（F05，LLD §6.5）。
 * payload 形状：`{ title, body|text, variant? }`；plainText 为 title+body（《06》§3.2）。
 * variant（note/tip/warning）决定强调色：warning 用琥珀，其余用品牌红左边条（§6 颜色语义）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct CalloutCard {
  /** 待渲染的 callout 内容块。 */
  @Prop block: ContentBlock;

  /**
   * 由 variant 取左边条强调色（warning→琥珀；其余→品牌红，§6 不滥用绿）。
   * @returns 强调色。
   */
  private accentColor(): string {
    // 提示类型
    const variant: string = BlockPayload.strFirst(this.block.payload, ['variant', 'kind', 'level'], 'note');
    return variant === 'warning' || variant === 'caution' ? LessonTokens.WARN_AMBER : LessonTokens.BRAND_RED;
  }

  build() {
    Row({ space: 0 }) {
      // 左侧强调边条
      Column()
        .width(4)
        .backgroundColor(this.accentColor())

      Column({ space: 6 }) {
        // 标题（可空时不占位）
        if (BlockPayload.str(this.block.payload, 'title', '').length > 0) {
          Text(BlockPayload.str(this.block.payload, 'title', ''))
            .fontSize(LessonTokens.FONT_BODY)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.accentColor())
            .width('100%')
        }
        Text(BlockPayload.strFirst(this.block.payload, ['body', 'text'], this.block.plainText))
          .fontSize(LessonTokens.FONT_BODY)
          .fontColor(LessonTokens.INK)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding(12)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor(LessonTokens.SURFACE)
    .borderRadius(8)
    .clip(true)
  }
}
