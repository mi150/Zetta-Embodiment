# VLA 安装脚本分层重构设计

## 目标

将 `scripts/deployment/install_vla_env.sh` 重构为类似 RLinf
`requirements/install.sh` 的分层安装器：先处理宿主机系统依赖，再安装共享
Python 依赖，最后根据相互独立的 `--env` 和 `--model` 参数安装仿真环境与
模型后端。

本次重构删除 `--track`，允许环境与模型自由组合，并支持仅安装环境或仅安装
模型。

## 命令行接口

脚本支持以下参数：

```text
--env libero-pro|robocasa
--model openpi|gr00t
--no-system-deps
-h|--help
```

规则如下：

- `--env` 和 `--model` 各最多出现一次。
- 两者至少指定一个。
- 环境和模型可以自由组合，不限制为原来的两组固定 track。
- `--track` 被完全删除；传入该参数时作为未知参数失败。
- `--no-system-deps` 只跳过系统包安装，不跳过系统库检查。

支持的典型调用：

```bash
bash scripts/deployment/install_vla_env.sh --env libero-pro
bash scripts/deployment/install_vla_env.sh --model openpi
bash scripts/deployment/install_vla_env.sh --env libero-pro --model gr00t
bash scripts/deployment/install_vla_env.sh --env robocasa --model openpi
bash scripts/deployment/install_vla_env.sh --env robocasa --model gr00t --no-system-deps
```

## 安装阶段

脚本采用单文件函数化实现，执行顺序固定为：

1. 解析和校验参数。
2. 校验输入路径及所选组件需要的源码目录。
3. 安装或检查系统依赖。
4. 创建或验证 Python venv。
5. 安装共享 Python 依赖及 Zetta runtime。
6. 安装所选仿真环境。
7. 安装所选模型后端。
8. 应用仅在特定已安装组件存在时才需要的兼容修复。
9. 按实际安装组件执行验证和 smoke test。

日志使用阶段名称，不再使用与固定 track 绑定的 `N/9` 编号，避免可选阶段导致
编号失真。

## 系统依赖

默认行为是在 Ubuntu/Debian 主机上通过 `apt-get` 安装：

```text
build-essential
git
curl
ca-certificates
libegl1-mesa-dev
libgl1-mesa-dev
libglib2.0-0
```

如果当前用户不是 root，脚本使用 `sudo apt-get`；如果 `sudo` 不存在或不可用，
在执行任何 Python 安装前失败，并提示用户以 root 运行或使用
`--no-system-deps` 手工准备依赖。

指定 `--no-system-deps` 后：

- 不执行 `apt-get update` 或 `apt-get install`。
- 检查 `git` 和编译工具是否存在。
- 通过 `ldconfig` 或可移植的动态库探测检查 `libEGL.so.1`、`libGL.so.1`。
- 缺少必需项时打印明确警告及 Ubuntu 安装命令。此阶段不立即失败，后续只在
  所选环境需要 EGL smoke test 时因 preflight 失败而终止。

非 Debian 系统在默认模式下给出明确错误，要求用户使用 `--no-system-deps`
并自行安装等价依赖。

## Python 环境和共享依赖

`REPO_ROOT`、`VENV_ROOT` 和 `PYTHON_BIN` 继续使用环境变量提供。默认 Python
保持当前工作树选择的 `python3.11`，并同步修正脚本及文档中仍称默认值为
Python 3.10 的内容。

共享阶段负责：

- 创建 venv，或验证已有目录包含可执行的 `bin/python`。
- 升级 `pip`、`setuptools` 和 `wheel`。
- 安装 `mujoco==3.3.1`。
- editable 安装 `${REPO_ROOT}[ray]`。
- 安装环境和模型都需要的运行时包。

脚本在 venv 中记录本安装器选择的 env/model；再次运行时允许补装缺失组件，
但拒绝把 `libero-pro` 与 `robocasa` 同时安装到同一 venv，因为两者分别要求
robosuite 1.4 和 1.5，属于不可调和的代码级冲突。模型可以在不更换环境的
情况下补装或更换。

## 环境安装器

### LIBERO-Pro

`install_libero_pro_env`：

- 以 `--no-deps` 安装 `rpent-liberopro==0.1.1`，或安装
  `LIBEROPRO_PACKAGE` 指定的等价制品。
- 显式安装除 `rlinf-libero` 外的必要依赖。
- 固定 `numpy>=1.22,<2`、`opencv-python<4.12` 和
  `robosuite>=1.4,<1.5`。
- 验证 robosuite 为 1.4.x。
- 执行 16 个 perturbation suite 的注册、任务数、init state 和 BDDL language
  检查，防止通过 `LIBEROPRO_PACKAGE` 引入未修补的上游 0.1.0。
- 除非设置 `SKIP_ASSET_DOWNLOAD=1`，通过
  `liberopro-download-assets --skip-existing` 获取完整资产。
- 以 robosuite assets 为基础、LIBERO-Pro assets 为覆盖层构建 composite tree。
- 验证 Panda XML 与 LIBERO-Pro tabletop scene 均存在。

### RoboCasa

`install_robocasa_env`：

- 仅要求 `ROBOCASA_SRC_ROOT/robosuite` 和
  `ROBOCASA_SRC_ROOT/robocasa` 存在。
- 从源码 editable 安装 robosuite 1.5.2 和 robocasa 1.0.1。
- 验证实际安装版本及 `PandaOmron` API。

RoboCasa 环境安装不应因为没有 `Isaac-GR00T` 源码而失败；该目录只属于 GR00T
模型安装器。

## 模型安装器

### OpenPI

`install_openpi_model`：

- 安装 `rlinf-openpi==0.1.1` 及完整依赖。
- 允许的 RLinf distributions 仅为 `rlinf-openpi` 和
  `rlinf-transformer-openpi`。
- 恢复 `mujoco==3.3.1`，并在 LIBERO-Pro 已安装时恢复 NumPy `<2`。
- 验证 `openpi` 以及 Zetta OpenPI factory 可导入。

### GR00T

`install_gr00t_model`：

- 仅要求 `ROBOCASA_SRC_ROOT/Isaac-GR00T` 存在；安装 GR00T 不要求同时安装
  RoboCasa 环境源码。
- editable 安装固定 ref 对应的 `gr00t==1.1.0`。
- 恢复 `mujoco==3.3.1`。
- 根据当前 torch、CUDA、Python 和 C++ ABI 安装 flash-attn 2.8.3。
- 默认 wheel 名中的 torch 标记只使用主次版本，例如 `torch2.7`，而不是
  `torch2.7.1`。
- 支持 `FLASH_ATTN_WHEEL` 覆盖默认 wheel。
- 强制恢复 genuine `transformers==4.51.3` 文件。

## 组合兼容处理

兼容逻辑根据已安装组件判断，而不是根据固定 track 判断：

- `pydantic==2.10.6` 在需要 numpydantic/GR00T 兼容时最后固定并验证。
- 只有同时安装 RoboCasa 和 GR00T 时，才安装 editable finder 优先级 `.pth`
  修复。
- 只有安装 LIBERO-Pro 时，才下载/合并其资产并运行 LIBERO 环境 reset。
- 只有安装 RoboCasa 时，才运行 RoboCasa 环境 reset。
- 环境与不匹配模型的组合不被安装器提前拒绝；最终验证分别确认各组件可导入。

由于 Zetta planner 依赖与 `pydantic==2.10.6` 存在已知元数据冲突，本次重构不把
`pip check` 的所有非零结果视为无条件失败。脚本应输出检查结果，并对已知冲突
与意外冲突做出区分；组件导入和版本断言仍必须失败即终止。

## 验证

静态测试覆盖：

- 不再接受或记录 `--track`。
- `--env`/`--model` 至少一个、不可重复、值域正确。
- `--no-system-deps` 存在。
- 系统依赖阶段先于 Python 依赖阶段。
- RoboCasa env 与 GR00T model 的源码目录检查解耦。
- 四种 env/model 组合均不被参数校验拒绝。
- LIBERO-Pro 安装路径包含 16-suite 校验。
- RLinf allowlist 保持两个精确包名。
- flash-attn URL 使用 torch 主次版本。

运行验证包括：

```bash
bash -n scripts/deployment/install_vla_env.sh
python -m pytest tests/test_vla_installer_contract.py -q
python -m pytest tests/test_repository_hygiene.py -q
```

完整 GPU、网络和 apt 安装不在单元测试中执行；真实安装仍由现有环境 reset smoke
和模型 import smoke 负责。

## 文档迁移

同步更新：

- `scripts/deployment/VLA_ENV_SETUP.md`
- `robots/libero/guides/pro_hybrid_guide.md`
- `README.md` 中的安装命令

删除所有 `--track` 示例，改为 `--env`/`--model`，并记录默认系统包安装行为及
`--no-system-deps` 的含义。
