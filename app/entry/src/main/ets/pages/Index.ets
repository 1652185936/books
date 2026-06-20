/**
 * 应用首屏占位页。
 * 第一版正式书架页（FR-F01，LLD §6.1）将在后续迭代中接管此入口路由 pages/Index，
 * 届时改为 Navigation 容器根页。当前仅提供可被 hvigor 识别的最小可运行入口。
 */
@Entry
@Component
struct Index {
  // 应用标题（来自 AppScope 资源，禁止硬编码用户可见文本，CLAUDE.md §5）
  @State private title: Resource = $r('app.string.app_name');

  build() {
    Column({ space: 12 }) {
      Text(this.title)
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
      Text($r('app.string.index_ready_hint'))
        .fontSize(16)
        .fontColor('#666666')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
