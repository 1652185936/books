import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F02 导入选择页路由构建函数（route_map.json → `import/select`，LLD §6.2）。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function ImportSelectPageBuilder(): void {
  ImportSelectPage();
}

/**
 * P-F02 导入选择页（LLD §6.2）。
 * P0-6 路由骨架占位；真实选择/空间检查（ImportStepper/FilePickerCard/SelectedFileRow）在 F02 落地。
 */
@Component
export struct ImportSelectPage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_import_select') })
    }
    .title($r('app.string.route_title_import_select'))
  }
}
