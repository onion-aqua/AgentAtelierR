# 商店商品与生成资源

## 当前价格

| 商品 | 售价（关系点数） |
| --- | ---: |
| 给莱莎的礼物 | 50 |
| 高级精力剂 | 150 |
| 和好券 | 200 |
| IPhone 18 Pro Max | 499 |

IPhone 18 Pro Max 的描述为：

> 异世界最新的强劲工具，似乎对知识的搜集以及各种状态有增幅的效果

实际效果为 **心情 +100**，遵循现有心情上限 100。例如心情 -35 时使用后为 65，心情 35 时使用后为 100。购买时扣除点数并放入珍贵道具；使用时生效并消耗一件。商品与点数随存档和备份保存。点击商品图可查看名称、图片、描述与效果。

## 手机商品图

2026-10-06 按用户要求，将手机商品图替换为动漫道具插画。

- 文件：`assets/images/shop/iphone-18-pro-max.png`
- 模型：`gpt-image-2.5-sunburst`
- 请求尺寸：1K（1024 × 1024）
- 服务实际返回及资源尺寸：1254 × 1254
- 质量参数：`auto`
- 格式：带透明背景的 RGBA PNG
- 风格：深蓝线稿、平涂色块与赛璐璐阴影，银蓝手机正反面重叠双视角。
- 设计：去除苹果图形及品牌标志，保留顶部胶囊形灵动岛；比例、镜头点与高光采用动漫化细节，保持熟悉感。屏幕使用原创云浪图案。
- 后处理：将模型生成的灵动岛局部以柔和边缘合成回原插画，保留原图透明轮廓；已验证编辑区域外的像素一致，并检查浅色与深色商店背景。
- 公开范围：用户已允许该生成图片上传 GitHub，已加入 Git 忽略规则的允许列表。

资源沿用原路径，商品列表和详情均自动使用新图。商品图已替换，商品参数沿用原配置。

2026-10-06 根据用户补充要求，使用相同模型局部编辑补回灵动岛。请求参数为 1K、`quality=auto`，服务实际返回 1254 × 1254。输入为现有动漫插画，编辑遮罩覆盖前摄区域；原图备份及生成中间文件保存在忽略目录 `build/imagegen/shop-phone-island-20261006/`。本次实际使用的完整编辑提示词：

```text
Asset type: A transparent PNG anime game shop item illustration, localized edit of the supplied silver-blue smartphone artwork.
Primary request: Restore the familiar Dynamic Island at the top center of the front-facing phone on the RIGHT. Replace its small circular camera hole with a clearly visible dark navy-black horizontal rounded pill-shaped capsule, centered in the same place. The capsule should be about 100-108 pixels wide and 29-31 pixels tall in this 1254-pixel reference, roughly one quarter of the visible screen width. Follow the slight perspective of the screen top, gently slanting upward toward the right. Include a tiny muted blue camera lens near the capsule's right end and a restrained anime highlight.
Style: Preserve the existing Japanese 2D anime prop illustration with dark blue ink contours, clean flat colors and cel shading. Keep the recognizable capsule idea, while using subtly stylized proportions and hand-drawn details so it feels familiar but not like an exact real-product photograph.
Invariants: Change ONLY this front camera area. Preserve both phones, their overlapping rear-left/front-right composition, silver-blue palette, camera plateau and lenses on the rear phone, body silhouettes, framing, original blue-white cloud-and-wave screen wallpaper, clean transparent background, and all other artwork. The back must remain unbranded.
Avoid: Circular single-hole front camera, logos, Apple emblem, text, watermarks, photorealism, PBR reflections, extra phones, extra interface elements, unrelated redesigns, background panels or checkerboard patterns.
```
