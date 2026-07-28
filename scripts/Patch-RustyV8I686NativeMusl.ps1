Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Patch-RustyV8I686NativeMusl {
    param(
        [Parameter(Mandatory = $true)][string]$V8Version,
        [Parameter(Mandatory = $true)][string]$RustyV8SourceDir
    )

    if ($V8Version -ne "149.2.0") {
        throw "The native i686 musl patch is audited only for rusty_v8 149.2.0; found $V8Version."
    }

    $buildRsPath = Join-Path $RustyV8SourceDir "build.rs"
    $compilerGnPath = Join-Path $RustyV8SourceDir "build/config/compiler/BUILD.gn"
    $linuxToolchainGnPath = Join-Path $RustyV8SourceDir "build/toolchain/linux/BUILD.gn"
    foreach ($path in @($buildRsPath, $compilerGnPath, $linuxToolchainGnPath)) {
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
    [System.IO.File]::WriteAllText($buildRsPath, $buildRs, [System.Text.UTF8Encoding]::new($false))

    $compilerGn = [System.IO.File]::ReadAllText($compilerGnPath).Replace("`r`n", "`n")
    $muslArgLine = '  rusty_v8_zig_lib_dir = ""'
    if (-not $compilerGn.Contains($muslArgLine)) {
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
            '}'
        ) -join "`n"
        if (-not $compilerGn.Contains($muslArgAnchor)) {
            throw "rusty_v8 compiler GN argument contract changed: $compilerGnPath"
        }
        $compilerGn = $compilerGn.Replace($muslArgAnchor, $muslArgPatch)
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

    $gnuTripleLine = '        cflags += [ "--target=i386-unknown-linux-gnu" ]'
    $muslTripleMarker = '          cflags += [ "--target=i386-unknown-linux-musl" ]'
    if (-not $compilerGn.Contains($muslTripleMarker)) {
        if (-not $compilerGn.Contains($gnuTripleLine)) {
            throw "rusty_v8 x86 compiler target contract changed: $compilerGnPath"
        }
        $triplePatch = @(
            '        if (rusty_v8_zig_lib_dir != "" && is_a_target_toolchain) {'
            '          cflags += [ "--target=i386-unknown-linux-musl" ]'
            '        } else {'
            '          cflags += [ "--target=i386-unknown-linux-gnu" ]'
            '        }'
        ) -join "`n"
        $compilerGn = $compilerGn.Replace($gnuTripleLine, $triplePatch)
    }
    if ($compilerGn.Contains('      "-nostdinc",')) {
        throw "rusty_v8 native build still disables bundled Clang resource headers: $compilerGnPath"
    }
    if ($compilerGn.Contains('-idirafter${rusty_v8_zig_lib_dir}/include') -or
        $compilerGn.Contains('-isystem${rusty_v8_zig_lib_dir}/include')) {
        throw "rusty_v8 native build still mixes Zig intrinsic headers with Chromium Clang: $compilerGnPath"
    }
    [System.IO.File]::WriteAllText($compilerGnPath, $compilerGn, [System.Text.UTF8Encoding]::new($false))

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
    [System.IO.File]::WriteAllText($linuxToolchainGnPath, $linuxToolchainGn, [System.Text.UTF8Encoding]::new($false))

    foreach ($check in @(
        @{ Path = $buildRsPath; Needle = 'rusty_v8_zig_lib_dir={zig_lib_dir:?}' },
        @{ Path = $buildRsPath; Needle = 'clang_x86_v8_x86_glibc' },
        @{ Path = $compilerGnPath; Needle = '# rusty_v8 i686-musl target C/C++ headers' },
        @{ Path = $compilerGnPath; Needle = '--target=i386-unknown-linux-musl' },
        @{ Path = $compilerGnPath; Needle = '-nostdlibinc' },
        @{ Path = $compilerGnPath; Needle = '-idirafter${rusty_v8_zig_lib_dir}/libc/include/generic-musl' },
        @{ Path = $compilerGnPath; Needle = 'defines += [ "ANDROID_HOST_MUSL" ]' },
        @{ Path = $compilerGnPath; Needle = 'rusty_v8_zig_lib_dir != "" && is_a_target_toolchain' },
        @{ Path = $linuxToolchainGnPath; Needle = 'clang_v8_toolchain("clang_x86_v8_x86_glibc")' },
        @{ Path = $linuxToolchainGnPath; Needle = 'rusty_v8_zig_lib_dir = ""' }
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
        libcxx_musl_configuration = "ANDROID_HOST_MUSL"
        snapshot_toolchain = "//build/toolchain/linux:clang_x86_v8_x86_glibc"
        snapshot_toolchain_libc = "glibc"
        snapshot_toolchain_pointer_width = 32
    }
}