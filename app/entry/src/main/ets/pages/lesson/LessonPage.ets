import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F05 章节讲解页路由构建函数（route_map.json → `lesson`，LLD §6.5）。
 * 参数 `bookId/chapterId/section?`（LessonParams）在 F05 经 NavDestination.onReady 解析；
 * `section` 缺省进入 sections 下标 0 或恢复 last_section_id（R-034）。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function LessonPageBuilder(): void {
  LessonPage();
}

/**
 * P-F05 章节讲解页（路由 `lesson/{bookId}/{chapterId}?section={sectionId}`，LLD §6.5）。
 * P0-6 路由骨架占位；真实讲解（LessonHeader/LessonTabs/ContentBlockRenderer/ChapterDrawer）在 F05 落地。
 */
@Component
export struct LessonPage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_lesson') })
    }
    .title($r('app.string.route_title_lesson'))
  }
}
