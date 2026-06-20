/**
 * example-list 内容块渲染组件（F05，LLD §6.5）。
 * payload 形状：`{ examples: [{ english, chinese }] }`；plainText 为各样例顺序拼接（《06》§3.2）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload, ExamplePair } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct ExampleList {
  /** 待渲染的 example-list 内容块。 */
  @Prop block: ContentBlock;

  build() {
    Column({ space: 10 }) {
      ForEach(BlockPayload.exampleList(this.block.payload), (pair: ExamplePair, index: number) => {
        Row({ space: 10 }) {
          // 序号点
          Text(`${index + 1}`)
            .fontSize(LessonTokens.FONT_CAPTION)
            .fontColor(LessonTokens.BRAND_RED)
            .width(20)
          Column({ space: 4 }) {
            Text(pair.english)
              .fontSize(LessonTokens.FONT_BODY)
              .fontColor(LessonTokens.INK)
              .width('100%')
            Text(pair.chinese)
              .fontSize(LessonTokens.FONT_CAPTION + 1)
              .fontColor(LessonTokens.INK_SECONDARY)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (pair: ExamplePair, index: number) => `${index}-${pair.english}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
