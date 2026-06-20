import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F09 复习页路由构建函数（route_map.json → `review`，LLD §6.9）。
 * 参数 `bookId?`（ReviewParams）在 F09 经 NavDestination.onReady 解析；缺省 = 全部书籍聚合（§6.13）。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function ReviewPageBuilder(): void {
  ReviewPage();
}

/**
 * P-F09 复习页（路由 `review?bookId={optional}`，LLD §6.9）。
 * P0-6 路由骨架占位；真实复习（ReviewSessionHeader/FlashCard/RatingBar）在 F09 落地。
 */
@Component
export struct ReviewPage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_review') })
    }
    .title($r('app.string.route_title_review'))
  }
}
