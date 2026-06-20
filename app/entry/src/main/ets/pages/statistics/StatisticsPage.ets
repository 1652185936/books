import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F11 学习统计页路由构建函数（route_map.json → `statistics`，LLD §6.11）。
 * 参数 `bookId?/range?`（StatisticsParams）在 F11 经 NavDestination.onReady 解析；
 * `range` 缺省/非法回退 'week'，`bookId` 缺省 = 全部书籍聚合（§6.13）。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function StatisticsPageBuilder(): void {
  StatisticsPage();
}

/**
 * P-F11 学习统计页（路由 `statistics?bookId={optional}&range=week`，LLD §6.11）。
 * P0-6 路由骨架占位；真实统计（MetricCards/StudyBarChart/MasteryDonut/WeaknessList）在 F11 落地。
 */
@Component
export struct StatisticsPage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_statistics') })
    }
    .title($r('app.string.route_title_statistics'))
  }
}
