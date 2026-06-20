/**
 * 导入按钮（F01，LLD §6.1 ImportButton）。
 *
 * 书架主操作之一：点击进入 P-F02 `import/select`。内置「防重复点击」节流（CLAUDE.md §6 / LLD §6.2 防抖约定），
 * 在 `busy` 期间禁用，避免连点重复入栈。文案取自资源（CLAUDE.md §5），主操作高度 56vp（CLAUDE.md §6）。
 */
@Component
export struct ImportButton {
  /** 是否处于忙碌态（如已触发跳转/导入中），忙碌时禁用按钮防重复点击。 */
  @Prop busy: boolean = false;
  /** 点击回调（进入导入选择页）。 */
  onImport?: () => void;

  build() {
    Button($r('app.string.bookshelf_import'))
      .width('100%')
      .height(56)
      .backgroundColor('#C0392B')
      .enabled(!this.busy)
      .opacity(this.busy ? 0.6 : 1)
      .onClick((): void => {
        if (!this.busy && this.onImport !== undefined) {
          this.onImport()
        }
      })
  }
}
