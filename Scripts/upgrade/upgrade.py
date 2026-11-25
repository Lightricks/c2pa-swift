#!/usr/bin/env python3
"""Prepare, compare, and build a trimmed C2PA Swift package."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

SCRIPTS = Path(__file__).resolve().parent
REPOSITORY = SCRIPTS.parents[1]
PINS = SCRIPTS / "upstream.json"
LOCKS = SCRIPTS / "locks"
SWIFT_REPO = "https://github.com/contentauth/c2pa-swift"
RUST_REPO = "https://github.com/contentauth/c2pa-rs"
FORK_REPO = "https://github.com/Lightricks/c2pa-swift"
BINARY_TARGET = re.compile(
    r'(\.binaryTarget\(\s*name:\s*"C2PAC",\s*)url:\s*"([^"]+)",\s*checksum:\s*"([0-9a-f]{64})"'
)
PLATFORMS = re.compile(r"platforms:\s*\[[^\]]*\]")
# A v-prefixed SemVer 2.0 version, including any pre-release and build metadata.
VERSION = re.compile(
    r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
FEATURES = "rust_native_crypto,file_io,c2pa/http_ureq"
DEVICE_TARGET = "aarch64-apple-ios"
SIMULATOR_TARGETS = ("aarch64-apple-ios-sim", "x86_64-apple-ios")
TARGETS = (DEVICE_TARGET, *SIMULATOR_TARGETS)
# Crates that must not be linked into the trimmed library. `ureq` is the only HTTP client.
# tokio is still in c2pa-c-ffi's dependency graph on non-wasm targets, but the C API never
# reaches it, so it is dead-stripped from apps.
FORBIDDEN = {"hyper", "image", "lopdf", "openssl", "openssl-sys", "reqwest"}
REQUIRED = {"ureq"}
# Build-machine paths that must not end up in the library.
LEAKED_PATHS = (b"/Users/", b"/home/runner", b"/private/var/", b"/var/folders/")
BUILD_PROFILE = {
    "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
    "CARGO_PROFILE_RELEASE_OPT_LEVEL": "z",
    "CARGO_PROFILE_RELEASE_LTO": "fat",
    "CARGO_PROFILE_RELEASE_CODEGEN_UNITS": "1",
    "CARGO_PROFILE_RELEASE_PANIC": "abort",
}
# ZIP entries get a fixed timestamp so that the archive depends only on its contents.
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def run(*args, cwd=None, env=None, capture=False):
    return subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_tag(value):
    if not VERSION.fullmatch(value):
        raise argparse.ArgumentTypeError(f"Expected a v-prefixed release tag, got {value!r}")
    return value


def pin(repository, tag):
    pins = json.loads(PINS.read_text())
    try:
        return pins[repository][tag]
    except KeyError:
        raise ValueError(f"{repository} {tag} is not pinned in {PINS}") from None


def clone_pinned(repository, url, tag, destination):
    expected = pin(repository, tag)["commit"]
    refs = run("git", "ls-remote", url, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}",
               capture=True).split()
    remote = dict(zip(refs[1::2], refs[0::2]))
    resolved = remote.get(f"refs/tags/{tag}^{{}}") or remote.get(f"refs/tags/{tag}")
    if resolved != expected:
        raise ValueError(f"{url} tag {tag} resolves to {resolved}, pinned {expected}")
    run("git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1",
        "--branch", tag, url, destination)
    head = run("git", "rev-parse", "HEAD^{commit}", cwd=destination, capture=True).strip()
    if head != expected:
        raise ValueError(f"{url} tag {tag} checked out {head}, pinned {expected}")
    return head


def prepare(tag, work):
    work.mkdir(parents=True)
    swift = work / "swift"
    swift_rev = clone_pinned("c2pa-swift", SWIFT_REPO, tag, swift)
    config = (swift / "Configurations/Base.xcconfig").read_text()
    version = re.search(r"^C2PA_VERSION\s*=\s*(v\S+)", config, re.M)
    if not version:
        raise ValueError("C2PA_VERSION is missing from Base.xcconfig")
    rust_tag = "c2pa-c-ffi-" + checked_tag(version[1])
    rust = work / "rust"
    rust_rev = clone_pinned("c2pa-rs", RUST_REPO, rust_tag, rust)
    target = BINARY_TARGET.search((swift / "Package.swift").read_text())
    if not target or not target[2].startswith(SWIFT_REPO + "/releases/download/"):
        raise ValueError("Expected the upstream C2PAC release asset in Package.swift")
    pinned_checksum = pin("c2pa-swift", tag)["c2pac_zip_sha256"]
    if target[3] != pinned_checksum:
        raise ValueError(f"Package.swift declares {target[3]}, pinned {pinned_checksum}")
    archive = work / "upstream.zip"
    run("curl", "--fail", "--silent", "--show-error", "--location", "--retry", "2",
        target[2], "--output", archive)
    if checksum(archive) != pinned_checksum:
        raise ValueError(f"Upstream archive checksum does not match {pinned_checksum}")
    with ZipFile(archive) as package:
        headers = [
            name for name in package.namelist()
            if Path(name).parts[:2] == ("C2PAC.xcframework", "ios-arm64") and name.endswith(".h")
        ]
        if len(headers) != 1 or Path(headers[0]).name != "c2pa.h":
            raise ValueError(f"Expected a single c2pa.h in the upstream device slice, found {headers}")
        (work / "c2pa.h").write_bytes(package.read(headers[0]))
    archive.unlink()
    (work / "versions.txt").write_text(f"c2pa-swift {tag} {swift_rev}\nc2pa-rs {rust_tag} {rust_rev}\n")


def pinned_version(work, repository):
    """Returns the tag and commit of `repository` in the work directory's versions.txt."""
    for line in (work / "versions.txt").read_text().splitlines():
        name, tag, revision = line.split()
        if name == repository:
            return tag, revision
    raise ValueError(f"versions.txt has no {repository} entry")


def rust_tag(work):
    return pinned_version(work, "c2pa-rs")[0]


def diff(old, candidate):
    if not old.exists() and not candidate.exists():
        return "Path absent in both versions.\n"
    if (old.is_dir() and not candidate.exists()) or (candidate.is_dir() and not old.exists()):
        existing = old if old.is_dir() else candidate
        return "".join(
            diff(old / item.relative_to(existing), candidate / item.relative_to(existing))
            for item in sorted(existing.rglob("*")) if item.is_file()
        )
    old_arg = old if old.exists() else Path("/dev/null")
    candidate_arg = candidate if candidate.exists() else Path("/dev/null")
    result = subprocess.run(["git", "diff", "--no-index", "--no-color", "--", old_arg, candidate_arg],
                            text=True, stdout=subprocess.PIPE)
    if result.returncode not in (0, 1):
        raise ValueError(f"Could not compare {old} and {candidate}")
    return result.stdout or "No changes.\n"


def report(old, candidate):
    paths = (
        "c2pa.h",
        "rust/CHANGELOG.md",
        "rust/c2pa_c_ffi/CHANGELOG.md",
        "rust/Cargo.toml",
        "rust/c2pa_c_ffi/Cargo.toml",
        "rust/sdk/Cargo.toml",
        "rust/c2pa_c_ffi/src/c_api.rs",
        "rust/sdk/src/crypto/time_stamp",
        "rust/sdk/src/http",
        "swift/Library/Sources/Signer.swift",
        "swift/Library/Sources/C2PAContext.swift",
    )
    print("Current\n" + (old / "versions.txt").read_text())
    print("Candidate\n" + (candidate / "versions.txt").read_text())
    for path in paths:
        print(f"=== {path} ===")
        print(diff(old / path, candidate / path))


def header_functions(header):
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path", capture=True).strip()
    ast = run("xcrun", "clang", "-target", "arm64-apple-ios16.0", "-isysroot", sdk,
              "-x", "c-header", "-fsyntax-only", "-Xclang", "-ast-dump", header, capture=True)
    names = set(re.findall(r"\bFunctionDecl .*?\b(c2pa_\w+) '", ast))
    if not names:
        raise ValueError("No C2PA declarations found in c2pa.h")
    return names


def check_archive(archive, header, nm):
    symbols = run(nm, "--extern-only", "--defined-only", "--format=just-symbols", archive,
                  capture=True).splitlines()
    exported = {symbol[1:] for symbol in symbols if symbol.startswith("_c2pa_")}
    missing = sorted(header - exported)
    if missing:
        raise ValueError(f"{archive}: missing header declarations: {', '.join(missing)}")
    rust_exports = sum(bool(re.match(r"^__R|^__ZN.*17h[0-9a-f]{16}E$", symbol))
                       for symbol in symbols)
    if rust_exports > 1000:
        raise ValueError(f"{archive}: {rust_exports} Rust exports; fat LTO may not have run")
    print(f"{archive}: {archive.stat().st_size} bytes, {rust_exports} Rust exports", flush=True)


def check_paths(archive, extra=()):
    contents = archive.read_bytes()
    leaks = []
    for needle in (*LEAKED_PATHS, *extra):
        index = contents.find(needle)
        if index >= 0:
            start = max(contents.rfind(b"\0", 0, index) + 1, index - 120)
            end = contents.find(b"\0", index, index + 240)
            leaks.append(contents[start:end if end >= 0 else index + 240].decode("utf-8", "replace"))
    if leaks:
        raise ValueError(f"{archive}: build-machine paths in the library: {leaks}")


def dependency_tree(cargo, common, target, rust):
    result = subprocess.run(
        [*cargo, "tree", *common, "--target", target, "--edges", "normal", "--prefix", "none"],
        cwd=rust, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise ValueError(f"{target}: cargo tree failed ({result.returncode}):\n{result.stderr}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines or not lines[0].startswith("c2pa-c-ffi "):
        raise ValueError(f"{target}: unexpected cargo tree output:\n{result.stdout}{result.stderr}")
    crates = {line.split()[0] for line in lines}
    forbidden = sorted(FORBIDDEN & crates)
    missing = sorted(REQUIRED - crates)
    if forbidden or missing:
        raise ValueError(f"{target}: forbidden crates {forbidden}, missing required crates {missing}")
    return result.stdout


def remapped_paths(work, toolchain):
    """Returns the --remap-path-prefix pairs that hide build-machine paths in the library."""
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")).resolve()
    sysroot = run("rustc", f"+{toolchain}", "--print", "sysroot", capture=True).strip()
    return (
        (cargo_home / "registry/src", "/cargo/registry/src"),
        (cargo_home / "git/checkouts", "/cargo/git/checkouts"),
        (Path(sysroot).resolve(), "/rustup/toolchain"),
        (work / "rust", "/c2pa-rs"),
    )


def deterministic_zip(directory, archive):
    """Zips `directory` with sorted entries, fixed timestamps and fixed permissions."""
    paths = sorted([directory, *directory.rglob("*")],
                   key=lambda path: path.relative_to(directory.parent).as_posix())
    with ZipFile(archive, "w") as package:
        for path in paths:
            if path.is_symlink():
                raise ValueError(f"Unexpected symbolic link {path}")
            name = path.relative_to(directory.parent).as_posix()
            if path.is_dir():
                entry = ZipInfo(name + "/", ZIP_TIMESTAMP)
                entry.external_attr = (0o40755 << 16) | 0x10
                entry.create_system = 3
                package.writestr(entry, b"")
            else:
                entry = ZipInfo(name, ZIP_TIMESTAMP)
                entry.external_attr = 0o100644 << 16
                entry.create_system = 3
                package.writestr(entry, path.read_bytes(), compress_type=ZIP_DEFLATED,
                                 compresslevel=9)


def ios_manifest(original, binary_target):
    """Returns the Package.swift with `binary_target` and an iOS-only platform list."""
    manifest, edits = BINARY_TARGET.subn(binary_target, original)
    if edits != 1:
        raise ValueError("Could not set the C2PAC binary target")
    # The XCFramework has iOS device and simulator slices only.
    manifest, edits = PLATFORMS.subn("platforms: [\n        .iOS(.v16)\n    ]", manifest)
    if edits != 1:
        raise ValueError("Could not restrict the platforms to iOS")
    return manifest


def toolchain_tools(toolchain):
    cargo = ("cargo", f"+{toolchain}")
    run("rustup", "toolchain", "install", toolchain, "--profile", "minimal")
    run("rustup", "target", "add", "--toolchain", toolchain, *TARGETS)
    # The Rust archives can contain bitcode newer than Xcode's nm can read.
    run("rustup", "component", "add", "--toolchain", toolchain, "llvm-tools")
    libdir = run("rustc", f"+{toolchain}", "--print", "target-libdir", capture=True).strip()
    return cargo, Path(libdir).parent / "bin/llvm-nm"


def patch_features(rust):
    ffi = rust / "c2pa_c_ffi/Cargo.toml"
    patched, edits = re.subn(
        r'(c2pa\s*=\s*\{[^}]*?features\s*=\s*\[[^\]]*?)\s*"pdf",?',
        r"\1", ffi.read_text(), count=1
    )
    if edits:
        ffi.write_text(patched)
    else:
        print("note: c2pa_c_ffi does not enable the pdf feature", file=sys.stderr)


def lock(work, seed, toolchain):
    """Writes a lockfile for a new c2pa-rs tag, changing as few versions of `seed` as possible."""
    work = work.resolve()
    rust = work / "rust"
    destination = LOCKS / f"{rust_tag(work)}.Cargo.lock"
    if destination.exists():
        raise ValueError(f"{destination} exists already")
    patch_features(rust)
    shutil.copyfile(seed, rust / "Cargo.lock")
    cargo, _ = toolchain_tools(toolchain)
    run(*cargo, "update", "--workspace", cwd=rust)
    shutil.copyfile(rust / "Cargo.lock", destination)
    print(f"Wrote {destination}. Review and commit it before building.")


def drift(work, toolchain):
    """Prints the dependency updates available on top of the committed lockfile."""
    rust = work.resolve() / "rust"
    run("cargo", f"+{toolchain}", "update", "--dry-run", "--verbose", cwd=rust)


def build(work, toolchain):
    work = work.resolve()
    rust = work / "rust"
    committed_lock = LOCKS / f"{rust_tag(work)}.Cargo.lock"
    if not committed_lock.exists():
        raise ValueError(f"{committed_lock} is missing; generate it with `upgrade.py lock` and commit it")
    patch_features(rust)
    shutil.copyfile(committed_lock, rust / "Cargo.lock")
    cargo, nm = toolchain_tools(toolchain)
    remaps = remapped_paths(work, toolchain)
    environment = os.environ | BUILD_PROFILE | {
        "CARGO_ENCODED_RUSTFLAGS": "\x1f".join(
            f"--remap-path-prefix={old}={new}" for old, new in remaps
        ),
        # C and assembly built by build scripts, such as ring's. cc parses the flags as shell
        # words, so that paths with spaces stay single flags.
        "TARGET_CFLAGS": shlex.join(f"-ffile-prefix-map={old}={new}" for old, new in remaps),
        "CC_SHELL_ESCAPED_FLAGS": "1",
    }
    environment.pop("RUSTFLAGS", None)
    common = ("--locked", "-p", "c2pa-c-ffi", "--no-default-features", "--features", FEATURES)
    header = header_functions(work / "c2pa.h")
    headers = work / "headers"
    headers.mkdir(exist_ok=True)
    shutil.copyfile(work / "c2pa.h", headers / "c2pa.h")
    (headers / "module.modulemap").write_text('module C2PAC {\n    header "c2pa.h"\n    export *\n}\n')
    local_paths = (str(work).encode(), str(Path.home()).encode())
    archives = {}
    for target in TARGETS:
        dependencies = dependency_tree(cargo, common, target, rust)
        (work / f"{target}-dependencies.txt").write_text(dependencies)
        run(*cargo, "rustc", "--release", *common, "--target", target, "--lib",
            "--crate-type", "staticlib", cwd=rust, env=environment)
        archive = rust / "target" / target / "release/libc2pa_c.a"
        check_archive(archive, header, nm)
        check_paths(archive, local_paths)
        archives[target] = archive

    simulator = work / "simulator/libc2pa_c.a"
    simulator.parent.mkdir(exist_ok=True)
    run("xcrun", "lipo", "-create", *(archives[target] for target in SIMULATOR_TARGETS),
        "-output", simulator)
    architectures = set(run("xcrun", "lipo", "-archs", simulator, capture=True).split())
    if architectures != {"arm64", "x86_64"}:
        raise ValueError(f"{simulator}: unexpected architectures {sorted(architectures)}")
    check_paths(simulator, local_paths)

    deliverable = work / "verified-package-input"
    deliverable.mkdir()
    framework = work / "C2PAC.xcframework"
    run("xcodebuild", "-create-xcframework",
        "-library", archives[DEVICE_TARGET], "-headers", headers,
        "-library", simulator, "-headers", headers, "-output", framework)
    # xcodebuild lists the libraries in a different order from run to run.
    info_path = framework / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["AvailableLibraries"].sort(key=lambda library: library["LibraryIdentifier"])
    info_path.write_bytes(plistlib.dumps(info, sort_keys=True))
    archive = deliverable / "C2PAC.xcframework.zip"
    deterministic_zip(framework, archive)
    swift = work / "swift"
    package = deliverable / "c2pa-swift"
    shutil.copytree(swift / "Library/Sources", package / "Library/Sources")
    for license_file in swift.glob("LICENSE-*"):
        shutil.copyfile(license_file, package / license_file.name)
    for license_file in rust.glob("LICENSE-*"):
        shutil.copyfile(license_file, package / f"c2pa-rs-{license_file.name}")
    shutil.copyfile(archive, package / archive.name)
    manifest = ios_manifest((swift / "Package.swift").read_text(), r'\1path: "C2PAC.xcframework.zip"')
    (package / "Package.swift").write_text(manifest)
    shutil.copyfile(work / "versions.txt", deliverable / "versions.txt")
    shutil.copyfile(rust / "Cargo.lock", deliverable / "Cargo.lock")
    for tree in work.glob("*-dependencies.txt"):
        shutil.copyfile(tree, deliverable / tree.name)
    digest = checksum(archive)
    (deliverable / "C2PAC.xcframework.checksum").write_text(digest + "\n")
    print(f"C2PAC.xcframework.zip SHA-256: {digest}")


def check_release_tag(swift_tag, tag):
    """Checks that `tag` is `<swift tag>-lightricks.<n>` and doesn't exist in the fork yet."""
    if not re.fullmatch(re.escape(swift_tag) + r"-lightricks\.[1-9][0-9]*", tag):
        raise ValueError(f"Expected a release tag {swift_tag}-lightricks.<n>, got {tag!r}")
    if run("git", "ls-remote", "--tags", FORK_REPO, f"refs/tags/{tag}", capture=True).strip():
        raise ValueError(f"{FORK_REPO} has a {tag} tag already")


def release(work, tag):
    swift_tag, _ = pinned_version(work, "c2pa-swift")
    check_release_tag(swift_tag, tag)
    # The release commit ships this checkout's Swift sources with the tested library, so they must
    # be the sources that were tested.
    tested = work / "swift/Library/Sources"
    result = subprocess.run(
        ["git", "diff", "--no-index", "--stat", "--", tested, REPOSITORY / "Library/Sources"],
        text=True, stdout=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise ValueError(f"Library/Sources differs from c2pa-swift {swift_tag}:\n{result.stdout}")
    revision = run("git", "rev-parse", "HEAD", cwd=REPOSITORY, capture=True).strip()
    if os.environ.get("GITHUB_SHA", revision) != revision:
        raise ValueError(f"Checked out {revision}, GITHUB_SHA is {os.environ['GITHUB_SHA']}")
    build_output = work / "verified-package-input"
    destination = work / "release"
    destination.mkdir()
    for item in build_output.iterdir():
        if item.is_file():
            shutil.copyfile(item, destination / item.name)
    # Records the fork commit that built and tested the release.
    with (destination / "versions.txt").open("a") as versions:
        versions.write(f"lightricks/c2pa-swift {tag} {revision}\n")
    original = (work / "swift/Package.swift").read_text()
    url = f"{FORK_REPO}/releases/download/{tag}/C2PAC.xcframework.zip"
    digest = checksum(destination / "C2PAC.xcframework.zip")
    manifest = ios_manifest(
        original, lambda match: f'{match[1]}url: "{url}",\n            checksum: "{digest}"'
    )
    (destination / "Package.swift").write_text(manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("tag", type=checked_tag)
    prepare_parser.add_argument("work", type=Path)
    report_parser = commands.add_parser("report")
    report_parser.add_argument("old", type=Path)
    report_parser.add_argument("candidate", type=Path)
    for name in ("build", "lock", "drift"):
        command = commands.add_parser(name)
        command.add_argument("work", type=Path)
        command.add_argument("--toolchain", default="1.99.1")
        if name == "lock":
            command.add_argument("--seed", type=Path, required=True)
    release_parser = commands.add_parser("release")
    release_parser.add_argument("work", type=Path)
    release_parser.add_argument("tag", type=checked_tag)
    tag_parser = commands.add_parser("check-release-tag")
    tag_parser.add_argument("swift_tag", type=checked_tag)
    tag_parser.add_argument("tag", type=checked_tag)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.tag, args.work)
        elif args.command == "report":
            report(args.old, args.candidate)
        elif args.command == "build":
            build(args.work, args.toolchain)
        elif args.command == "lock":
            lock(args.work, args.seed, args.toolchain)
        elif args.command == "drift":
            drift(args.work, args.toolchain)
        elif args.command == "check-release-tag":
            check_release_tag(args.swift_tag, args.tag)
        else:
            release(args.work, args.tag)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
