# 设置页液态玻璃性能修复

## 撤回与替换

用户报告 1.0.4.3 开启液态玻璃后设置页卡顿。构建 54 已从 GitHub Release 隐藏，自托管 APK 移至非公开隔离目录。stable 使用更高序号 58 发布无 APK 的暂停清单，避免回退序号被客户端防回放逻辑拒绝。两端代码镜像同步撤回指针。

替换版本保留 1.0.4.3，Android 构建号递增为 55，stable 序号为 59；覆盖更新保留存档。

## 代码中定位的开销

- 虚拟手机设置路由已使用 sigma 24 的背景模糊，设置页又创建全屏的 blur + fragment shader 组合，重复读取、过滤背景。
- 每个玻璃表面监听 pointer move 并 setState，流光 AnimationController 通过 AnimatedBuilder 重建 BackdropFilter，滚动触摸触发持续滤镜更新。
- 全屏零圆角表面仍申请折射 shader，但它不需要圆角边缘的透镜效果。

## 修复

- 引入 GlassBackdropScope，标记上层已处理的背景，卡片复用背景，只绘制色调和光泽。
- 手机设置背景标记为跨路由保留；设置详情页继承此能力，避免页面切换时再次叠加滤镜。普通独立设置页仍能保留自己的背景。
- 零圆角整页不加载、不运行折射 shader；独立圆角玻璃仍保留静态边缘折射。
- 触摸流光由 CustomPainter 的 repaint 监听驱动，放在独立 RepaintBoundary 中；不再使用 pointer move/setState 和 AnimatedBuilder 重建滤镜。触摸落点触发短暂流光，拖动列表不会逐帧改变背景 shader 参数。
- 保持控件树稳定，切换效果不丢失输入草稿、选择区与焦点。

## 验证边界

47 项针对玻璃、设置、人格编辑器的测试通过。新增测试核验嵌套卡片只有一次背景过滤，12 个连续流光帧复用同一批 BackdropFilter widget/filter，设置详情页复用已有背景；已有像素测试检查文字对比度和浅色显示。

本轮 ADB 未连接设备，未取得用户手机的 GPU/frame timing 数据，因此上述是实现路径和自动化渲染验证，不宣称真机帧率已经实测。全量回归和最终包审计结果保存在 build/release-build55-* 日志中。
