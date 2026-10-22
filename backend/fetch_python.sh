#!/bin/bash
# Downloads a self-contained Python 3.12 (python-build-standalone) into the given
# folder and prints its executable path. Used when no Python 3.11–3.13 is installed.
# The archive is pinned and checked against its SHA-256 before it is unpacked.
set -euo pipefail

destination="${1:?Usage: fetch_python.sh <folder>}"
release="20260924"
version="3.12.14"
case "$(uname -m)" in
  arm64) triple="aarch64-apple-darwin"; checksum="9763f43db2481a6af36af82ec40302aab7a73632f880129d07a6e81aec846277" ;;
  x86_64) triple="x86_64-apple-darwin"; checksum="0d6a4a299908123f00bc844df737603f047ff9eba14fda6cad83f3cf3cb3a2af" ;;
  *) echo "No standalone Python is available for $(uname -m)." >&2; exit 1 ;;
esac
python="$destination/bin/python3.12"
if [[ -x "$python" ]] && "$python" -c 'import sys; assert sys.version_info[:2] == (3, 12)' >/dev/null 2>&1; then
  echo "$python"
  exit 0
fi

archive_name="cpython-$version+$release-$triple-install_only.tar.gz"
url="https://github.com/astral-sh/python-build-standalone/releases/download/$release/${archive_name//+/%2B}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "Downloading Python ${version}…" >&2
curl --fail --location --silent --show-error --retry 3 --output "$work/python.tar.gz" "$url"
actual="$(shasum -a 256 "$work/python.tar.gz" | cut -d ' ' -f 1)"
if [[ "$actual" != "$checksum" ]]; then
  echo "The Python download did not match its expected checksum, so it was not used." >&2
  exit 1
fi
tar -xzf "$work/python.tar.gz" -C "$work"
rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
mv "$work/python" "$destination"
"$python" -c 'import sys; assert sys.version_info[:2] == (3, 12)'
echo "$python"
