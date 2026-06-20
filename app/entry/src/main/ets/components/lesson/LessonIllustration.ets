/**
 * illustration 内容块渲染组件（F05，LLD §6.5）。
 *
 * payload 形状：`{ alt, caption? }`；图片来源为 `block.assetUri`（沙箱相对路径，仅授权/原创资源，
 * CLAUDE.md §2.10「不复制原书正文插图」）。`assetUri` 缺失（资源缺失态，LLD §6.5「资源缺失」状态）时
 * 不渲染图片，改用 alt 文本占位提示，不留空洞、不崩溃（R-036 配套）。
 *
 * 图片以沙箱 file:// 资源加载：本组件接收已解析的沙箱绝对/相对 URI 字符串（由页面经 ContentRepository
 * + 上下文 filesDir 拼装），缺图回退「资源缺失」占位。
 */
import { ContentBlock } from '../../domain/entities/content';
import { BlockPayload } from './BlockPayload';
import { LessonTokens } from './LessonTokens';

@Component
export struct LessonIllustration {
  /** 待渲染的 illustration 内容块。 */
  @Prop block: ContentBlock;
  /** 已解析为可加载形式的图片 URI（页面注入；缺图为空串→资源缺失态）。 */
  @Prop resolvedImageUri: string = '';

  build() {
    Column({ space: 8 }) {
      if (this.resolvedImageUri.length > 0) {
        // 授权/原创插图（缺图不走此分支）
        Image(this.resolvedImageUri)
          .alt(BlockPayload.str(this.block.payload, 'alt', ''))
          .objectFit(ImageFit.Contain)
          .width('100%')
          .constraintSize({ maxHeight: 420 })
          .borderRadius(8)
          .backgroundColor(LessonTokens.SURFACE)
      } else {
        // 资源缺失态：alt 文本占位，不白屏（LLD §6.5「资源缺失」状态）
        Column({ space: 6 }) {
          Text($r('app.string.lesson_asset_missing'))
            .fontSize(LessonTokens.FONT_CAPTION + 1)
            .fontColor(LessonTokens.WARN_AMBER)
          Text(BlockPayload.str(this.block.payload, 'alt', ''))
            .fontSize(LessonTokens.FONT_CAPTION)
            .fontColor(LessonTokens.INK_MUTED)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(LessonTokens.SURFACE)
        .borderRadius(8)
        .border({ width: 1, color: LessonTokens.BORDER })
      }
      // 图注（可空）
      if (BlockPayload.strFirst(this.block.payload, ['caption', 'alt'], '').length > 0) {
        Text(BlockPayload.strFirst(this.block.payload, ['caption', 'alt'], ''))
          .fontSize(LessonTokens.FONT_CAPTION)
          .fontColor(LessonTokens.INK_SECONDARY)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
