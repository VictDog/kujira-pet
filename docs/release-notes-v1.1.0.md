# Kujira 1.1.0 · 高冷猫，以及「皮肤能带性格」

新增第三套内置皮肤 **高冷猫**，并让每套皮肤拥有自己的台词与脾气。
从 1.0.0 覆盖安装即可，偏好、窗口位置、外置皮肤全部保留。

## 下载

| 文件 | 大小 | 说明 |
| --- | --- | --- |
| `Kujira-1.1.0-macOS-universal.zip` | 115 MB | Apple Silicon + Intel 通用二进制，macOS 13 Ventura 及以上 |

SHA-256：

```
55e40332c30ee130a96966f266dec49684c56c5611dbc8199b82ebb30f8f4fa7
```

## 安装

1. 解压得到 `Kujira 桌宠.app`，拖进「应用程序」文件夹。
2. 首次打开会被 Gatekeeper 拦下——这是本地 ad-hoc 签名的正常现象，不是文件损坏：

   - 右键点 App 图标 → **打开** → 再点一次「打开」；
   - 或者一次性去掉隔离标记：

     ```bash
     xattr -dr com.apple.quarantine "/Applications/Kujira 桌宠.app"
     ```

3. 右键桌宠 → **更换角色** → 「高冷猫」。

## 这一版新增

- **高冷猫皮肤（21 段动画）**：80% 的点击会被无视，1.8 秒内连点 3 次才炸毛，
  84% 的时间待机不动，偶尔突然蹦一下又装作没事。说话间隔拉长到 240–420 秒，
  台词是「……」「没空。」「别戳了。」；落地也更沉、不太弹。
- **皮肤可以带性格**：`catalog.json` 新增可选的 `personality`，可配台词表、说话间隔、
  点击忽略率、连点阈值与反应、忽略时说的话。不写就沿用默认设定，
  所以 DSH 与柴犬两个旧包一个字都不用改。
- **白底立绘一行命令变桌宠**：新增 `Tools/keyout.swift`，从画布四边泛洪抠掉纯色背景
  （白 / 绿 / 蓝），角色身上的浅色毛被描边隔开不会抠穿，角落的浅色水印会一起清掉。
  `new-character.sh` 检测到图片没有 alpha 通道时自动调用。
- 修掉 `new-character.sh` 在 `set -u` 下变量名紧挨全角引号导致的 `unbound variable`。
- 新增演示 GIF `docs/skin-aloof-cat.gif`，README 补上性格字段表与踩坑记录。

## 升级说明

- 直接覆盖 `Kujira 桌宠.app` 即可。`CFBundleIdentifier` 仍是 `local.dshpet.macos`，
  所以窗口位置、开关、已选角色都保留；外置皮肤目录 `~/Library/Application Support/DSH桌宠/characters/` 不动。
- 从源码构建：`./build.sh`，发版打包：`./Tools/release.sh 1.1.0`。

## 已知限制

- 没有 Apple 开发者证书，未做 Developer ID 签名与公证，所以会有 Gatekeeper 提示
- 目前单实例单只，不能同时养两只
- 程序化动画只做整体位移 / 缩放 / 旋转，挥手、吃东西这类肢体分层动作仍需视频素材
- 动画素材与角色形象为**非商业**授权，仅供个人使用，详见仓库里的 `LICENSE-ASSETS.md`

## 致谢

动画素材与动作编排规则来自 [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet)，
本项目只重写了 macOS 侧的播放与交互实现。

宠物形象为社区二创的 DeepSeek「大肥鱼」（鲸鱼娘），**非 DeepSeek 官方形象**；
原型「溟月」出自 B 站 @上善无形，DeepSeek 版设计出自 B 站 @ZipZipPipe，形象遵循 CC BY-NC-SA 4.0。
柴犬小柴与高冷猫为本项目自制的独立形象，同样禁止商用。

---

## English

**Kujira 1.1.0** adds a third built-in skin, the **aloof cat** (21 clips), and makes skins
personality-driven: an optional `personality` object in `catalog.json` controls dialogue lines,
chatter interval, click-ignore rate, pester threshold and physics feel. Older skins without it
keep the original behaviour. The cat ignores 80% of clicks and only gets annoyed after three
rapid ones.

Also included: `Tools/keyout.swift` (flood-fill keying for white/green/blue backdrops,
auto-invoked by `new-character.sh` when the illustration has no alpha), a `set -u` shell fix,
and a new demo GIF.

Download `Kujira-1.1.0-macOS-universal.zip` (115 MB, universal, macOS 13+), unzip, drag to
Applications. Ad-hoc signed, so the first launch needs right-click → Open. Code is MIT;
animation assets and character designs are non-commercial (CC BY-NC-SA 4.0) and require
attribution to the upstream repository.
