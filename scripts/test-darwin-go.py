"""Run the macOS backend packages affected by a NUL-delimited Git path list."""

import argparse
import os
from pathlib import PurePosixPath
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--plan", action="store_true")
    args = parser.parse_args()
    paths = set() if args.all else set(os.fsdecode(sys.stdin.buffer.read()).split("\0"))
    module = subprocess.check_output(["go", "list", "-m"], text=True).strip()
    # .Deps includes transitive production imports; test imports can introduce
    # additional dependencies that the production binary does not use.
    template = (
        '{{.ImportPath}}|{{join .Deps " "}}|'
        '{{join .TestImports " "}} {{join .XTestImports " "}}|'
        '{{join .GoFiles " "}} {{join .CgoFiles " "}} '
        '{{join .TestGoFiles " "}} {{join .XTestGoFiles " "}}'
    )
    listing = subprocess.check_output(
        ["go", "list", "-f", template, "./cmd/...", "./internal/..."], text=True
    )
    dependencies = {}
    test_imports = {}
    darwin_packages = set()
    for line in listing.splitlines():
        package, imports, tests, files = line.split("|")
        dependencies[package] = set(imports.split())
        test_imports[package] = tests.split()
        if any("_darwin_" in name or name.endswith("_darwin.go") for name in files.split()):
            darwin_packages.add(package)

    changed = set()
    targets = set()
    for path in paths:
        if path.startswith(("cmd/", "internal/")) and path.endswith(".go"):
            if path.endswith(("_windows.go", "_windows_test.go", "_linux.go", "_linux_test.go")):
                continue
            directory = path.split("/testdata/")[0] if "/testdata/" in path else str(PurePosixPath(path).parent)
            package = f"{module}/{directory}"
            if package in dependencies:
                targets.add(package)
                if not path.endswith("_test.go") and "/testdata/" not in path:
                    changed.add(package)
        elif path.startswith((".github/workflows/", ".github/actions/")) or path in {
            "scripts/check-pr-gate.sh", "scripts/ci-pr-scope.sh", "scripts/test-darwin-go.py"
        }:
            targets.update(darwin_packages)
    if args.all or paths.intersection({"go.mod", "go.sum"}):
        targets.update(dependencies)
    for package, imports in dependencies.items():
        if changed.intersection(imports) or any(
            dep in changed or changed.intersection(dependencies.get(dep, ()))
            for dep in test_imports[package]
        ):
            targets.add(package)

    if not targets:
        print("No affected packages build on macOS.")
        return
    command = ["go", "test", "-count=1", *sorted(targets)]
    print(" ".join(command), flush=True)
    if not args.plan:
        subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
