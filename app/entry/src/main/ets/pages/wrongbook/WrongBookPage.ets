import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F10 错题本页路由构建函数（route_map.json → `wrongbook`，LLD §6.10）。
 * 参数 `bookId?`（WrongBookParams）在 F10 经 NavDestination.onReady 解析；缺省 = 全部书籍聚合（§6.13）。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function WrongBookPageBuilder(): void {
  WrongBookPage();
}

/**
 * P-F10 错题本页（路由 `wrongbook?bookId={optional}`，LLD §6.10）。
 * P0-6 路由骨架占位；真实错题（WrongFilterPanel/WrongItemList/WrongDetail）在 F10 落地。
 */
@Component
export struct WrongBookPage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_wrongbook') })
    }
    .title($r('app.string.route_title_wrongbook'))
  }
}
