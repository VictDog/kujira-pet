# Kujira 1.0.0 · 首个公开发布

把那只蓝发鲸鱼娘放到你的 macOS 桌面上：下载、解压、双击。不装任何运行时。

## 下载

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `Kujira-1.0.0-macOS-universal.zip` | 93 MB | Apple Silicon + Intel 通用二进制，macOS 13 Ventura 及以上 |

SHA-256：

```
d6e232499f33cf36a2cdf9c3a1f6497e2543d72e3d8da177142752b9ec8578ff
```

## 安装

1. 解压得到 `Kujira 桌宠.app`，拖进「应用程序」文件夹。
2. 首次打开会被 Gatekeeper 拦下——这是本地 ad-hoc 签名的正常现象，不是文件损坏：

   - 右键点 App 图标 → **打开** → 再点一次「打开」；
   - 或者一次性去掉隔离标记：

     ```bash
     xattr -dr com.apple.quarantine "/Applications/Kujira 桌宠.app"
     ```

3. 它会落在屏幕右下角，状态栏出现一个爪印图标，退出也从那里。

## 这一版有什么

- **109 段 DSH 小女仆动作 + 8 段柴犬动作**，全部 640×360、30 fps、带 alpha 通道的 HEVC
- **硬切不断帧**：两路 `AVPlayerLayer` A/B 双缓冲，新片段首帧解码完成才换面，实测约 20 ms
- **真透明**：直接解 HEVC with alpha，不是绿幕抠像，头发丝和裙摆边缘都干净
- **不挡鼠标**：只有身体那一块吃点击，其余穿透；非激活面板，不抢输入焦点
- **有物理**：拎起来会挣扎，松手按甩动速度抛出，重力下落、撞墙反弹、落地压扁回弹
- **会睡觉**：入睡过渡 → 睡姿循环 → 醒来过渡，完整三段，睡着时会拒绝你
- **皮肤热插拔**：右键换角色，不用重新编译、不用重启
- **自带皮肤工具链**：一段视频变成一个动作；一张立绘变成 21 段程序化动画

## 已知限制

- 没有 Apple 开发者证书，未做 Developer ID 签名与公证，所以会有 Gatekeeper 提示（下一步计划）
- 目前单实例单只，不能同时养两只
- 动画素材与角色形象为**非商业**授权，仅供个人使用，详见仓库里的 `LICENSE-ASSETS.md`

## 致谢

动画素材与动作编排规则来自 [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet)，
本版只重写了 macOS 侧的播放与交互实现。

宠物形象为社区二创的 DeepSeek「大肥鱼」（鲸鱼娘），**非 DeepSeek 官方形象**；
原型「溟月」出自 B 站 @上善无形，DeepSeek 版设计出自 B 站 @ZipZipPipe，形象遵循 CC BY-NC-SA 4.0。

---

## English

First public release of **Kujira**, a native macOS desktop pet ported from
[PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet). No Electron, no runtime, no third-party packages.

**Download** `Kujira-1.0.0-macOS-universal.zip` (93 MB, universal, macOS 13+), unzip, drag to Applications.
The app is ad-hoc signed, so the first launch needs right-click → Open.

Code is MIT. Animation assets and the character design are non-commercial (CC BY-NC-SA 4.0);
attribution to the upstream repository is required for any derivative work.
