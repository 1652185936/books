import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F03 校验页路由构建函数（route_map.json → `import/validate`，LLD §6.3）。
 * 参数 `jobId`（ImportValidateParams）在 F03 经 NavDestination.onReady 取 `ctx.pathInfo.param` 解析。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function ImportValidatePageBuilder(): void {
  ImportValidatePage();
}

/**
 * P-F03 校验页（路由 `import/validate/{jobId}`，LLD §6.3）。
 * P0-6 路由骨架占位；真实校验进度流/报告/回滚（ValidationStageGrid/ValidationSummary/ReportDialog）在 F03 落地。
 */
@Component
export struct ImportValidatePage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_import_validate') })
    }
    .title($r('app.string.route_title_import_validate'))
  }
}
