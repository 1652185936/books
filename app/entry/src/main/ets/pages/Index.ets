import { BookshelfPage } from './bookshelf/BookshelfPage';

/**
 * 应用首屏：Navigation 容器根页（LLD §1.1「导航：Navigation」、§6 页面路由骨架）。
 *
 * 维护全局 `NavPathStack`；Navigation 的根内容为书架页 P-F01（BookshelfPage），其余 P-F02..P-F12
 * 子页面经系统路由表 `route_map.json`（module.json5 `routerMap`）解析，由 `pushPathByName(RouteName.*, params)`
 * 入栈。各子页面在 NavDestination.onReady 经 `ctx.pathStack` 取得本栈用于继续跳转/返回；
 * 因此本骨架阶段不需向根内容下发栈实例，F01 接管书架交互时再按需以 `@Provide`/`@Consume` 暴露本栈。
 */
@Entry
@Component
struct Index {
  /** 全局导航栈：承载 P-F02..P-F12 的 NavDestination 路由（见 route_map.json）。 */
  private pageStack: NavPathStack = new NavPathStack();

  build() {
    Navigation(this.pageStack) {
      BookshelfPage()
    }
    // 顶层路由以整页栈式切换；书架页自带头部，隐藏 Navigation 默认标题栏
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .width('100%')
    .height('100%')
  }
}
