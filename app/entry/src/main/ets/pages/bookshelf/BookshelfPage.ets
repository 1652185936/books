import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F01 书架页（Navigation 根内容，路由 `bookshelf`，LLD §6.1）。
 *
 * P0-6 路由骨架占位：作为 Navigation 的根内容（非 NavDestination）渲染；真实书架
 * （AppRail/BookGrid/BookCard/ImportButton/ImportToast）在 F01 落地接管。F01 接管时由本组件
 * 经 `@Consume` 取全局 NavPathStack 以驱动「导入/继续学习」等跳转。
 */
@Component
export struct BookshelfPage {
  build() {
    Column() {
      RoutePlaceholder({ title: $r('app.string.route_title_bookshelf') })
    }
    .width('100%')
    .height('100%')
  }
}
