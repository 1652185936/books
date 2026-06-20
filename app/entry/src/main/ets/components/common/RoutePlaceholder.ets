/**
 * 通用「页面占位」内容组件。用于 P0-6 路由骨架阶段各页面的占位展示，
 * 后续各 F-页面落地时以真实页面替换。所有文字取自资源文件（CLAUDE.md §5），不在页面散落硬编码。
 */
@Component
export struct RoutePlaceholder {
  /** 页面标题（资源引用）。 */
  @Prop title: ResourceStr;
  /** 占位说明文案（资源引用），缺省用通用「建设中」提示。 */
  @Prop hint: ResourceStr = $r('app.string.route_placeholder_hint');

  build() {
    Column({ space: 12 }) {
      Text(this.title)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
      Text(this.hint)
        .fontSize(15)
        .fontColor('#888888')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
