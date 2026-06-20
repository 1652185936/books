import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F06/P-F07 手写练习与识别判分页路由构建函数（route_map.json → `exercise`，LLD §6.6/§6.7）。
 * 参数 `bookId/chapterId/exerciseId/from?`（ExerciseParams）在 F06/F07 经 NavDestination.onReady 解析；
 * 判分页 P-F07 作为 P-F06 子状态沿用同一 `from`，不新增独立返回栈（§6.13）。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function ExercisePageBuilder(): void {
  ExercisePage();
}

/**
 * P-F06/P-F07 手写练习与识别判分页
 * （路由 `lesson/{bookId}/{chapterId}/exercise/{exerciseId}?from={chapter|wrongbook}`，LLD §6.6/§6.7）。
 * P0-6 路由骨架占位；真实作答/识别/判分（SegmentedPrompt/HandwritingBlank/PenToolbar/RecognitionProgress/GradeFeedback）在 F06/F07 落地。
 */
@Component
export struct ExercisePage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_exercise') })
    }
    .title($r('app.string.route_title_exercise'))
  }
}
