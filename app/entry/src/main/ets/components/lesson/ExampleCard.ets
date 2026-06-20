/**
 * example 内容块渲染组件（F05，LLD §6.5）。
 * payload 形状：`{ english, chinese }`；plainText 为 english+chinese（《06》§3.2）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload, ExamplePair } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct ExampleCard {
  /** 待渲染的 example 内容块。 */
  @Prop block: ContentBlock;

  build() {
    // 样例对（english + chinese）
    Column({ space: 6 }) {
      Text(BlockPayload.examplePair(this.block.payload).english)
        .fontSize(LessonTokens.FONT_BODY)
        .fontColor(LessonTokens.INK)
        .width('100%')
      Text(BlockPayload.examplePair(this.block.payload).chinese)
        .fontSize(LessonTokens.FONT_CAPTION + 1)
        .fontColor(LessonTokens.INK_SECONDARY)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(LessonTokens.SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LessonTokens.BORDER })
  }
}
