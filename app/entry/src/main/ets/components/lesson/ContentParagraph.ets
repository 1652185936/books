/**
 * paragraph 内容块渲染组件（F05，LLD §6.5 内容块映射表）。
 * payload 形状：`{ text }`；缺 text 时回退 plainText（《06》§3.2）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct ContentParagraph {
  /** 待渲染的 paragraph 内容块。 */
  @Prop block: ContentBlock;

  build() {
    Text(BlockPayload.str(this.block.payload, 'text', this.block.plainText))
      .fontSize(LessonTokens.FONT_BODY)
      .fontColor(LessonTokens.INK)
      .lineHeight(LessonTokens.FONT_BODY + 10)
      .width('100%')
  }
}
