"""Build the one-file `rowbase` binary for the current OS/arch with Nuitka (no Python needed to run it).

    python packaging/build.py            → dist/rowbase-<os>-<arch>[.exe]
Nuitka cannot cross-compile: run this on each target OS (CI does it: .github/workflows/release.yml).
"""
import os
import platform
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OS = {"darwin": "macos", "win32": "windows", "linux": "linux"}[sys.platform]
ARCH = {"x86_64": "x64", "amd64": "x64", "arm64": "arm64", "aarch64": "arm64"}[platform.machine().lower()]
name = f"rowbase-{OS}-{ARCH}" + (".exe" if OS == "windows" else "")
sys.path.insert(0, ROOT)
from rowbase import __version__  # noqa: E402

args = [sys.executable, "-m", "nuitka", "--onefile", "--assume-yes-for-downloads", "--remove-output",
        f"--output-dir={os.path.join(ROOT, 'dist')}", f"--output-filename={name}",
        "--include-package=rowbase", "--include-package=pymysql", "--include-package=pg8000",
        "--no-deployment-flag=self-execution",  # our CLI has its own -c (connection) flag
        "--include-package=keyring", "--include-distribution-metadata=keyring",  # keyring finds backends via entry points
        f"--include-data-dir={os.path.join(ROOT, 'rowbase', 'static')}=rowbase/static",
        "--nofollow-import-to=tkinter,unittest,test,pydoc,doctest",
        f"--product-name=Rowbase", f"--product-version={__version__}", f"--file-version={__version__}",
        "--company-name=Rowbase", "--file-description=Rowbase database client"]
if OS == "macos":
    args += ["--static-libpython=no", "--macos-target-arch=" + ("arm64" if ARCH == "arm64" else "x86_64")]  # Homebrew/python.org: dylib is bundled
    if os.environ.get("ROWBASE_SIGN_IDENTITY"):  # Developer ID + hardened runtime so it can live inside a notarized app/DMG
        args += [f"--macos-sign-identity={os.environ['ROWBASE_SIGN_IDENTITY']}", "--macos-sign-notarization"]
if OS == "windows":
    args += [f"--windows-icon-from-ico={os.path.join(ROOT, 'packaging', 'rowbase.ico')}"] if os.path.exists(os.path.join(ROOT, "packaging", "rowbase.ico")) else []
if OS == "linux":
    import importlib.util
    args += [f"--include-package={m}" for m in ("secretstorage", "jeepney") if importlib.util.find_spec(m)]
args.append(os.path.join(ROOT, "packaging", "rowbase_main.py"))
print(" ".join(args))
sys.exit(subprocess.call(args, cwd=ROOT))
