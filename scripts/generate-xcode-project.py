#!/usr/bin/env python3
"""Generate a dependency-free Xcode application project from the Swift sources."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "DocuFind.xcodeproj"


def ident(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def main() -> None:
    sources = sorted((ROOT / "Sources" / "DocuFind").glob("**/*.swift"))
    if not sources:
        raise SystemExit("No Swift sources found in Sources/DocuFind.")
    lines = [
        "// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {};",
        "\tobjectVersion = 56;", "\tobjects = {",
    ]

    def obj(name: str, properties: str) -> None:
        lines.append(f"\t\t{ident(name)} = {{{properties}}};")

    source_refs: list[str] = []
    source_builds: list[str] = []
    for source in sources:
        relative = source.relative_to(ROOT).as_posix()
        reference_name = "file:" + relative
        build_name = "build:" + relative
        obj(reference_name, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT; ")
        obj(build_name, f"isa = PBXBuildFile; fileRef = {ident(reference_name)}; ")
        source_refs.append(ident(reference_name))
        source_builds.append(ident(build_name))

    obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DocuFind.app; sourceTree = BUILT_PRODUCTS_DIR; ')
    obj("plist", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = SOURCE_ROOT; ')
    obj("icon", 'isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/DocuFind.icns; sourceTree = SOURCE_ROOT; ')
    obj("icon-build", f'isa = PBXBuildFile; fileRef = {ident("icon")}; ')
    obj("banner", 'isa = PBXFileReference; lastKnownFileType = image.png; path = Resources/Banner.png; sourceTree = SOURCE_ROOT; ')
    obj("banner-build", f'isa = PBXBuildFile; fileRef = {ident("banner")}; ')
    obj("sources-group", f"isa = PBXGroup; children = ({', '.join(source_refs)},); name = Sources; sourceTree = \"<group>\"; ")
    obj("products-group", f'isa = PBXGroup; children = ({ident("product")},); name = Products; sourceTree = "<group>"; ')
    obj("main-group", f'isa = PBXGroup; children = ({ident("sources-group")}, {ident("plist")}, {ident("icon")}, {ident("banner")}, {ident("products-group")},); sourceTree = "<group>"; ')
    obj("sources-phase", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({', '.join(source_builds)},); runOnlyForDeploymentPostprocessing = 0; ")
    obj("frameworks-phase", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; ")
    obj("resources-phase", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident("icon-build")}, {ident("banner-build")},); runOnlyForDeploymentPostprocessing = 0; ')
    copy_backend = (
        'set -eu\n'
        'backend_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/backend"\n'
        '/bin/mkdir -p "$backend_destination"\n'
        '/usr/bin/rsync -a --delete --exclude=.venv --exclude=__pycache__ '
        '--exclude=.pytest_cache --exclude=.DS_Store --exclude=\\*.pyc --exclude=tests '
        '"$SRCROOT/backend/" "$backend_destination/"\n'
    )
    obj("backend-phase", f"isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); name = \"Copy local model backend\"; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quote(copy_backend)}; ")
    # Sparkle and the docufind tool are embedded and signed the same way as scripts/build.sh does.
    embed_helpers = (
        'set -eu\n'
        '"$SRCROOT/scripts/embed-helpers.sh" "$TARGET_BUILD_DIR/$WRAPPER_NAME" "${ARCHS%% *}" '
        '"$DERIVED_FILE_DIR/module-cache" "${EXPANDED_CODE_SIGN_IDENTITY:--}"\n'
    )
    obj("helpers-phase", f"isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); name = \"Embed Sparkle and the command-line tool\"; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quote(embed_helpers)}; ")
    phases = ", ".join(ident(name) for name in ["sources-phase", "frameworks-phase", "resources-phase", "backend-phase", "helpers-phase"])
    obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {ident("target-configs")}; buildPhases = ({phases},); buildRules = (); dependencies = (); name = DocuFind; productName = DocuFind; productReference = {ident("product")}; productType = "com.apple.product-type.application"; ')
    obj("project", f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }}; buildConfigurationList = {ident("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {ident("main-group")}; productRefGroup = {ident("products-group")}; projectDirPath = ""; projectRoot = ""; targets = ({ident("target")},); ')

    project_settings = "CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 15.0; SDKROOT = macosx; "
    target_settings = (
        'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = NO; '
        'CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; '
        'COMBINE_HIDPI_IMAGES = YES; CURRENT_PROJECT_VERSION = 1; '
        'CODE_SIGN_ENTITLEMENTS = DocuFind.entitlements; ENABLE_APP_SANDBOX = NO; ENABLE_HARDENED_RUNTIME = YES; '
        'ENABLE_USER_SCRIPT_SANDBOXING = NO; FRAMEWORK_SEARCH_PATHS = "$(SRCROOT)/vendor/Sparkle"; '
        'GENERATE_INFOPLIST_FILE = NO; '
        'INFOPLIST_FILE = Info.plist; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; '
        'MARKETING_VERSION = 0.1.0; OTHER_LDFLAGS = "-framework Sparkle"; PRODUCT_BUNDLE_IDENTIFIER = com.theodeschampsberger.DocuFind; '
        'PRODUCT_NAME = "$(TARGET_NAME)"; SUPPORTED_PLATFORMS = macosx; '
        'SWIFT_EMIT_LOC_STRINGS = YES; SWIFT_VERSION = 5.0; '
    )
    for scope, base in [("project", project_settings), ("target", target_settings)]:
        for config in ["Debug", "Release"]:
            extra = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; ' if config == "Debug" else 'SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; '
            obj(f"{scope}-{config}", f"isa = XCBuildConfiguration; buildSettings = {{{base}{extra}}}; name = {config}; ")
        obj(f"{scope}-configs", f'isa = XCConfigurationList; buildConfigurations = ({ident(scope + "-Debug")}, {ident(scope + "-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; ')

    lines.extend(["\t};", f'\trootObject = {ident("project")};', "}", ""])
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text("\n".join(lines))
    scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="DocuFind.app" BlueprintName="DocuFind" ReferencedContainer="container:DocuFind.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (scheme_dir / "DocuFind.xcscheme").write_text(scheme)
    print(f"Updated {PROJECT}")


if __name__ == "__main__":
    main()
