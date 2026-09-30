# Codex 图片背景（Windows）

这是一个独立、无第三方 npm 依赖的本地背景注入器。它不修改 Codex 安装包，只通过回环地址上的 Chromium 调试协议为 Codex 加载背景图。

- `background.png`：第一张背景图片（默认）
- `background-2.png`：第二张背景图片
- `background-3.png`：第三张背景图片
- `background.css`：透明度与可读性适配
- `start.ps1`：关闭现有 Codex，以本机调试端口重新打开，并从所有 `background*.png` 中随机选择背景
- `stop.ps1`：停止注入并恢复当前窗口的原生外观
- `injector.mjs`：仅使用 Node.js 内置 API 的注入器

以当前 Codex Electron 的 app-shell 界面为适配目标。即使调试接口在主窗口创建期间短暂重启，注入器也会继续等待，直到主界面挂载后再确认成功。面板只在最外层绘制一次半透明遮罩，避免多层背景叠加成纯黑。

26.924.1866 适配：清除插件、资料库等页面共用吸顶搜索页头的 `::before` 背景叠层；新版输入框通过 `data-composer-*` 属性恢复半透明背景与聚焦光效，补充 CSS Modules 顶部渐变层选择器，并跟进正文的 `--thread-content-expanded-max-width` 宽度变量。

皮肤会统一覆盖主聊天、固定与悬浮边栏、底部终端、右侧输出栏、站点、个人资料菜单和全部设置页面。终端、长文本卡片与弹层使用较深的半透明遮罩，在保留背景图的同时维持文字可读性。

Figma 内嵌界面也会沿用窗口背景和紫色强调色，背景裁切与主窗口对齐。注入器会为 Figma MCP 界面的独立网页框架同步样式和位置，重新打开、刷新或调整窗口大小后自动恢复覆盖。左侧图标悬浮展开的边栏使用不透明黑底，防止下层文字透出。

外观由 `background.css` 统一控制：浅色和深色模式都使用霓虹紫强调色、深紫黑背景、偏白前景与系统界面字体，无需手动配置 Codex 外观。皮肤只覆盖显示，不写入应用偏好；设置页的色值与字体选项仍表示原生配置，停止皮肤后恢复原生配置的显示效果。代码字体和字号继续使用应用设置。

收起固定左边栏后，聊天正文和输入区会利用释放出的横向空间；右侧输出栏打开时会自动保留安全间距，避免内容被浮层遮挡。

宠物使用 Codex 自带的透明悬浮窗口；注入器会跳过该辅助窗口，避免背景图片出现在宠物后方。

安装后从桌面或开始菜单的“Codex Picture Background”启动。每次启动都会从现有背景图片中随机选择一张。旧版创建的“Codex Picture Background 2”快捷方式也会被更新为随机启动。

启动窗口会短暂可见；脚本不绕过执行策略。皮肤启用期间会保留一个隐藏的 Node.js 监听进程，负责为后续打开的窗口、设置页和重新创建的页面同步背景；运行 `stop.ps1` 或再次启动皮肤时会回收它。直接点击原生 Codex 图标时不会带背景。

需要测试时仍可直接指定背景：

```powershell
.\start.ps1 -Background background-2.png
```

## 自定义与本地更新

下载新版后重新运行源文件夹中的 `install.ps1`，可用 `-Destination` 指定安装目录。更新保留已有同名背景、额外的 `background-N.png` 和 `user.css`，只补充缺失的默认背景；需要替换已有图片时请自行复制。`-NoShortcuts` 可跳过桌面和开始菜单快捷方式更新。

安装目录中的 `user.css` 是可选覆盖文件，会在基础样式之后加载。默认不需要创建它。所有主要颜色、遮罩和模糊参数位于 `background.css` 顶部；复制需要调整的变量到 `user.css`，例如：

```css
:root.codex-picture-background {
  --picture-violet: #9f78ff;
  --picture-output: rgb(18 16 29 / 60%);
  --picture-blur-sidebar: 10px;
  --picture-bubble-tail-space: 22px;
}
```

编辑后重新运行安装脚本，可向运行中的皮肤会话重新注入同版本样式，无需重启 Codex。未运行皮肤时，安装只更新文件，之后通过快捷方式启动。代码字体和字号仍由应用设置控制。

被替换的程序和基础 CSS 会保存在安装目录的 `backups/时间戳/`。旧版直接改在基础 CSS 内的自定义内容不会自动合并，请从备份迁移到 `user.css`。更新失败会恢复被替换文件；原会话可连接时尝试恢复旧皮肤和监听进程。结果及失败步骤记录在 `update.log`，恢复失败也会单独记录。

## 验证

运行 `node injector.mjs --self-test` 检查资源加载；运行 `tests/install.tests.ps1` 在临时目录验证安装、资源保留和失败回滚，不修改快捷方式。运行中注入验证使用现有 `--verify --port ... --browser-id ... --background ...`，连接信息位于安装目录的 `state.json`。
