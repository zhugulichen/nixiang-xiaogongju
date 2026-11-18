# 清舟

清舟 1.8.1 是一款独立实现的中文苹果电脑应用管理工具，支持应用卸载、残留检查、缓存清理和设置重置。退出主窗口后可在菜单栏运行，应用被拖入废纸篓时可提醒检查关联文件。

## 功能

- 单个和批量卸载，确认后将所选项目移入废纸篓。可从清理记录逐项或整批恢复。
- 查看扫描位置、权限受限目录、安装收据及后台组件。下载文件夹中的安装器和未挂载的磁盘映像可单独核对与回收。
- 管理当前用户的启动代理，查询浏览器扩展、检查应用版本与兼容性，设置常用文件类型的默认打开方式。
- 查看开发者声明的隐私用途。苹果电脑系统 27 及以后，实际权限由系统设置查看和调整，清舟提供对应入口。

系统组件、仍被其他应用使用的共享数据和已挂载的磁盘映像会受到保护。整机后台组件可在清舟中核对，并通过系统设置或开发者卸载程序管理。

## 构建与测试

需要苹果芯片电脑、系统版本 14 或更高，以及可编译本项目的苹果命令行开发工具。从本合集根目录执行：

```sh
cd qingzhou
bash scripts/test.sh
bash scripts/build-app.sh
```

构建后的安装压缩包位于 `dist/清舟.zip`。解压后将清舟拖到“应用程序”。如果正在运行旧版，先从菜单栏退出。也可从项目目录运行 `bash scripts/install-app.sh` 来安装并校验签名。

如已配置本机签名身份，构建会使用该身份；新机器默认使用本机临时签名。是否启用扫描相关授权由当前电脑决定。

## 废纸篓验收

下列命令用自建应用、缓存、用户脚本、安装器和磁盘映像验证回收、单项恢复及整批恢复：

```sh
swiftc Sources/CleanCore/Models.swift \
  Sources/CleanCore/ApplicationGroupService.swift Sources/CleanCore/Scanner.swift \
  Sources/CleanCore/ApplicationProtection.swift Sources/CleanCore/SystemServices.swift \
  Sources/CleanCore/InstallerFiles.swift Sources/CleanCore/TrashService.swift \
  scripts/acceptance.swift -o /tmp/qingzhou-acceptance
/tmp/qingzhou-acceptance
```
