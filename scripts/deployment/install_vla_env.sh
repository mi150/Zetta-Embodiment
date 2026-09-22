#!/usr/bin/env bash
# Layered VLA installer: host dependencies -> common Python -> env -> model.
set -euo pipefail

SELECTED_ENV=""
SELECTED_MODEL=""
NO_SYSTEM_DEPS=0
USE_MIRROR=0
REPO_ROOT="${REPO_ROOT:-}"
VENV_ROOT="${VENV_ROOT:-}"
UV_BIN="${UV_BIN:-uv}"
UV_PYTHON_VERSION="${UV_PYTHON_VERSION:-3.11}"
UV_CACHE_DIR="${UV_CACHE_DIR:-}"
UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-}"
GITHUB_PREFIX="${GITHUB_PREFIX:-}"
ROBOCASA_SRC_ROOT="${ROBOCASA_SRC_ROOT:-}"
FLASH_ATTN_WHEEL="${FLASH_ATTN_WHEEL:-}"
LIBEROPRO_PACKAGE="${LIBEROPRO_PACKAGE:-rpent-liberopro==0.1.1}"
SKIP_ASSET_DOWNLOAD="${SKIP_ASSET_DOWNLOAD:-0}"
LIBERO_CONFIG_PATH="${LIBERO_CONFIG_PATH:-}"
PY=""

log() { printf '\n=== %s ===\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install_vla_env.sh [--env ENV] [--model MODEL] [--no-system-deps] [--use-mirror]

Install at least one independently selectable component:
  --env libero-pro|robocasa
  --model openpi|gr00t

Options:
  --no-system-deps  Skip apt-get; check host dependencies and warn instead.
  --use-mirror      Use the RLinf-compatible Aliyun/HF/GitHub proxy mirrors.
  -h, --help        Show this help.

Required variables: REPO_ROOT, VENV_ROOT
Optional variables: UV_BIN, UV_PYTHON_VERSION, UV_CACHE_DIR,
                    UV_PYTHON_INSTALL_DIR, ROBOCASA_SRC_ROOT, LIBEROPRO_PACKAGE,
                    FLASH_ATTN_WHEEL, LIBERO_PRO_ASSET_PATH,
                    LIBERO_COMPOSITE_ASSETS_DIR, SKIP_ASSET_DOWNLOAD
EOF
}

parse_args() {
  SELECTED_ENV=""; SELECTED_MODEL=""; NO_SYSTEM_DEPS=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env)
        [ -z "$SELECTED_ENV" ] || die "--env may only be specified once"
        [ "$#" -ge 2 ] || die "--env requires a value"
        SELECTED_ENV="$2"; shift 2 ;;
      --env=*)
        [ -z "$SELECTED_ENV" ] || die "--env may only be specified once"
        SELECTED_ENV="${1#--env=}"; shift ;;
      --model)
        [ -z "$SELECTED_MODEL" ] || die "--model may only be specified once"
        [ "$#" -ge 2 ] || die "--model requires a value"
        SELECTED_MODEL="$2"; shift 2 ;;
      --model=*)
        [ -z "$SELECTED_MODEL" ] || die "--model may only be specified once"
        SELECTED_MODEL="${1#--model=}"; shift ;;
      --no-system-deps) NO_SYSTEM_DEPS=1; shift ;;
      --use-mirror) USE_MIRROR=1; shift ;;
      -h|--help) usage; return 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$SELECTED_ENV" ] || [ -n "$SELECTED_MODEL" ] || \
    die "at least one of --env or --model must be specified"
  case "$SELECTED_ENV" in ""|libero-pro|robocasa) ;; *) die "unsupported environment: $SELECTED_ENV" ;; esac
  case "$SELECTED_MODEL" in ""|openpi|gr00t) ;; *) die "unsupported model: $SELECTED_MODEL" ;; esac
}

require_source_directory() {
  [ -n "$ROBOCASA_SRC_ROOT" ] || die "$1 requires ROBOCASA_SRC_ROOT"
  [ -d "$ROBOCASA_SRC_ROOT/$1" ] || die "ROBOCASA_SRC_ROOT ($ROBOCASA_SRC_ROOT) is missing $1/"
}

validate_inputs() {
  [ -n "$REPO_ROOT" ] || die "set REPO_ROOT to the Zetta-Embodiment checkout"
  [ -f "$REPO_ROOT/pyproject.toml" ] || die "REPO_ROOT ($REPO_ROOT) does not contain pyproject.toml"
  [ -n "$VENV_ROOT" ] || die "set VENV_ROOT to the target virtual environment"
  command -v "$UV_BIN" >/dev/null || die "uv was not found (set UV_BIN to its executable)"
  if [ "$SELECTED_ENV" = robocasa ]; then require_source_directory robosuite; require_source_directory robocasa; fi
  if [ "$SELECTED_MODEL" = gr00t ]; then require_source_directory Isaac-GR00T; fi
}

install_apt_packages() {
  local apt=(apt-get)
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || die "system dependency installation needs root or sudo; use --no-system-deps after installing them manually"
    apt=(sudo apt-get)
  fi
  [ -r /etc/os-release ] || die "cannot detect the host distribution"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-} ${ID_LIKE:-}" in *debian*|*ubuntu*) ;; *) die "automatic system dependency installation supports Debian/Ubuntu only; use --no-system-deps" ;; esac
  "${apt[@]}" update
  "${apt[@]}" install -y --no-install-recommends build-essential git curl ca-certificates ffmpeg libegl1-mesa-dev libgl1-mesa-dev libglib2.0-0
}

has_shared_library() {
  local library="$1"
  command -v ldconfig >/dev/null && ldconfig -p 2>/dev/null | grep -F "$library" >/dev/null
}

check_system_dependencies() {
  local mode="$1" missing=()
  command -v git >/dev/null || missing+=(git)
  command -v gcc >/dev/null || missing+=(build-essential)
  command -v ffmpeg >/dev/null || missing+=(ffmpeg)
  has_shared_library libEGL.so.1 || missing+=(libegl1-mesa-dev)
  has_shared_library libGL.so.1 || missing+=(libgl1-mesa-dev)
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing system dependencies: ${missing[*]}" >&2
    echo "Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y ${missing[*]}" >&2
    [ "$mode" != strict ] || return 1
    echo "Warning: --no-system-deps was used; an environment smoke test may fail." >&2
  fi
  command -v nvidia-smi >/dev/null || echo "Warning: nvidia-smi is unavailable; GPU inference may fail." >&2
}

prepare_system_dependencies() {
  log "System dependencies"
  if [ "$NO_SYSTEM_DEPS" -eq 0 ]; then install_apt_packages; check_system_dependencies strict
  else check_system_dependencies warn; fi
}

state_file() { printf '%s/.zetta-vla-components' "$VENV_ROOT"; }
read_installed_environment() { [ -f "$(state_file)" ] && awk -F= '$1=="env" {print $2}' "$(state_file)" || true; }
read_installed_model() { [ -f "$(state_file)" ] && awk -F= '$1=="model" {print $2}' "$(state_file)" || true; }
effective_environment() {
  if [ -n "$SELECTED_ENV" ]; then printf '%s\n' "$SELECTED_ENV"; else read_installed_environment; fi
}
effective_model() {
  if [ -n "$SELECTED_MODEL" ]; then printf '%s\n' "$SELECTED_MODEL"; else read_installed_model; fi
}

configure_uv() {
  UV_CACHE_DIR="${UV_CACHE_DIR:-$REPO_ROOT/.uv-cache}"
  UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$REPO_ROOT/.uv-python}"
  export UV_CACHE_DIR UV_PYTHON_INSTALL_DIR
  mkdir -p "$UV_CACHE_DIR" "$UV_PYTHON_INSTALL_DIR"
}

setup_mirror() {
  [ "$USE_MIRROR" -eq 1 ] || return 0
  export UV_DEFAULT_INDEX="${UV_DEFAULT_INDEX:-https://mirrors.aliyun.com/pypi/simple}"
  export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
  export GITHUB_PREFIX="${GITHUB_PREFIX:-https://gh-proxy.com/}"
  export UV_PYTHON_INSTALL_MIRROR="${UV_PYTHON_INSTALL_MIRROR:-${GITHUB_PREFIX}https://github.com/astral-sh/python-build-standalone/releases/download}"
  local idx="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_${idx}=url.${GITHUB_PREFIX}github.com/.insteadOf"
  export "GIT_CONFIG_VALUE_${idx}=https://github.com/"
  export GIT_CONFIG_COUNT=$((idx + 1))
}

run_uv() { "$UV_BIN" "$@"; }
uv_pip_install() { run_uv pip install --python "$PY" "$@"; }

validate_existing_venv() {
  local installed_env=""
  if [ -e "$VENV_ROOT" ] && [ ! -x "$VENV_ROOT/bin/python" ]; then die "VENV_ROOT exists but is not a usable virtual environment: $VENV_ROOT"; fi
  if [ -x "$VENV_ROOT/bin/python" ]; then
    [ -f "$VENV_ROOT/pyvenv.cfg" ] && grep -Eq '^uv[[:space:]]*=' "$VENV_ROOT/pyvenv.cfg" || \
      die "VENV_ROOT is not a uv-managed virtual environment: $VENV_ROOT"
    grep -Eq "^(version_info|version)[[:space:]]*=[[:space:]]*${UV_PYTHON_VERSION}([.]|$)" "$VENV_ROOT/pyvenv.cfg" || \
      die "VENV_ROOT must use uv-managed Python $UV_PYTHON_VERSION"
  fi
  if [ -x "$VENV_ROOT/bin/python" ] && [ -n "$SELECTED_ENV" ]; then
    installed_env="$(read_installed_environment)"
    if [ -n "$installed_env" ] && [ "$installed_env" != "$SELECTED_ENV" ]; then
      die "this venv already contains '$installed_env'; '$SELECTED_ENV' needs an incompatible robosuite version"
    fi
  fi
}

create_venv() {
  log "Python virtual environment"; validate_existing_venv
  configure_uv
  if [ ! -x "$VENV_ROOT/bin/python" ]; then
    run_uv python install "$UV_PYTHON_VERSION"
    run_uv venv --managed-python --python "$UV_PYTHON_VERSION" "$VENV_ROOT"
  fi
  PY="$VENV_ROOT/bin/python"
}

install_common_python_deps() {
  log "Common Python dependencies"
  uv_pip_install mujoco==3.3.1
  uv_pip_install -e "${REPO_ROOT}[ray]"
}

verify_liberopro_suites() {
  "$PY" - <<'PYEOF'
from liberopro.liberopro import benchmark
names = [f"libero_{f}_{v}" for f in ("spatial", "object", "goal", "10") for v in ("task", "swap", "lan", "object")]
missing = sorted(set(names) - set(benchmark.get_benchmark_dict()))
assert not missing, f"missing LIBERO-Pro perturbation suites: {missing}"
for name in names:
    suite = benchmark.get_benchmark(name)()
    assert suite.get_num_tasks() > 0, name
    assert suite.get_task(0).language.strip(), name
    assert len(suite.get_task_init_states(0)) > 0, name
print("LIBERO-Pro perturbation suites OK:", len(names))
PYEOF
}

prepare_libero_assets() {
  local composite pkg_root libero_assets robosuite_assets endpoint
  composite="${LIBERO_COMPOSITE_ASSETS_DIR:-$VENV_ROOT/libero-pro-composite-assets}"
  if [ "$SKIP_ASSET_DOWNLOAD" != 1 ]; then
    endpoint="${HF_ENDPOINT:-https://huggingface.co}"
    pkg_root="$("$PY" -c 'import os, liberopro; print(os.path.dirname(liberopro.__file__))')"
    libero_assets="$pkg_root/liberopro/assets"
    HF_ENDPOINT="$endpoint" \
      "$PY" - "$libero_assets" "${LIBERO_PRO_ASSETS_REPO:-RLinf/LIBERO-PRO-assets}" "$endpoint" <<'PYEOF'
import os
import shutil
import sys
from pathlib import Path
from huggingface_hub import HfApi, hf_hub_download

assets_dir, repo_id, endpoint = sys.argv[1:]
assets_root = Path(assets_dir)
api = HfApi(endpoint=endpoint.rstrip("/"))
files = []
pending = [""]
while pending:
    current = pending.pop()
    for attempt in range(6):
        try:
            entries = list(api.list_repo_tree(
                repo_id,
                path_in_repo=current or None,
                repo_type="dataset",
                recursive=False,
            ))
            break
        except Exception:
            if attempt == 5:
                raise
            import time
            time.sleep(min(120, 10 * (2 ** attempt)))
    for item in entries:
        path = item.path
        if hasattr(item, "size"):
            files.append(path)
        else:
            pending.append(path)
for relative in files:
    destination = assets_root / relative
    if destination.is_file():
        continue
    destination.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(6):
        try:
            cached = hf_hub_download(
                repo_id=repo_id,
                filename=relative,
                repo_type="dataset",
                endpoint=endpoint.rstrip("/"),
                cache_dir=os.environ.get("HF_HOME"),
            )
            break
        except Exception:
            if attempt == 5:
                raise
            import time
            time.sleep(min(120, 10 * (2 ** attempt)))
    shutil.copy2(cached, destination)
print("LIBERO-Pro assets downloaded via", endpoint, "files:", len(files))
PYEOF
    robosuite_assets="$("$PY" -c 'import os, robosuite; print(os.path.join(os.path.dirname(robosuite.__file__), "models", "assets"))')"
    if [ ! -d "$composite" ]; then mkdir -p "$composite"; cp -a "$robosuite_assets/." "$composite/"; cp -a "$libero_assets/." "$composite/"; fi
  fi
  [ -f "$composite/robots/panda/robot.xml" ] || die "composite assets are missing robots/panda/robot.xml"
  [ -f "$composite/scenes/libero_tabletop_base_style.xml" ] || die "composite assets are missing scenes/libero_tabletop_base_style.xml"
  export LIBERO_ASSETS_ROOT_OVERRIDE="$composite"
}

install_libero_pro_env() {
  log "Environment: LIBERO-Pro"
  export LIBERO_CONFIG_PATH="${LIBERO_CONFIG_PATH:-$VENV_ROOT/.liberopro-config}"
  uv_pip_install --no-deps "$LIBEROPRO_PACKAGE"
  uv_pip_install "numpy>=1.22,<2" "opencv-python<4.12" "robosuite>=1.4,<1.5" "matplotlib>=3.5.3" torch bddl cloudpickle easydict filelock gym h5py huggingface-hub imageio pyyaml termcolor tqdm
  local version; version="$("$PY" -c 'from importlib.metadata import version; print(version("robosuite"))')"
  case "$version" in 1.4.*) ;; *) die "LIBERO-Pro requires robosuite 1.4.x, got '$version'" ;; esac
  verify_liberopro_suites; prepare_libero_assets
}

install_robocasa_env() {
  log "Environment: RoboCasa"
  uv_pip_install --no-deps -e "$ROBOCASA_SRC_ROOT/robosuite"
  uv_pip_install -e "$ROBOCASA_SRC_ROOT/robocasa"
  "$PY" - <<'PYEOF'
import robosuite
from robosuite.models.robots import PandaOmron  # noqa: F401
assert robosuite.__version__.startswith("1.5."), robosuite.__version__
PYEOF
}

verify_openpi_distribution_guard() {
  "$PY" - <<'PYEOF'
from importlib.metadata import distributions
names = {str(item.metadata.get("Name", "")).lower() for item in distributions()}
allowed = {"rlinf-openpi", "rlinf-transformer-openpi"}
bad = sorted(n for n in names if (n == "rlinf" or n.startswith("rlinf-")) and n not in allowed)
assert not bad, f"forbidden RLinf distributions installed: {bad}"
PYEOF
}

restore_mujoco_pin() { uv_pip_install --reinstall --no-deps mujoco==3.3.1; }

install_openpi_model() {
  log "Model: OpenPI"
  uv_pip_install rlinf-openpi==0.1.1
  verify_openpi_distribution_guard; restore_mujoco_pin
}

flash_attn_default_url() {
  local torch_tag cuda_tag python_tag cxx11abi version=2.8.3
  torch_tag="$("$PY" -c 'import torch; print(".".join(torch.__version__.split("+")[0].split(".")[:2]))')"
  cuda_tag="$("$PY" -c 'import torch; print((torch.version.cuda or "").split(".")[0])')"
  [ -n "$cuda_tag" ] || die "GR00T flash-attn requires CUDA torch"
  python_tag="$("$PY" -c 'import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}")')"
  cxx11abi="$("$PY" -c 'import torch; print("TRUE" if torch._C._GLIBCXX_USE_CXX11_ABI else "FALSE")')"
  printf 'https://github.com/Dao-AILab/flash-attention/releases/download/v%s/flash_attn-%s+cu%storch%scxx11abi%s-%s-%s-linux_x86_64.whl' "$version" "$version" "$cuda_tag" "$torch_tag" "$cxx11abi" "$python_tag" "$python_tag"
}

install_gr00t_model() {
  log "Model: GR00T"
  uv_pip_install -e "$ROBOCASA_SRC_ROOT/Isaac-GR00T"; restore_mujoco_pin
  if [ -n "$FLASH_ATTN_WHEEL" ]; then uv_pip_install "$FLASH_ATTN_WHEEL"; else uv_pip_install "$(flash_attn_default_url)"; fi
  uv_pip_install --reinstall --no-deps transformers==4.51.3
}

install_robocasa_groot_finder_fix() {
  local site_packages; site_packages="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  printf '%s\n' 'import sys; exec("def _fix():\n gi=ri=None\n for i,f in enumerate(sys.meta_path):\n  m=getattr(f,'"'"'__module__'"'"',None)\n  if m=='"'"'__editable___gr00t_1_1_0_finder'"'"': gi=i\n  elif m=='"'"'__editable___robocasa_1_0_1_finder'"'"': ri=i\n if gi is None or ri is None or ri<gi: return\n sys.meta_path.insert(gi,sys.meta_path.pop(ri))\n_fix()")' > "$site_packages/zzz_robocasa_finder_precedence_fix.pth"
}

apply_compatibility_fixes() {
  log "Compatibility fixes"
  local environment model
  environment="$(effective_environment)"; model="$(effective_model)"
  [ -z "$model" ] || uv_pip_install pydantic==2.10.6
  if [ "$environment" = libero-pro ] && [ -n "$model" ]; then
    uv_pip_install "numpy>=1.22,<2"
    uv_pip_install --no-deps "robosuite>=1.4,<1.5"
  elif [ "$environment" = robocasa ] && [ -n "$model" ]; then
    if [ -d "$ROBOCASA_SRC_ROOT/robosuite" ]; then
      uv_pip_install --no-deps -e "$ROBOCASA_SRC_ROOT/robosuite"
    else
      uv_pip_install --no-deps "robosuite>=1.5,<1.6"
    fi
  fi
  [ -z "$model" ] || restore_mujoco_pin
  if [ "$environment" = robocasa ] && [ "$model" = gr00t ]; then install_robocasa_groot_finder_fix; fi
}

record_installed_components() {
  local installed_env installed_model=""
  installed_env="$(read_installed_environment)"
  [ ! -f "$(state_file)" ] || installed_model="$(awk -F= '$1=="model" {print $2}' "$(state_file)")"
  [ -z "$SELECTED_ENV" ] || installed_env="$SELECTED_ENV"
  [ -z "$SELECTED_MODEL" ] || installed_model="$SELECTED_MODEL"
  printf 'env=%s\nmodel=%s\n' "$installed_env" "$installed_model" > "$(state_file)"
}

verify_libero_environment() {
  export LIBERO_CONFIG_PATH="${LIBERO_CONFIG_PATH:-$VENV_ROOT/.liberopro-config}"
  export LIBERO_ASSETS_ROOT_OVERRIDE="${LIBERO_ASSETS_ROOT_OVERRIDE:-${LIBERO_COMPOSITE_ASSETS_DIR:-$VENV_ROOT/libero-pro-composite-assets}}"
  "$PY" - <<'PYEOF'
import os
os.environ.setdefault("MUJOCO_GL", "egl")
from robots.libero.assets import bind_libero_assets_root
bind_libero_assets_root(os.environ["LIBERO_ASSETS_ROOT_OVERRIDE"])
from liberopro.liberopro import benchmark
from liberopro.liberopro import get_libero_path
from liberopro.liberopro.envs import OffScreenRenderEnv
task = benchmark.get_benchmark("libero_10")().get_task(0)
bddl_path = os.path.join(get_libero_path("bddl_files"), task.problem_folder, task.bddl_file)
assert os.path.isfile(bddl_path), bddl_path
env = OffScreenRenderEnv(bddl_file_name=bddl_path)
env.seed(0); assert env.reset() is not None; env.close()
PYEOF
}

verify_robocasa_environment() {
  "$PY" - <<'PYEOF'
import os
os.environ.setdefault("MUJOCO_GL", "egl")
import robocasa  # noqa: F401
from robosuite.environments.base import make
env = make(env_name="PickPlaceCounterToCabinet", robots="PandaOmron", has_renderer=False, has_offscreen_renderer=False, use_camera_obs=False, ignore_done=True)
assert env.reset() is not None; env.close()
PYEOF
}

verify_openpi_model() {
  "$PY" - <<PYEOF
import sys
sys.path.insert(0, "${REPO_ROOT}")
import openpi
from zetta.policies.openpi.factory import build_openpi_model
print(openpi.__file__, build_openpi_model.__module__)
PYEOF
}

verify_gr00t_model() {
  "$PY" - <<'PYEOF'
import inspect, flash_attn, gr00t, transformers.image_utils as iu
assert "VideoInput" in inspect.getsource(iu)
print(gr00t.__file__, flash_attn.__version__)
PYEOF
}

verify_dependency_consistency() {
  local output line unexpected="" known=0
  if output="$(run_uv pip check --python "$PY" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  fi
  printf '%s\n' "$output"
  while IFS= read -r line; do
    case "$line" in
      "The package \`openai-codex\` requires \`pydantic"*|\
      "The package \`mcp\` requires \`pydantic"*|\
      "The package \`pydantic-ai-slim\` requires \`pydantic"*|\
      "The package \`pydantic-graph\` requires \`pydantic"*|\
      "The package \`dm-control\` requires \`mujoco"*|\
      "The package \`rpent-liberopro\` requires \`rlinf-libero"*)
        known=$((known + 1)) ;;
      ""|"Using Python "*|"Checked "*|"Found "*) ;;
      *) unexpected+="${unexpected:+$'\n'}$line" ;;
    esac
  done <<< "$output"
  [ -z "$unexpected" ] || die "unexpected dependency incompatibility:\n$unexpected"
  echo "Known compatibility exceptions: $known"
}

verify_installation() {
  local environment model
  log "Verification"
  "$PY" - <<'PYEOF'
import mujoco, rollout_runtime
assert mujoco.__version__ == "3.3.1", mujoco.__version__
print("mujoco", mujoco.__version__, "rollout_runtime", rollout_runtime.__file__)
PYEOF
  environment="$(effective_environment)"; model="$(effective_model)"
  case "$environment" in libero-pro) verify_libero_environment ;; robocasa) verify_robocasa_environment ;; esac
  case "$model" in openpi) verify_openpi_model ;; gr00t) verify_gr00t_model ;; esac
  verify_dependency_consistency
  record_installed_components
}

print_next_steps() {
  local environment
  environment="$(effective_environment)"
  log "Complete"; echo "venv is ready: $VENV_ROOT"
  [ -z "$SELECTED_ENV" ] || echo "environment: $SELECTED_ENV"
  [ -z "$SELECTED_MODEL" ] || echo "model: $SELECTED_MODEL"
  if [ "$environment" = libero-pro ]; then
    echo "export LIBERO_CONFIG_PATH=${LIBERO_CONFIG_PATH:-$VENV_ROOT/.liberopro-config}"
    echo "export LIBERO_ASSETS_ROOT_OVERRIDE=${LIBERO_COMPOSITE_ASSETS_DIR:-$VENV_ROOT/libero-pro-composite-assets}"
  fi
}

main() {
  local parse_status=0
  parse_args "$@" || parse_status=$?
  if [ "$parse_status" -eq 2 ]; then return 0; elif [ "$parse_status" -ne 0 ]; then return "$parse_status"; fi
  validate_inputs; setup_mirror; prepare_system_dependencies; create_venv; install_common_python_deps
  case "$SELECTED_ENV" in libero-pro) install_libero_pro_env ;; robocasa) install_robocasa_env ;; esac
  case "$SELECTED_MODEL" in openpi) install_openpi_model ;; gr00t) install_gr00t_model ;; esac
  apply_compatibility_fixes; verify_installation; print_next_steps
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
