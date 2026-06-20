import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F04 书籍目录页路由构建函数（route_map.json → `book`，LLD §6.4）。
 * 参数 `bookId`（CatalogParams）在 F04 经 NavDestination.onReady 取 `ctx.pathInfo.param` 解析。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function CatalogPageBuilder(): void {
  CatalogPage();
}

/**
 * P-F04 书籍目录页（路由 `book/{bookId}`，LLD §6.4）。
 * P0-6 路由骨架占位；真实目录（ChapterList/ChapterSearch/ChapterPreview）在 F04 落地。
 */
@Component
export struct CatalogPage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_catalog') })
    }
    .title($r('app.string.route_title_catalog'))
  }
}
