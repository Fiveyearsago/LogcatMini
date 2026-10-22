#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET_BIN="$(command -v dotnet || true)"
if [[ -z "$DOTNET_BIN" && -x "$HOME/Library/Caches/LogcatMini/dotnet/dotnet" ]]; then
    DOTNET_BIN="$HOME/Library/Caches/LogcatMini/dotnet/dotnet"
fi
if [[ ! -x "$DOTNET_BIN" ]]; then
    echo "Install .NET SDK 10.0.401 and add dotnet to PATH." >&2
    exit 1
fi
python3 "$PROJECT_DIR/scripts/prepare-windows-recording.py"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
cd "$PROJECT_DIR/windows"
"$DOTNET_BIN" run --project LogcatMini.Checks -c Release
"$DOTNET_BIN" run --project LogcatMini.UiChecks -c Release
mkdir -p "$PROJECT_DIR/dist"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/windows-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
PACKAGE_NAME="LogcatMini-0.2.0-Windows-x64"
PACKAGE_DIR="$STAGING_DIR/$PACKAGE_NAME"
"$DOTNET_BIN" publish LogcatMini.Desktop -c Release -r win-x64 --self-contained true -p:PublishTrimmed=false -p:RestoreLockedMode=true -o "$PACKAGE_DIR"
cp "$PROJECT_DIR/windows/使用说明.txt" "$PACKAGE_DIR/使用说明.txt"
cp -R "$PROJECT_DIR/windows/licenses" "$PACKAGE_DIR/licenses"
python3 - "$PACKAGE_DIR" "$PROJECT_DIR/dist/$PACKAGE_NAME.zip" <<'PY'
import hashlib, pathlib, sys, zipfile
source, output = map(pathlib.Path, sys.argv[1:])
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for f in sorted(source.rglob('*')):
        if f.is_file() and f.suffix.lower() != '.pdb':
            z.write(f, f.relative_to(source.parent))
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix('.zip.sha256').write_text(digest + '  ' + output.name + '\n')
print(f'{output}\nSHA256 {digest}\n{output.stat().st_size / 1024 / 1024:.1f} MiB')
PY
