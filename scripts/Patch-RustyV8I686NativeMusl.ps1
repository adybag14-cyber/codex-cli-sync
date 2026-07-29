Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Patch-RustyV8I686NativeMusl {
    param(
        [Parameter(Mandatory = $true)][string]$V8Version,
        [Parameter(Mandatory = $true)][string]$RustyV8SourceDir
    )

    $supportedVersions = @("149.2.0", "150.4.0")
    if ($V8Version -notin $supportedVersions) {
        throw "The native i686 musl patch is audited only for rusty_v8 versions $($supportedVersions -join ', '); found $V8Version."
    }

    $buildRsPath = Join-Path $RustyV8SourceDir "build.rs"
    $compilerGnPath = Join-Path $RustyV8SourceDir "build/config/compiler/BUILD.gn"
    $cpuAbiGnPath = Join-Path $RustyV8SourceDir "build/config/compiler_cpu_abi.gn"
    $knownRustTargetsPath = Join-Path $RustyV8SourceDir "build/rust/known-target-triples.txt"
    $linuxToolchainGnPath = Join-Path $RustyV8SourceDir "build/toolchain/linux/BUILD.gn"
    $requiredPaths = @($buildRsPath, $compilerGnPath, $linuxToolchainGnPath)
    if ($V8Version -eq "150.4.0") {
        $requiredPaths += @($cpuAbiGnPath, $knownRustTargetsPath)
    }
    foreach ($path in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required rusty_v8 native-build file not found: $path"
        }
    }

    $buildRs = [System.IO.File]::ReadAllText($buildRsPath).Replace("`r`n", "`n")
    $nativeMuslMarker = 'rusty_v8 native build: target C/C++ uses Zig musl headers'
    if (-not $buildRs.Contains($nativeMuslMarker)) {
        $nativeMuslAnchor = @(
            '  gn_args.push(format!('
            '    "use_custom_libcxx={}",'
            '    env::var("CARGO_FEATURE_USE_CUSTOM_LIBCXX").is_ok()'
            '  ));'
            ''
            '  let extra_args = {'
        ) -join "`n"
        $nativeMuslPatch = @(
            '  gn_args.push(format!('
            '    "use_custom_libcxx={}",'
            '    env::var("CARGO_FEATURE_USE_CUSTOM_LIBCXX").is_ok()'
            '  ));'
            ''
            '  let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();'
            '  if target_os == "linux" && target_arch == "x86" && target_env == "musl" {'
            '    let zig_lib_dir = PathBuf::from('
            '      env::var("RUSTY_V8_ZIG_LIB_DIR")'
            '        .expect("RUSTY_V8_ZIG_LIB_DIR must be set for i686 musl native build"),'
            '    );'
            '    for include_dir in ['
            '      "include",'
            '      "libc/include/x86-linux-musl",'
            '      "libc/include/generic-musl",'
            '      "libc/include/x86-linux-any",'
            '      "libc/include/any-linux-any",'
            '    ] {'
            '      let include_path = zig_lib_dir.join(include_dir);'
            '      assert!('
            '        include_path.is_dir(),'
            '        "missing Zig musl native include directory: {}",'
            '        include_path.display()'
            '      );'
            '    }'
            '    gn_args.push(format!("rusty_v8_zig_lib_dir={zig_lib_dir:?}"));'
            '    gn_args.push(format!('
            '      "rusty_v8_crate_version={:?}",'
            '      env!("CARGO_PKG_VERSION")'
            '    ));'
            '    gn_args.push('
            '      "v8_snapshot_toolchain=\"//build/toolchain/linux:clang_x86_v8_x86_glibc\""'
            '        .to_string(),'
            '    );'
            '    eprintln!('
            '      "rusty_v8 native build: target C/C++ uses Zig musl headers; mksnapshot uses isolated x86 glibc toolchain"'
            '    );'
            '  }'
            ''
            '  let extra_args = {'
        ) -join "`n"
        if (-not $buildRs.Contains($nativeMuslAnchor)) {
            throw "rusty_v8 native musl GN argument contract changed: $buildRsPath"
        }
        $buildRs = $buildRs.Replace($nativeMuslAnchor, $nativeMuslPatch)
    }
    $crateVersionGnMarker = 'rusty_v8_crate_version={:?}'
    if (-not $buildRs.Contains($crateVersionGnMarker)) {
        $crateVersionGnAnchor = '    gn_args.push(format!("rusty_v8_zig_lib_dir={zig_lib_dir:?}"));'
        $crateVersionGnPatch = @(
            '    gn_args.push(format!("rusty_v8_zig_lib_dir={zig_lib_dir:?}"));'
            '    gn_args.push(format!('
            '      "rusty_v8_crate_version={:?}",'
            '      env!("CARGO_PKG_VERSION")'
            '    ));'
        ) -join "`n"
        if (-not $buildRs.Contains($crateVersionGnAnchor)) {
            throw "rusty_v8 crate-version GN argument contract changed: $buildRsPath"
        }
        $buildRs = $buildRs.Replace($crateVersionGnAnchor, $crateVersionGnPatch)
    }
    if ($V8Version -eq "150.4.0") {
        $muslX86Marker = 'Cross build (x64 host -> x86 musl target).'
        if (-not $buildRs.Contains($muslX86Marker)) {
            $unsupportedMuslAnchor = @(
                '      other => panic!('
                '        "musl builds are only supported for x86_64 and aarch64 (got {other})"'
                '      ),'
            ) -join "`n"
            $x86MuslPatch = @(
                '      "x86" => {'
                '        // Cross build (x64 host -> x86 musl target). The default host'
                '        // toolchain stays x64 glibc, while the audited GN args select'
                '        // an x86 glibc snapshot toolchain. Target C/C++ and Rust stay musl.'
                '      }'
                '      other => panic!('
                '        "musl builds are only supported for x86_64, aarch64, and x86 (got {other})"'
                '      ),'
            ) -join "`n"
            if (-not $buildRs.Contains($unsupportedMuslAnchor)) {
                throw "rusty_v8 upstream musl architecture contract changed: $buildRsPath"
            }
            $buildRs = $buildRs.Replace($unsupportedMuslAnchor, $x86MuslPatch)
        }
    }
    [System.IO.File]::WriteAllText($buildRsPath, $buildRs, [System.Text.UTF8Encoding]::new($false))

    if ($V8Version -eq "150.4.0") {
        $knownRustTargets = [System.IO.File]::ReadAllText($knownRustTargetsPath).Replace("`r`n", "`n")
        $i686MuslTriple = 'i686-unknown-linux-musl'
        if (-not ($knownRustTargets -split "`n").Contains($i686MuslTriple)) {
            $i686GnuTriple = "i686-unknown-linux-gnu`n"
            if (-not $knownRustTargets.Contains($i686GnuTriple)) {
                throw "rusty_v8 Rust target allow-list contract changed: $knownRustTargetsPath"
            }
            $knownRustTargets = $knownRustTargets.Replace(
                $i686GnuTriple,
                "i686-unknown-linux-gnu`ni686-unknown-linux-musl`n"
            )
        }
        [System.IO.File]::WriteAllText(
            $knownRustTargetsPath,
            $knownRustTargets,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    $compilerGn = [System.IO.File]::ReadAllText($compilerGnPath).Replace("`r`n", "`n")
    $gnArgumentPath = if ($V8Version -eq "150.4.0") { $cpuAbiGnPath } else { $compilerGnPath }
    $gnArgumentText = if ($V8Version -eq "150.4.0") {
        [System.IO.File]::ReadAllText($cpuAbiGnPath).Replace("`r`n", "`n")
    } else {
        $compilerGn
    }
    $muslArgLine = '  rusty_v8_zig_lib_dir = ""'
    $versionArgLine = '  rusty_v8_crate_version = ""'
    if (-not $gnArgumentText.Contains($muslArgLine)) {
        if ($V8Version -eq "150.4.0") {
            $muslArgAnchor = 'import("//build/toolchain/toolchain.gni")'
            $muslArgPatch = @(
                'import("//build/toolchain/toolchain.gni")'
                ''
                'declare_args() {'
                '  # Non-empty only for rusty_v8''s audited i686-musl target toolchain.'
                '  rusty_v8_zig_lib_dir = ""'
                '  rusty_v8_crate_version = ""'
                '}'
            ) -join "`n"
        } else {
            $muslArgAnchor = @(
                'declare_args() {'
                '  # This allows overriding the location of lld.'
                '  lld_path = default_lld_path'
                '}'
            ) -join "`n"
            $muslArgPatch = @(
                'declare_args() {'
                '  # This allows overriding the location of lld.'
                '  lld_path = default_lld_path'
                ''
                '  # Non-empty only for rusty_v8''s audited i686-musl target toolchain.'
                '  rusty_v8_zig_lib_dir = ""'
                '  rusty_v8_crate_version = ""'
                '}'
            ) -join "`n"
        }
        if (-not $gnArgumentText.Contains($muslArgAnchor)) {
            throw "rusty_v8 compiler GN argument contract changed: $gnArgumentPath"
        }
        $gnArgumentText = $gnArgumentText.Replace($muslArgAnchor, $muslArgPatch)
    } elseif (-not $gnArgumentText.Contains($versionArgLine)) {
        $gnArgumentText = $gnArgumentText.Replace($muslArgLine, "$muslArgLine`n$versionArgLine")
    }
    if ($V8Version -eq "150.4.0") {
        $cpuAbiGn = $gnArgumentText
    } else {
        $compilerGn = $gnArgumentText
    }

    $nativeHeadersMarker = '# rusty_v8 i686-musl target C/C++ headers'
    if (-not $compilerGn.Contains($nativeHeadersMarker)) {
        $nativeHeadersAnchor = @(
            '  ldflags = []'
            '  defines = []'
            '  configs = []'
        ) -join "`n"
        $nativeHeadersPatch = @(
            '  ldflags = []'
            '  defines = []'
            '  configs = []'
            ''
            '  # rusty_v8 i686-musl target C/C++ headers. The separate snapshot'
            '  # toolchain clears rusty_v8_zig_lib_dir and remains glibc-hosted.'
            '  if (rusty_v8_zig_lib_dir != "" && is_a_target_toolchain &&'
            '      current_cpu == "x86") {'
            '    cflags += ['
            '      "-nostdlibinc",'
            '      "-idirafter${rusty_v8_zig_lib_dir}/libc/include/x86-linux-musl",'
            '      "-idirafter${rusty_v8_zig_lib_dir}/libc/include/generic-musl",'
            '      "-idirafter${rusty_v8_zig_lib_dir}/libc/include/x86-linux-any",'
            '      "-idirafter${rusty_v8_zig_lib_dir}/libc/include/any-linux-any",'
            '    ]'
            '    defines += [ "ANDROID_HOST_MUSL" ]'
            '  }'
        ) -join "`n"
        if (-not $compilerGn.Contains($nativeHeadersAnchor)) {
            throw "rusty_v8 compiler config contract changed: $compilerGnPath"
        }
        $compilerGn = $compilerGn.Replace($nativeHeadersAnchor, $nativeHeadersPatch)
    }

    # Migrate restored registry sources from the earlier ordering. Keep the
    # bundled Clang resource headers for intrinsics and add only Zig's libc
    # headers after libc++ so its wrappers can use include_next to reach musl.
    $compilerGn = $compilerGn.Replace('      "-nostdinc",', '      "-nostdlibinc",')
    $compilerGn = $compilerGn.Replace(
        '      "-idirafter${rusty_v8_zig_lib_dir}/include",' + "`n",
        ''
    )
    $compilerGn = $compilerGn.Replace(
        '      "-isystem${rusty_v8_zig_lib_dir}/include",' + "`n",
        ''
    )
    foreach ($includeDir in @(
        'libc/include/x86-linux-musl',
        'libc/include/generic-musl',
        'libc/include/x86-linux-any',
        'libc/include/any-linux-any'
    )) {
        $compilerGn = $compilerGn.Replace(
            "-isystem`${rusty_v8_zig_lib_dir}/$includeDir",
            "-idirafter`${rusty_v8_zig_lib_dir}/$includeDir"
        )
    }
    $libcxxMuslDefine = '    defines += [ "ANDROID_HOST_MUSL" ]'
    if (-not $compilerGn.Contains($libcxxMuslDefine)) {
        $libcxxMuslAnchor = @(
            '      "-idirafter${rusty_v8_zig_lib_dir}/libc/include/any-linux-any",'
            '    ]'
            '  }'
        ) -join "`n"
        $libcxxMuslPatch = @(
            '      "-idirafter${rusty_v8_zig_lib_dir}/libc/include/any-linux-any",'
            '    ]'
            '    defines += [ "ANDROID_HOST_MUSL" ]'
            '  }'
        ) -join "`n"
        if (-not $compilerGn.Contains($libcxxMuslAnchor)) {
            throw "rusty_v8 libc++ musl configuration contract changed: $compilerGnPath"
        }
        $compilerGn = $compilerGn.Replace($libcxxMuslAnchor, $libcxxMuslPatch)
    }

    $tripleGnPath = if ($V8Version -eq "150.4.0") { $cpuAbiGnPath } else { $compilerGnPath }
    $tripleGn = if ($V8Version -eq "150.4.0") { $cpuAbiGn } else { $compilerGn }
    if ($V8Version -eq "150.4.0") {
        $gnuTripleLine = '      cpu_abi_cflags += [ "--target=i386-unknown-linux-gnu" ]'
        $muslTripleMarker = '        cpu_abi_cflags += [ "--target=i386-unknown-linux-musl" ]'
        $triplePatch = @(
            '      if (rusty_v8_zig_lib_dir != "" && is_a_target_toolchain) {'
            '        cpu_abi_cflags += [ "--target=i386-unknown-linux-musl" ]'
            '      } else {'
            '        cpu_abi_cflags += [ "--target=i386-unknown-linux-gnu" ]'
            '      }'
        ) -join "`n"
    } else {
        $gnuTripleLine = '        cflags += [ "--target=i386-unknown-linux-gnu" ]'
        $muslTripleMarker = '          cflags += [ "--target=i386-unknown-linux-musl" ]'
        $triplePatch = @(
            '        if (rusty_v8_zig_lib_dir != "" && is_a_target_toolchain) {'
            '          cflags += [ "--target=i386-unknown-linux-musl" ]'
            '        } else {'
            '          cflags += [ "--target=i386-unknown-linux-gnu" ]'
            '        }'
        ) -join "`n"
    }
    if (-not $tripleGn.Contains($muslTripleMarker)) {
        if (-not $tripleGn.Contains($gnuTripleLine)) {
            throw "rusty_v8 x86 compiler target contract changed: $tripleGnPath"
        }
        $tripleGn = $tripleGn.Replace($gnuTripleLine, $triplePatch)
    }
    if ($V8Version -eq "150.4.0") {
        $cpuAbiGn = $tripleGn
    } else {
        $compilerGn = $tripleGn
    }
    if ($compilerGn.Contains('      "-nostdinc",')) {
        throw "rusty_v8 native build still disables bundled Clang resource headers: $compilerGnPath"
    }
    if ($compilerGn.Contains('-idirafter${rusty_v8_zig_lib_dir}/include') -or
        $compilerGn.Contains('-isystem${rusty_v8_zig_lib_dir}/include')) {
        throw "rusty_v8 native build still mixes Zig intrinsic headers with Chromium Clang: $compilerGnPath"
    }
    [System.IO.File]::WriteAllText($compilerGnPath, $compilerGn, [System.Text.UTF8Encoding]::new($false))
    if ($V8Version -eq "150.4.0") {
        [System.IO.File]::WriteAllText($cpuAbiGnPath, $cpuAbiGn, [System.Text.UTF8Encoding]::new($false))
    }

    $linuxToolchainGn = [System.IO.File]::ReadAllText($linuxToolchainGnPath).Replace("`r`n", "`n")
    $snapshotToolchainMarker = 'clang_v8_toolchain("clang_x86_v8_x86_glibc")'
    if (-not $linuxToolchainGn.Contains($snapshotToolchainMarker)) {
        $snapshotToolchainAnchor = @(
            'template("clang_v8_toolchain") {'
            '  clang_toolchain(target_name) {'
            '    toolchain_args = {'
            '      current_os = "linux"'
            '      forward_variables_from(invoker.toolchain_args, "*")'
            '    }'
            '  }'
            '}'
        ) -join "`n"
        $snapshotToolchainPatch = @(
            'template("clang_v8_toolchain") {'
            '  clang_toolchain(target_name) {'
            '    toolchain_args = {'
            '      current_os = "linux"'
            '      forward_variables_from(invoker.toolchain_args, "*")'
            '    }'
            '  }'
            '}'
            ''
            '# 32-bit glibc host toolchain used only to run x86 mksnapshot while'
            '# the default x86 target toolchain compiles the final archive for musl.'
            'clang_v8_toolchain("clang_x86_v8_x86_glibc") {'
            '  toolchain_args = {'
            '    current_cpu = "x86"'
            '    v8_current_cpu = "x86"'
            '    rusty_v8_zig_lib_dir = ""'
            '  }'
            '}'
        ) -join "`n"
        if (-not $linuxToolchainGn.Contains($snapshotToolchainAnchor)) {
            throw "rusty_v8 Linux toolchain contract changed: $linuxToolchainGnPath"
        }
        $linuxToolchainGn = $linuxToolchainGn.Replace($snapshotToolchainAnchor, $snapshotToolchainPatch)
    }
    $snapshotToolchainStart = $linuxToolchainGn.IndexOf('clang_v8_toolchain("clang_x86_v8_x86_glibc")')
    if ($snapshotToolchainStart -lt 0) {
        throw "rusty_v8 isolated snapshot toolchain missing after patch: $linuxToolchainGnPath"
    }
    $snapshotToolchainEnd = $linuxToolchainGn.IndexOf("`n}`n", $snapshotToolchainStart)
    if ($snapshotToolchainEnd -lt 0) {
        throw "rusty_v8 isolated snapshot toolchain block is malformed: $linuxToolchainGnPath"
    }
    $snapshotToolchainBlock = $linuxToolchainGn.Substring(
        $snapshotToolchainStart,
        $snapshotToolchainEnd + 3 - $snapshotToolchainStart
    )
    if ($V8Version -eq "150.4.0" -and
        -not $snapshotToolchainBlock.Contains('use_musl = false')) {
        $snapshotToolchainBlockPatched = $snapshotToolchainBlock.Replace(
            '    rusty_v8_zig_lib_dir = ""',
            "    rusty_v8_zig_lib_dir = `"`"`n    use_musl = false"
        )
        if ($snapshotToolchainBlockPatched -eq $snapshotToolchainBlock) {
            throw "rusty_v8 snapshot musl-isolation contract changed: $linuxToolchainGnPath"
        }
        $linuxToolchainGn = $linuxToolchainGn.Replace(
            $snapshotToolchainBlock,
            $snapshotToolchainBlockPatched
        )
    }
    [System.IO.File]::WriteAllText($linuxToolchainGnPath, $linuxToolchainGn, [System.Text.UTF8Encoding]::new($false))

    foreach ($check in @(
        @{ Path = $buildRsPath; Needle = 'rusty_v8_zig_lib_dir={zig_lib_dir:?}' },
        @{ Path = $buildRsPath; Needle = 'rusty_v8_crate_version={:?}' },
        @{ Path = $buildRsPath; Needle = 'clang_x86_v8_x86_glibc' },
        @{ Path = $buildRsPath; Needle = if ($V8Version -eq "150.4.0") { 'Cross build (x64 host -> x86 musl target).' } else { 'rusty_v8 native build: target C/C++ uses Zig musl headers' } },
        @{ Path = $gnArgumentPath; Needle = 'rusty_v8_crate_version = ""' },
        @{ Path = $compilerGnPath; Needle = '# rusty_v8 i686-musl target C/C++ headers' },
        @{ Path = $tripleGnPath; Needle = '--target=i386-unknown-linux-musl' },
        @{ Path = $compilerGnPath; Needle = '-nostdlibinc' },
        @{ Path = $compilerGnPath; Needle = '-idirafter${rusty_v8_zig_lib_dir}/libc/include/generic-musl' },
        @{ Path = $compilerGnPath; Needle = 'defines += [ "ANDROID_HOST_MUSL" ]' },
        @{ Path = $compilerGnPath; Needle = 'rusty_v8_zig_lib_dir != "" && is_a_target_toolchain' },
        @{ Path = $linuxToolchainGnPath; Needle = 'clang_v8_toolchain("clang_x86_v8_x86_glibc")' },
        @{ Path = $linuxToolchainGnPath; Needle = 'rusty_v8_zig_lib_dir = ""' },
        @{ Path = if ($V8Version -eq "150.4.0") { $linuxToolchainGnPath } else { $buildRsPath }; Needle = if ($V8Version -eq "150.4.0") { 'use_musl = false' } else { 'rusty_v8 native build: target C/C++ uses Zig musl headers' } },
        @{ Path = if ($V8Version -eq "150.4.0") { $knownRustTargetsPath } else { $buildRsPath }; Needle = if ($V8Version -eq "150.4.0") { 'i686-unknown-linux-musl' } else { 'rusty_v8 native build: target C/C++ uses Zig musl headers' } }
    )) {
        if (-not [System.IO.File]::ReadAllText($check.Path).Contains($check.Needle)) {
            throw "rusty_v8 native i686 musl patch verification failed: $($check.Path) missing $($check.Needle)"
        }
    }

    Write-Host "Patched rusty_v8 $V8Version target C/C++ for Zig musl with an isolated x86 glibc snapshot toolchain."
    return [pscustomobject]@{
        v8_version = $V8Version
        target_triple = "i386-unknown-linux-musl"
        native_zig_musl_headers = $true
        native_zig_musl_headers_after_libcxx = $true
        native_compiler_builtin_headers = $true
        gn_crate_version_marker = $true
        upstream_musl_x86_architecture_enabled = $V8Version -eq "150.4.0"
        rust_target_triple_allowlisted = if ($V8Version -eq "150.4.0") { "i686-unknown-linux-musl" } else { $null }
        snapshot_use_musl = if ($V8Version -eq "150.4.0") { $false } else { $null }
        cpu_abi_config = if ($V8Version -eq "150.4.0") { "build/config/compiler_cpu_abi.gn" } else { "build/config/compiler/BUILD.gn" }
        libcxx_musl_configuration = "ANDROID_HOST_MUSL"
        snapshot_toolchain = "//build/toolchain/linux:clang_x86_v8_x86_glibc"
        snapshot_toolchain_libc = "glibc"
        snapshot_toolchain_pointer_width = 32
    }
}