#!/bin/bash
# Installs the local runtime: the Python packages in a virtual environment and, when DOCUFIND_MODEL_CACHE is set,
# the search model, downloaded alongside the packages so both finish together.
# Lines starting with "::docufind" report progress to the app:
#   ::docufind runtime <fraction> <message>
#   ::docufind model <received bytes> <total bytes>
set -euo pipefail
backend_dir="$(cd "$(dirname "$0")" && pwd)"
venv_dir="${DOCUFIND_VENV_DIR:-$HOME/Library/Application Support/DocuFind/venv}"
python_command="${DOCUFIND_PYTHON:-}"
model_cache="${DOCUFIND_MODEL_CACHE:-}"
download_pid=""
trap '[[ -n "$download_pid" ]] && kill "$download_pid" 2>/dev/null; true' EXIT
step() { echo "::docufind runtime $1 $2"; }

# The packages take about 0.5 GB; the model about 3.3 GB, and as much again once Core ML compiles it on this Mac.
# Say so now rather than failing halfway.
needed_gb=1
if [[ -n "$model_cache" ]] && [[ ! -f "$model_cache/coreml/files.json" ]]; then
  needed_gb=8
fi
mkdir -p "$(dirname "$venv_dir")"
free_kb="$(df -Pk "$(dirname "$venv_dir")" | awk 'NR == 2 { print $4 }')"
if (( free_kb < needed_gb * 1024 * 1024 )); then
  echo "DocuFind needs about $needed_gb GB of free space to install, and $(( free_kb / 1024 / 1024 )) GB is free. Free up some space, then try again." >&2
  exit 1
fi

step 0.02 "Finding Python…"
supported() { "$1" -c 'import sys; assert (3,11) <= sys.version_info[:2] <= (3,13)' >/dev/null 2>&1; }
if [[ -n "$python_command" ]] && ! supported "$python_command"; then
  echo "Ignoring $python_command: DocuFind needs Python 3.11–3.13."
  python_command=""
fi
if [[ -z "$python_command" && -x "$venv_dir/bin/python" ]] && "$venv_dir/bin/python" -c 'import sys; assert (3,11) <= sys.version_info[:2] <= (3,13)' >/dev/null 2>&1; then
  python_command="$venv_dir/bin/python"
fi
if [[ -z "$python_command" ]]; then
  # GUI-launched apps often lack Homebrew/Python.org locations in their PATH.
  for candidate in python3.13 python3.12 python3.11 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /usr/local/bin/python3.13 /usr/local/bin/python3.12 /usr/local/bin/python3.11 /Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13 /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 /Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; assert (3,11) <= sys.version_info[:2] <= (3,13)' >/dev/null 2>&1; then
      python_command="$candidate"
      break
    fi
  done
fi
if [[ -z "$python_command" ]]; then
  # No suitable Python on this Mac: use a private, checksum-verified copy beside the runtime.
  step 0.03 "Downloading Python 3.12…"
  python_command="$("$backend_dir/fetch_python.sh" "$(dirname "$venv_dir")/python")"
fi
"$python_command" -c 'import sys; assert (3,11) <= sys.version_info[:2] <= (3,13), "Use Python 3.11–3.13 for the model dependencies."'
step 0.06 "Creating the environment…"
if [[ ! -x "$venv_dir/bin/python" ]]; then
  "$python_command" -m venv "$venv_dir"
fi
"$venv_dir/bin/python" -c 'import sys; assert (3,11) <= sys.version_info[:2] <= (3,13), "Existing DocuFind venv uses an unsupported Python. Choose a new DOCUFIND_VENV_DIR with Python 3.11–3.13."'
requirements_file="$backend_dir/requirements.txt"
python_minor="$("$venv_dir/bin/python" -c 'import sys; print(sys.version_info.minor)')"
if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" && ( "$python_minor" == "12" || "$python_minor" == "13" ) && -f "$backend_dir/requirements-macos-arm64.lock.txt" ]]; then
  requirements_file="$backend_dir/requirements-macos-arm64.lock.txt"
  echo "Using the verified Apple Silicon dependency versions (tested with Python 3.12 and 3.13)."
else
  echo "Using compatible dependency ranges for this platform/Python version; this combination has not been verified with the real model."
fi
step 0.08 "Preparing the installer…"
"$venv_dir/bin/python" -m pip install --quiet --upgrade pip

if [[ -n "$model_cache" ]]; then
  # The download library goes first, so the model downloads while the other packages install.
  step 0.1 "Starting the search model download…"
  "$venv_dir/bin/python" -m pip install --quiet -c "$requirements_file" huggingface_hub
  "$venv_dir/bin/python" "$backend_dir/model_download.py" "$model_cache" &
  download_pid=$!
fi

# pip lists every package ("Collecting"), then downloads the ones it lacks ("Downloading" with raw
# "Progress <bytes> of <total>" lines), then installs them. Each phase moves the bar along its own stretch.
"$venv_dir/bin/python" -m pip install --progress-bar raw -r "$requirements_file" 2>&1 | awk '
  function report(fraction, message) {
    if (fraction > 0.97) fraction = 0.97
    printf "::docufind runtime %.3f %s\n", fraction, message
    fflush()
  }
  /^Collecting / {
    print; collected++
    name = $2; sub(/[=<>!~;\[].*/, "", name)
    report(0.12 + 0.13 * (1 - 1 / (1 + collected / 20)), "Checking " name "…")
    next
  }
  /^(Downloading|Using cached) .*\.whl/ {
    print; started++; part = 0
    name = $2; sub(/-[0-9].*/, "", name)
    size = $0; sub(/.*\(/, "", size); sub(/\).*/, "", size)
    current = $1 == "Using" ? name : name " (" size ")"
    report(0.25 + 0.6 * (started - 1) / collected, "Downloading " current "…")
    next
  }
  /^Progress [0-9]+ of [0-9]+/ {
    if ($4 > 0 && $2 / $4 - part >= 0.02) {
      part = $2 / $4
      report(0.25 + 0.6 * (started - 1 + part) / collected, "Downloading " current "… " int(part * 100) "%")
    }
    next
  }
  /^Installing collected packages/ { print; report(0.88, "Installing the packages…"); next }
  { print }
'
step 1 "Runtime installed."
echo "Backend ready: $venv_dir/bin/python"

if [[ -n "$download_pid" ]]; then
  if ! wait "$download_pid"; then
    download_pid=""
    echo "The search model download did not complete. Check your internet connection, then try again." >&2
    exit 1
  fi
  download_pid=""
  echo "Search model ready."
else
  echo "Model weights are downloaded only when indexing/search first uses BidirLM."
fi
