/**
 * 书架占位状态视图（F01）：统一渲染 loading / empty / error 三态的居中提示，
 * 区别于 content 态的书卡栅格。所有文案取自资源（CLAUDE.md §5）。
 *
 * - loading：转圈 + 「加载中…」
 * - empty：空书架引导 + 「导入学习包」主操作
 * - error：错误文案（按 messageKey 资源引用）+ 「重试」
 */
@Component
export struct BookshelfStateView {
  /** 状态类型：loading / empty / error。 */
  @Prop kind: 'loading' | 'empty' | 'error';
  /** error 态的文案资源引用（由调用方按 AppError.messageKey 解析后传入）。 */
  @Prop errorText: ResourceStr = $r('app.string.state_error');
  /** empty 态「导入学习包」点击回调。 */
  onImport?: () => void;
  /** error 态「重试」点击回调。 */
  onRetry?: () => void;

  build() {
    Column({ space: 16 }) {
      if (this.kind === 'loading') {
        // 加载态：转圈 + 加载文案
        LoadingProgress()
          .width(48)
          .height(48)
          .color('#C0392B')
        Text($r('app.string.state_loading'))
          .fontSize(15)
          .fontColor('#6B7280')
      } else if (this.kind === 'empty') {
        // 空书架态：引导文案 + 导入主操作
        Text($r('app.string.bookshelf_empty_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#374151')
        Text($r('app.string.bookshelf_empty_hint'))
          .fontSize(14)
          .fontColor('#6B7280')
          .textAlign(TextAlign.Center)
        Button($r('app.string.bookshelf_import'))
          .height(56)
          .padding({ left: 24, right: 24 })
          .backgroundColor('#C0392B')
          .onClick((): void => {
            if (this.onImport !== undefined) {
              this.onImport()
            }
          })
      } else {
        // 错误态：错误文案 + 重试
        Text(this.errorText)
          .fontSize(15)
          .fontColor('#374151')
          .textAlign(TextAlign.Center)
        Button($r('app.string.action_retry'))
          .height(48)
          .padding({ left: 24, right: 24 })
          .backgroundColor('#C0392B')
          .onClick((): void => {
            if (this.onRetry !== undefined) {
              this.onRetry()
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(24)
  }
}
