Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Patch-RustyV8I686Abi {
    param(
        [Parameter(Mandatory = $true)][string]$V8Version,
        [Parameter(Mandatory = $true)][string]$RustyV8SourceDir
    )

    if ($V8Version -ne "149.2.0") {
        throw "The i686 ABI patch is audited only for rusty_v8 149.2.0; found $V8Version."
    }

    $bindingPath = Join-Path $RustyV8SourceDir "src/binding.cc"
    $compilerPath = Join-Path $RustyV8SourceDir "src/script_compiler.rs"
    $cppgcPath = Join-Path $RustyV8SourceDir "src/cppgc.rs"
    $buildRsPath = Join-Path $RustyV8SourceDir "build.rs"
    foreach ($path in @($bindingPath, $compilerPath, $cppgcPath, $buildRsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required rusty_v8 ABI source file not found: $path"
        }
    }

    $binding = [System.IO.File]::ReadAllText($bindingPath).Replace("`r`n", "`n")
    $layoutPattern = '(?s)static_assert\(sizeof\(v8::ScriptCompiler::CompilationDetails\) ==\s*sizeof\(int64_t\) \* 3,\s*"CompilationDetails size mismatch"\);\s*static_assert\(\s*sizeof\(v8::ScriptCompiler::Source\) ==\s*align_to<size_t>\(sizeof\(size_t\) \* 8 \+ sizeof\(int\) \* 2 \+\s*// the last field before CompilationDetails on 32-bit\s*// systems will have a padding\s*align_to<int64_t>\(sizeof\(size_t\)\) \+\s*sizeof\(v8::ScriptCompiler::CompilationDetails\)\),\s*"Source size mismatch"\);'
    $layoutReplacement = @(
        '#if INTPTR_MAX == INT64_MAX'
        'static_assert(sizeof(v8::ScriptCompiler::CompilationDetails) == 24,'
        '              "CompilationDetails size mismatch");'
        'static_assert(sizeof(v8::ScriptCompiler::Source) == 104,'
        '              "Source size mismatch");'
        '#else'
        'static_assert(sizeof(v8::ScriptCompiler::CompilationDetails) == 20,'
        '              "CompilationDetails size mismatch");'
        'static_assert(sizeof(v8::ScriptCompiler::Source) == 64,'
        '              "Source size mismatch");'
        '#endif'
    ) -join "`n"

    if ($binding -match $layoutPattern) {
        $binding = [regex]::Replace($binding, $layoutPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $layoutReplacement }, 1)
    } elseif (-not $binding.Contains('sizeof(v8::ScriptCompiler::Source) == 64')) {
        throw "rusty_v8 binding layout contract changed: $bindingPath"
    }

    $cppgcPattern = '(?s)class alignas\(16\) RustObjButAlign16 : public RustObj \{\};\s*RustObj\* cppgc__make_garbage_collectable\(v8::CppHeap\* heap, size_t size,\s*size_t alignment\) \{\s*if \(alignment <= 8\) \{\s*return cppgc::MakeGarbageCollected<RustObj>\(heap->GetAllocationHandle\(\),\s*cppgc::AdditionalBytes\(size\)\);\s*\}\s*if \(alignment <= 16\) \{\s*return cppgc::MakeGarbageCollected<RustObjButAlign16>\(\s*heap->GetAllocationHandle\(\), cppgc::AdditionalBytes\(size\)\);\s*\}\s*return nullptr;\s*\}'
    $cppgcReplacement = @(
        '#if INTPTR_MAX == INT64_MAX'
        'class alignas(16) RustObjButAlign16 : public RustObj {};'
        '#endif'
        ''
        'RustObj* cppgc__make_garbage_collectable(v8::CppHeap* heap, size_t size,'
        '                                         size_t alignment) {'
        '  if (alignment <= 8) {'
        '    return cppgc::MakeGarbageCollected<RustObj>(heap->GetAllocationHandle(),'
        '                                                cppgc::AdditionalBytes(size));'
        '  }'
        '#if INTPTR_MAX == INT64_MAX'
        '  if (alignment <= 16) {'
        '    return cppgc::MakeGarbageCollected<RustObjButAlign16>('
        '        heap->GetAllocationHandle(), cppgc::AdditionalBytes(size));'
        '  }'
        '#endif'
        '  return nullptr;'
        '}'
    ) -join "`n"

    if ($binding -match $cppgcPattern) {
        $binding = [regex]::Replace($binding, $cppgcPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $cppgcReplacement }, 1)
    } elseif (-not $binding.Contains('class alignas(16) RustObjButAlign16 : public RustObj {};')) {
        throw "rusty_v8 cppgc binding contract changed: $bindingPath"
    }

    [System.IO.File]::WriteAllText($bindingPath, $binding, [System.Text.UTF8Encoding]::new($false))

    $compiler = [System.IO.File]::ReadAllText($compilerPath).Replace("`r`n", "`n")
    $oldField = '  _compilation_details: [usize; 3],'
    $newField = '  _compilation_details: CompilationDetailsLayout,'
    if ($compiler.Contains($oldField)) {
        $layout = @(
            '#[repr(C)]'
            '#[derive(Debug)]'
            'struct CompilationDetailsLayout {'
            '  _in_memory_cache_result: int,'
            '  _foreground_time_in_microseconds: i64,'
            '  _background_time_in_microseconds: i64,'
            '}'
            ''
        ) -join "`n"
        $sourceComment = '/// Source code which can then be compiled to a UnboundScript or Script.'
        if (-not $compiler.Contains($sourceComment)) {
            throw "rusty_v8 Source comment contract changed: $compilerPath"
        }
        $compiler = $compiler.Replace($sourceComment, $layout + $sourceComment)
        $compiler = $compiler.Replace($oldField, $newField)
    } elseif (-not $compiler.Contains($newField)) {
        throw "rusty_v8 Rust Source layout contract changed: $compilerPath"
    }

    [System.IO.File]::WriteAllText($compilerPath, $compiler, [System.Text.UTF8Encoding]::new($false))

    $cppgc = [System.IO.File]::ReadAllText($cppgcPath).Replace("`r`n", "`n")
    $oldLimit = "    // max alignment in cppgc is 16`n    assert!(std::mem::align_of::<T>() <= 16);"
    $newLimit = @(
        '    // cppgc supports 16-byte alignment on 64-bit, but only 8 on i686.'
        '    let max_alignment = if cfg!(target_pointer_width = "64") { 16 } else { 8 };'
        '    assert!(std::mem::align_of::<T>() <= max_alignment);'
    ) -join "`n"

    if ($cppgc.Contains($oldLimit)) {
        $cppgc = $cppgc.Replace($oldLimit, $newLimit)
    } elseif (-not $cppgc.Contains('let max_alignment = if cfg!(target_pointer_width = "64")')) {
        throw "rusty_v8 Rust cppgc contract changed: $cppgcPath"
    }

    [System.IO.File]::WriteAllText($cppgcPath, $cppgc, [System.Text.UTF8Encoding]::new($false))

    $buildRs = [System.IO.File]::ReadAllText($buildRsPath).Replace("`r`n", "`n")
    $envAnchor = '    "RUSTY_V8_SRC_BINDING_PATH",'
    $envLine = '    "RUSTY_V8_ZIG_LIB_DIR",'
    if (-not $buildRs.Contains($envLine)) {
        if (-not $buildRs.Contains($envAnchor)) {
            throw "rusty_v8 build environment contract changed: $buildRsPath"
        }
        $buildRs = $buildRs.Replace($envAnchor, "$envAnchor`n$envLine")
    }

    $bindgenAnchor = @(
        '  }'
        ''
        '  let bindings = bindgen::Builder::default()'
    ) -join "`n"
    $bindgenPatch = @(
        '  }'
        ''
        '  let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap();'
        '  let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();'
        '  if target_os == "linux" && target_arch == "x86" && target_env == "musl" {'
        '    let zig_lib_dir = PathBuf::from('
        '      env::var("RUSTY_V8_ZIG_LIB_DIR")'
        '        .expect("RUSTY_V8_ZIG_LIB_DIR must be set for i686 musl bindgen"),'
        '    );'
        '    clang_args.push("--target=i386-unknown-linux-musl".to_string());'
        '    clang_args.push("-nostdinc".to_string());'
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
        '        "missing Zig musl bindgen include directory: {}",'
        '        include_path.display()'
        '      );'
        '      clang_args.push(format!("-isystem{}", include_path.display()));'
        '    }'
        '  }'
        ''
        '  let bindings = bindgen::Builder::default()'
    ) -join "`n"

    if (-not $buildRs.Contains('env::var("RUSTY_V8_ZIG_LIB_DIR")')) {
        if (-not $buildRs.Contains($bindgenAnchor)) {
            throw "rusty_v8 bindgen argument contract changed: $buildRsPath"
        }
        $buildRs = $buildRs.Replace($bindgenAnchor, $bindgenPatch)
    }

    [System.IO.File]::WriteAllText($buildRsPath, $buildRs, [System.Text.UTF8Encoding]::new($false))

    foreach ($check in @(
        @{ Path = $bindingPath; Needle = 'sizeof(v8::ScriptCompiler::CompilationDetails) == 20' },
        @{ Path = $bindingPath; Needle = 'sizeof(v8::ScriptCompiler::Source) == 64' },
        @{ Path = $bindingPath; Needle = "#if INTPTR_MAX == INT64_MAX`nclass alignas(16) RustObjButAlign16" },
        @{ Path = $compilerPath; Needle = '_compilation_details: CompilationDetailsLayout' },
        @{ Path = $cppgcPath; Needle = 'cfg!(target_pointer_width = "64")' },
        @{ Path = $buildRsPath; Needle = 'env::var("RUSTY_V8_ZIG_LIB_DIR")' },
        @{ Path = $buildRsPath; Needle = 'libc/include/x86-linux-musl' }
    )) {
        if (-not [System.IO.File]::ReadAllText($check.Path).Contains($check.Needle)) {
            throw "rusty_v8 i686 ABI patch verification failed: $($check.Path) missing $($check.Needle)"
        }
    }

    Write-Host "Patched rusty_v8 $V8Version for i686 ABI sizes, cppgc alignment, and direct Zig-musl bindgen headers."
    return [pscustomobject]@{
        v8_version = $V8Version
        i686_compilation_details_bytes = 20
        i686_source_bytes = 64
        i686_cppgc_max_alignment = 8
        i686_bindgen_direct_zig_musl_headers = $true
        x64_compilation_details_bytes = 24
        x64_source_bytes = 104
        x64_cppgc_max_alignment = 16
    }
}
