# add/ — xPON 内核驱动的上游源码（git submodules）

此目录下的两个 submodule 为 `kmod-airoha-xpon-en757x` 提供必需的
Airoha SDK 源码，均钉在已验证的 commit 上：

| submodule | 上游 | 钉住的 commit | 提供内容 |
|---|---|---|---|
| `airoha-collection-main` | [Yuzhii0718/airoha-collection](https://github.com/Yuzhii0718/airoha-collection)（main） | `d9454f2b13fe` | `airoha-pon/src`：BSP + GPON/EPON/XSPON MAC 驱动（6.18 移植） |
| `airoha_sdk` | [naoki66/airoha_sdk](https://github.com/naoki66/airoha_sdk) | `32b5aa356c24` | `private/lddla`：EN7572 LDDLA 光模块固件源码 |

## 首次克隆后初始化

```sh
git submodule update --init --recursive --depth 1
```

（若需 airoha_sdk 完整内容可去掉 --depth 1；构建只用 private/lddla。）

submodule 更新后如需跟随上游新版本：

```sh
git -C add/airoha-collection-main fetch origin main
git -C add/airoha-collection-main checkout <新 commit>
git add add/airoha-collection-main && git commit
```

## 注意

- 缺少这两个源码树时，`kmod-airoha-xpon-en757x` 构建会明确报错
  （`Missing .../src` / `Missing .../private/lddla`）；其他包不受影响。
- 顶层 `.gitignore` 原先忽略整个 `/add` 的规则已随 submodule 化移除。
