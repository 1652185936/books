/**
 * 导入中提示条（F01，LLD §6.1 ImportToast / 状态「导入中」）。
 *
 * 当书架检测到有正在进行的导入任务时，于书架顶部悬浮一条非阻断提示，告知用户导入进行中并可点击查看进度。
 * 仅在 `visible` 为 true 时渲染；不阻断书架浏览。文案取自资源（CLAUDE.md §5）。
 */
@Component
export struct ImportToast {
  /** 是否可见（有进行中导入任务时为 true）。 */
  @Prop visible: boolean = false;
  /** 点击查看导入进度回调（进入 P-F03 校验页）。 */
  onView?: () => void;

  build() {
    if (this.visible) {
      Row({ space: 8 }) {
        // 进行中指示器
        LoadingProgress()
          .width(20)
          .height(20)
          .color('#C0392B')
        // 提示文案
        Text($r('app.string.bookshelf_importing'))
          .fontSize(14)
          .fontColor('#374151')
          .layoutWeight(1)
        // 查看进度入口
        Text($r('app.string.bookshelf_importing_view'))
          .fontSize(14)
          .fontColor('#C0392B')
          .onClick((): void => {
            if (this.onView !== undefined) {
              this.onView()
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#FBEAE8')
      .borderRadius(8)
      .alignItems(VerticalAlign.Center)
    }
  }
}
