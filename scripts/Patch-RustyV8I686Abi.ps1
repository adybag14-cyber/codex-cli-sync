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
    foreach ($path in @($bindingPath, $compilerPath, $cppgcPath)) {
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

    foreach ($check in @(
        @{ Path = $bindingPath; Needle = 'sizeof(v8::ScriptCompiler::CompilationDetails) == 20' },
        @{ Path = $bindingPath; Needle = 'sizeof(v8::ScriptCompiler::Source) == 64' },
        @{ Path = $bindingPath; Needle = "#if INTPTR_MAX == INT64_MAX`nclass alignas(16) RustObjButAlign16" },
        @{ Path = $compilerPath; Needle = '_compilation_details: CompilationDetailsLayout' },
        @{ Path = $cppgcPath; Needle = 'cfg!(target_pointer_width = "64")' }
    )) {
        if (-not [System.IO.File]::ReadAllText($check.Path).Contains($check.Needle)) {
            throw "rusty_v8 i686 ABI patch verification failed: $($check.Path) missing $($check.Needle)"
        }
    }

    Write-Host "Patched rusty_v8 $V8Version for i686 ABI sizes and cppgc alignment."
    return [pscustomobject]@{
        v8_version = $V8Version
        i686_compilation_details_bytes = 20
        i686_source_bytes = 64
        i686_cppgc_max_alignment = 8
        x64_compilation_details_bytes = 24
        x64_source_bytes = 104
        x64_cppgc_max_alignment = 16
    }
}
