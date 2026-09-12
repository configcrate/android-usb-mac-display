# macOS 虚拟显示器：实验边界

默认 ScreenCaptureKit 采集已有主屏，仅镜像。真正扩展屏使用 `--backend virtual`，通过有明确方法签名的 Objective-C 桥接层创建私有 CGVirtualDisplay，并交给 ScreenCaptureKit 采集。

私有 API 没有兼容承诺；不能据类存在或 CI 构建通过宣称该 Mac 已支持。失败会明确报错，不会自动切回镜像。使用者需到系统设置→显示器确认扩展布局，触摸按当前显示器全局坐标换算。

本项目目前不安装驱动，不要求 DriverKit。早期“DriverKit 官方虚拟显示驱动/长期稳定”的建议未经验证，已撤回；不能仅凭 DriverKit 存在就承诺可实现受支持的虚拟显示器。

先按 [真机清单](TESTING.zh-CN.md) 验证镜像，再验证扩展桌面。正式分发的签名、公证、许可证与私有 API 使用限制需要单独评估。
