import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

// 日志域与标签（CLAUDE.md §5：禁止输出完整正文/笔迹/敏感路径，仅记录生命周期）
const DOMAIN: number = 0x0001;
const TAG: string = 'EntryAbility';

/**
 * 应用入口 UIAbility。负责加载主窗口内容（书架页将在 F01 接管 pages/Index）。
 */
export default class EntryAbility extends UIAbility {
  /**
   * Ability 创建回调。
   * @param want 拉起参数
   * @param launchParam 启动参数
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
  }

  /**
   * Ability 销毁回调。
   */
  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  /**
   * 窗口舞台创建：加载首屏页面内容。
   * @param windowStage 窗口舞台
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed, code: %{public}d', err.code);
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  /**
   * 窗口舞台销毁回调。
   */
  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  /**
   * 切换到前台回调。
   */
  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  /**
   * 切换到后台回调。
   */
  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
