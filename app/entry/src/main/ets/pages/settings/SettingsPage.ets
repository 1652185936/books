import { RoutePlaceholder } from '../../components/common/RoutePlaceholder';

/**
 * P-F12 设置与数据页路由构建函数（route_map.json → `settings`，LLD §6.12）。
 * 参数 `section?`（SettingsParams）在 F12 经 NavDestination.onReady 解析；缺省进入默认分区。
 * @returns 无（构建占位 NavDestination）
 */
@Builder
export function SettingsPageBuilder(): void {
  SettingsPage();
}

/**
 * P-F12 设置与数据页（路由 `settings/{section}`，LLD §6.12）。
 * P0-6 路由骨架占位；真实设置（SettingsNav/SettingRow/StorageSummary/DangerZone）在 F12 落地。
 */
@Component
export struct SettingsPage {
  build() {
    NavDestination() {
      RoutePlaceholder({ title: $r('app.string.route_title_settings') })
    }
    .title($r('app.string.route_title_settings'))
  }
}
