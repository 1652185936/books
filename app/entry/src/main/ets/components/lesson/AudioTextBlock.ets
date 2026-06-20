/**
 * audio-text 内容块渲染组件（F05，LLD §6.5；D5 新增项）。
 *
 * payload 形状：`{ text|transcript, audio? }`；plainText 取文本字段（《06》§3.2）。第一版以文本转写为主，
 * 音频播放列入后续迭代——音频资源缺失（`block.assetUri` 缺）时不阻断文本展示（资源缺失态局部降级）。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct AudioTextBlock {
  /** 待渲染的 audio-text 内容块。 */
  @Prop block: ContentBlock;
  /** 是否有可用音频资源（页面注入；第一版仅据此显示「音频后续支持」占位徽标）。 */
  @Prop hasAudio: boolean = false;

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        // 音频徽标（第一版占位：播放交互列入后续迭代）
        Text($r('app.string.lesson_audio_badge'))
          .fontSize(LessonTokens.FONT_CAPTION)
          .fontColor(this.hasAudio ? LessonTokens.BRAND_RED : LessonTokens.INK_MUTED)
          .padding({ top: 2, bottom: 2, left: 8, right: 8 })
          .border({ width: 1, color: this.hasAudio ? LessonTokens.BRAND_RED : LessonTokens.BORDER })
          .borderRadius(12)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)

      // 转写文本（音频缺失也保留文本，不白屏）
      Text(BlockPayload.strFirst(this.block.payload, ['text', 'transcript'], this.block.plainText))
        .fontSize(LessonTokens.FONT_BODY)
        .fontColor(LessonTokens.INK)
        .lineHeight(LessonTokens.FONT_BODY + 10)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(LessonTokens.SURFACE)
    .borderRadius(8)
  }
}
