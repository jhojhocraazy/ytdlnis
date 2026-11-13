<#
.SYNOPSIS
    Diagnóstico de sincronização upstream x tradução pt-BR dos 7 repositórios.

.DESCRIPTION
    Verifica, para cada repositório, o estado do Git local (branch, commit,
    alterações não commitadas), consulta o remoto e compara as chaves dos
    arquivos-fonte em inglês (values/strings.xml, messages.json, en.json) entre
    a base da nossa tradução e o upstream.

    O script é somente leitura por padrão no que se refere ao conteúdo dos
    repositórios: ele NUNCA executa pull, merge, checkout, reset, stash ou
    commit. A única escrita em .git é o `git fetch` do remoto upstream (ou origin,
    quando não há upstream) (metadados de remote-tracking), que pode ser desligado
    com -ReadOnly ou -NoFetch.

    A base de comparação é, por padrão, o HEAD local (a versão do código-fonte
    sobre a qual a tradução foi construída). Um arquivo .sync-baseline.json
    pode fixar uma base explícita por repositório; use -UpdateBaseline após
    concluir um ciclo de tradução para avançar essa base.

.PARAMETER Root
    Raiz do workspace que contém as 7 pastas de repositório. Padrão: a pasta
    onde este script está.

.PARAMETER Repo
    Um ou mais nomes de repositório a analisar (ex.: better-lyrics,ytdlnis).
    Padrão: todos os 7.

.PARAMETER ReadOnly
    Não executa `git fetch` e não grava o baseline. Usa apenas as referências
    remote-tracking já existentes no clone. É o modo mais conservador.

.PARAMETER NoFetch
    Não consulta a rede, mas permite gravar o baseline. Útil para diagnóstico
    offline com referências já baixadas.

.PARAMETER Json
    Emite um único documento JSON no stdout, sem tabela nem texto decorativo.
    Indicado para automação e para as sessões isoladas de tradução.

.PARAMETER UpdateBaseline
    Grava .sync-baseline.json com o commit upstream atual de cada repositório
    que não tenha pendências nem lacunas de cobertura. Recusa repositórios com
    chaves novas/alteradas ou lacunas, a menos que -Force seja usado.

.PARAMETER Force
    Permite atualizar o baseline mesmo havendo chaves pendentes ou lacunas.
    Use com consciência: pendências não traduzidas deixam de ser sinalizadas
    como novidade upstream.

.PARAMETER FailOnPending
    Retorna código 1 quando houver qualquer chave nova ou alterada pendente.
    Sem este switch, pendências não são erro (código 0).

.PARAMETER DetailLimit
    Máximo de nomes de chave exibidos por categoria em cada arquivo (0-50).
    Padrão: 8.

.EXAMPLE
    .\sync-check.ps1
    Diagnóstico completo: fetch + tabela.

.EXAMPLE
    .\sync-check.ps1 -ReadOnly
    Diagnóstico sem rede e sem qualquer escrita.

.EXAMPLE
    .\sync-check.ps1 -Repo better-lyrics,ytdlnis -Json
    Delta dos dois repositórios em JSON, para uma sessão de tradução.

.EXAMPLE
    .\sync-check.ps1 -UpdateBaseline
    Executa o check e fixa a base no upstream atual dos repositórios sem
    pendências.

.NOTES
    Requisitos: PowerShell 7+, Git 2.30+ e acesso HTTPS aos remotos.
    O backend SSL exigido para o fetch é `openssl` (-c http.sslBackend=openssl).
    Saída: 0 = ok; 1 = pendências com -FailOnPending; 2 = erro de execução.
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,

    [string[]]$Repo,

    [switch]$ReadOnly,

    [switch]$NoFetch,

    [switch]$Json,

    [switch]$UpdateBaseline,

    [switch]$Force,

    [switch]$FailOnPending,

    [ValidateRange(0, 50)]
    [int]$DetailLimit = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '1.0.0'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:TempDir = $null
$script:UseColor = -not $Json
$script:GitTimeoutSeconds = 180
$script:FetchTimeoutSeconds = 300

# ---------------------------------------------------------------------------
# Infraestrutura: console, temporários e execução do Git
# ---------------------------------------------------------------------------

try {
    [Console]::OutputEncoding = $script:Utf8NoBom
    $OutputEncoding = $script:Utf8NoBom
}
catch {
    # Console de redirecionamento pode recusar; não é fatal.
}

function Write-Ui {
    param(
        [AllowEmptyString()][string]$Text = '',
        [string]$Color = 'Gray'
    )
    if ($script:UseColor) {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Initialize-TempDir {
    $base = [System.IO.Path]::GetTempPath()
    $dir = Join-Path $base ('sync-check-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:TempDir = $dir
}

function Remove-TempDir {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
    Executa o Git com stdout/stderr redirecionados para arquivos e um arquivo
    de código de saída. Esse desenho evita pipes nomeados (que podem ser
    bloqueados por sandboxes) e funciona igualmente em terminal comum.
#>
function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = $script:GitTimeoutSeconds
    )

    if (-not $script:TempDir) {
        throw 'Diretório temporário não inicializado.'
    }

    $id = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $script:TempDir "$id.out"
    $errFile = Join-Path $script:TempDir "$id.err"
    $codeFile = Join-Path $script:TempDir "$id.code"
    $cmdFile = Join-Path $script:TempDir "$id.cmd"

    $effectiveArgs = @('-c', 'color.ui=false', '-c', 'core.quotepath=false') + $Arguments
    $quotedArgs = foreach ($arg in $effectiveArgs) {
        if ($arg -match '"') {
            throw "Argumento Git com aspas não suportado: $arg"
        }
        '"' + $arg + '"'
    }
    $argLine = $quotedArgs -join ' '

    $lines = @(
        '@echo off',
        ('git -C "{0}" {1} > "{2}" 2> "{3}"' -f $RepoPath, $argLine, $outFile, $errFile),
        ('echo %ERRORLEVEL% > "{0}"' -f $codeFile)
    )
    [System.IO.File]::WriteAllLines($cmdFile, $lines, [System.Text.Encoding]::ASCII)

    $process = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList @('/d', '/c', $cmdFile) `
        -WindowStyle Hidden -PassThru

    $timeoutMs = [Math]::Max(5000, $TimeoutSeconds * 1000)
    if (-not $process.WaitForExit($timeoutMs)) {
        try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
        Remove-Item $outFile, $errFile, $codeFile, $cmdFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            ExitCode  = -1
            StdOut    = ''
            StdErr    = "Tempo esgotado após ${TimeoutSeconds}s"
            TimedOut  = $true
        }
    }
    $process.WaitForExit()

    $codeText = ''
    if (Test-Path -LiteralPath $codeFile) {
        $codeText = [System.IO.File]::ReadAllText($codeFile, [System.Text.Encoding]::ASCII)
    }
    $exitCode = -1
    if ($codeText -match '(-?\d+)') {
        $exitCode = [int]$Matches[1]
    }

    $stdout = ''
    $stderr = ''
    if (Test-Path -LiteralPath $outFile) {
        $stdout = [System.IO.File]::ReadAllText($outFile, $script:Utf8NoBom)
    }
    if (Test-Path -LiteralPath $errFile) {
        $stderr = [System.IO.File]::ReadAllText($errFile, $script:Utf8NoBom)
    }

    Remove-Item $outFile, $errFile, $codeFile, $cmdFile -Force -ErrorAction SilentlyContinue

    [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
        TimedOut = $false
    }
}

function Read-WorkingText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Format-Cell {
    param([AllowNull()][string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) {
        return $Text.Substring(0, $Width - 1) + '…'
    }
    return $Text.PadRight($Width)
}

function Format-Percent {
    param([double]$Value, [int]$Missing)
    $text = $Value.ToString('0.0').Replace('.', ',') + '%'
    if ($Missing -gt 0) {
        $text = "$text ($Missing)"
    }
    return $text
}

function Get-SumProperty {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$Name
    )
    $sum = 0.0
    foreach ($item in $Items) {
        $value = $item[$Name]
        if ($null -ne $value) {
            $sum += [double]$value
        }
    }
    return $sum
}

# ---------------------------------------------------------------------------
# Configuração dos repositórios
# ---------------------------------------------------------------------------

function New-SourceEntry {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string[]]$Includes,
        [Parameter(Mandatory)][ValidateSet('xml', 'chrome-json', 'nested-json')][string]$Format,
        [string[]]$ArrayWhitelist = @(),
        [string[]]$ExcludePrefixes = @(),
        [string]$TargetFileName = '',
        [ValidateSet('file', 'ledger')][string]$CoverageMode = 'file',
        [string]$InheritedLedger = '',
        [string]$InheritedLocale = ''
    )
    [pscustomobject]@{
        Dir             = $Dir
        TargetDir       = $TargetDir
        Includes        = $Includes
        Format          = $Format
        ArrayWhitelist  = $ArrayWhitelist
        ExcludePrefixes = $ExcludePrefixes
        TargetFileName  = $TargetFileName
        CoverageMode    = $CoverageMode
        InheritedLedger = $InheritedLedger
        InheritedLocale = $InheritedLocale
    }
}

$script:RepoConfigs = @(
    [pscustomobject]@{
        Name    = 'better-lyrics'
        Sources = @(
            (New-SourceEntry -Dir '_locales/en' -TargetDir '_locales/pt_BR' `
                -Includes @('messages.json') -Format 'chrome-json')
        )
    },
    [pscustomobject]@{
        Name    = 'BitChord'
        Sources = @(
            (New-SourceEntry -Dir 'app/src/main/res/values' -TargetDir 'app/src/main/res/values-pt' `
                -Includes @('strings.xml') -Format 'xml'),
            (New-SourceEntry -Dir 'sharedUi/src/commonMain/composeResources/values' -TargetDir 'sharedUi/src/commonMain/composeResources/values-pt' `
                -Includes @('strings.xml') -Format 'xml'),
            (New-SourceEntry -Dir 'wearos/src/main/res/values' -TargetDir 'wearos/src/main/res/values-pt' `
                -Includes @('strings.xml') -Format 'xml')
        )
    },
    [pscustomobject]@{
        Name    = 'DNSToggle'
        Sources = @(
            (New-SourceEntry -Dir 'app/src/main/res/values' -TargetDir 'app/src/main/res/values-pt-rBR' `
                -Includes @('strings.xml') -Format 'xml')
        )
    },
    [pscustomobject]@{
        Name    = 'NuvioMobile'
        Sources = @(
            (New-SourceEntry -Dir 'composeApp/src/commonMain/composeResources/values' -TargetDir 'composeApp/src/commonMain/composeResources/values-pt-rBR' `
                -Includes @('*.xml') -Format 'xml')
        )
    },
    [pscustomobject]@{
        Name    = 'TizenTube'
        Sources = @(
            (New-SourceEntry -Dir 'mods/translations/resources' -TargetDir 'mods/translations/resources' `
                -Includes @('en.json') -Format 'nested-json' -TargetFileName 'pt-BR.json' `
                -ExcludePrefixes @('__'))
        )
    },
    [pscustomobject]@{
        Name    = 'torbox-app'
        Sources = @(
            (New-SourceEntry -Dir 'src/i18n/messages' -TargetDir 'src/i18n/messages' `
                -Includes @('en.json') -Format 'nested-json' -TargetFileName 'pt-BR.json' `
                -ExcludePrefixes @('Admin.', 'CustomViews.presets.') `
                -CoverageMode 'ledger' -InheritedLedger 'src/i18n/messages/inherited.json' `
                -InheritedLocale 'pt-BR')
        )
    },
    [pscustomobject]@{
        Name    = 'ytdlnis'
        Sources = @(
            (New-SourceEntry -Dir 'app/src/main/res/values' -TargetDir 'app/src/main/res/values-pt-rBR' `
                -Includes @('strings.xml', 'arrays.xml') -Format 'xml' `
                -ArrayWhitelist @('countries', 'language_names'))
        )
    }
)

# ---------------------------------------------------------------------------
# Parsers de chaves
# ---------------------------------------------------------------------------

function New-OrdinalMap {
    return [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
}

function Normalize-Text {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    return $normalized.Trim()
}

function Get-XmlResourceMap {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string[]]$ArrayWhitelist = @()
    )

    $map = New-OrdinalMap
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return [pscustomobject]@{ Keys = $map; Skipped = 0 }
    }

    $document = [System.Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.LoadXml($Content)

    if ($null -eq $document.DocumentElement) {
        return [pscustomobject]@{ Keys = $map; Skipped = 0 }
    }

    $skipped = 0
    foreach ($node in $document.DocumentElement.ChildNodes) {
        if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }

        $name = $node.GetAttribute('name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $translatable = $node.GetAttribute('translatable')
        if ($translatable -eq 'false') {
            $skipped++
            continue
        }

        # Importante: o adaptador ETS do PowerShell faz $node.Name devolver o
        # atributo name. O nome real da tag XML está em LocalName.
        if ($node.LocalName -eq 'string') {
            $map[$name] = Normalize-Text $node.InnerXml
        }
        elseif ($node.LocalName -eq 'plurals') {
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $node.ChildNodes) {
                if ($item.NodeType -eq [System.Xml.XmlNodeType]::Element -and $item.LocalName -eq 'item') {
                    $quantity = $item.GetAttribute('quantity')
                    $parts.Add($quantity + '=' + (Normalize-Text $item.InnerXml))
                }
            }
            $map[$name] = $parts -join "`u{001F}"
        }
        elseif ($node.LocalName -eq 'string-array') {
            if ($ArrayWhitelist.Count -gt 0 -and $ArrayWhitelist -notcontains $name) { continue }
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $node.ChildNodes) {
                if ($item.NodeType -eq [System.Xml.XmlNodeType]::Element -and $item.LocalName -eq 'item') {
                    $parts.Add((Normalize-Text $item.InnerXml))
                }
            }
            $map[$name] = $parts -join "`u{001F}"
        }
    }

    [pscustomobject]@{ Keys = $map; Skipped = $skipped }
}

function Get-ChromeMessagesMap {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $map = New-OrdinalMap
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return [pscustomobject]@{ Keys = $map; Skipped = 0 }
    }

    $parsed = ($Content.TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable)
    $skipped = 0
    foreach ($key in $parsed.Keys) {
        $value = $parsed[$key]
        if ($value -is [System.Collections.IDictionary]) {
            if ($value.Contains('message')) {
                $message = $value['message']
                if ($null -ne $message) {
                    $map[[string]$key] = [string]$message
                }
            }
        }
        else {
            $skipped++
        }
    }

    [pscustomobject]@{ Keys = $map; Skipped = $skipped }
}

function Add-JsonLeaves {
    param(
        [AllowNull()]$Node,
        [string]$Prefix,
        [string[]]$ExcludePrefixes,
        [System.Collections.Generic.Dictionary[string, string]]$Map
    )

    if ($null -eq $Node) { return }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $path = if ($Prefix) { "$Prefix.$key" } else { [string]$key }
            $excluded = $false
            foreach ($prefixToExclude in $ExcludePrefixes) {
                if ($path.StartsWith($prefixToExclude, [System.StringComparison]::Ordinal)) {
                    $excluded = $true
                    break
                }
            }
            if ($excluded) { continue }
            Add-JsonLeaves -Node $Node[$key] -Prefix $path -ExcludePrefixes $ExcludePrefixes -Map $Map
        }
        return
    }

    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        if ([string]::IsNullOrWhiteSpace($Prefix)) { return }
        $Map[$Prefix] = ConvertTo-Json -InputObject $Node -Compress -Depth 20
        return
    }

    if ([string]::IsNullOrWhiteSpace($Prefix)) { return }
    $Map[$Prefix] = [string]$Node
}

function Get-NestedJsonMap {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string[]]$ExcludePrefixes = @()
    )

    $map = New-OrdinalMap
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return [pscustomobject]@{ Keys = $map; Skipped = 0 }
    }

    $parsed = ($Content.TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable)
    Add-JsonLeaves -Node $parsed -Prefix '' -ExcludePrefixes $ExcludePrefixes -Map $map

    [pscustomobject]@{ Keys = $map; Skipped = 0 }
}

function Get-KeyMapForContent {
    param(
        [AllowNull()][string]$Content,
        [Parameter(Mandatory)]$SourceEntry
    )

    if ($null -eq $Content) {
        return [pscustomobject]@{ Keys = (New-OrdinalMap); Skipped = 0 }
    }

    switch ($SourceEntry.Format) {
        'xml' {
            return Get-XmlResourceMap -Content $Content -ArrayWhitelist $SourceEntry.ArrayWhitelist
        }
        'chrome-json' {
            return Get-ChromeMessagesMap -Content $Content
        }
        'nested-json' {
            return Get-NestedJsonMap -Content $Content -ExcludePrefixes $SourceEntry.ExcludePrefixes
        }
        default {
            throw "Formato desconhecido: $($SourceEntry.Format)"
        }
    }
}

function Compare-KeyMaps {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Base,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Upstream
    )

    $added = [System.Collections.Generic.List[string]]::new()
    $modified = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $Upstream.Keys) {
        if (-not $Base.ContainsKey($key)) {
            $added.Add($key)
        }
        elseif ($Base[$key] -cne $Upstream[$key]) {
            $modified.Add($key)
        }
    }
    foreach ($key in $Base.Keys) {
        if (-not $Upstream.ContainsKey($key)) {
            $removed.Add($key)
        }
    }

    [pscustomobject]@{
        Added    = @($added | Sort-Object)
        Modified = @($modified | Sort-Object)
        Removed  = @($removed | Sort-Object)
    }
}

# ---------------------------------------------------------------------------
# Estado do Git
# ---------------------------------------------------------------------------

function Get-RepoSnapshot {
    param([Parameter(Mandatory)][string]$RepoPath)

    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
        throw "Diretório do repositório não encontrado: $RepoPath"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
        throw "Não é um repositório Git: $RepoPath"
    }

    $branchResult = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($branchResult.ExitCode -ne 0) {
        throw "Falha ao ler a branch: $($branchResult.StdErr.Trim())"
    }

    $headResult = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('rev-parse', 'HEAD')
    if ($headResult.ExitCode -ne 0) {
        throw "Falha ao ler o HEAD: $($headResult.StdErr.Trim())"
    }

    $shortResult = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('rev-parse', '--short', 'HEAD')
    $remoteResult = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('remote', 'get-url', 'origin')
    $statusResult = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('status', '--porcelain')

    $dirtyLines = @()
    if ($statusResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($statusResult.StdOut)) {
        $dirtyLines = @(
            $statusResult.StdOut -split "`n" |
                ForEach-Object { $_.TrimEnd() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    [pscustomobject]@{
        Branch     = $branchResult.StdOut.Trim()
        HeadCommit = $headResult.StdOut.Trim()
        HeadShort  = $shortResult.StdOut.Trim()
        RemoteUrl  = if ($remoteResult.ExitCode -eq 0) { $remoteResult.StdOut.Trim() } else { '' }
        DirtyLines = $dirtyLines
    }
}

function Resolve-UpstreamRef {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Branch
    )

    # Com a topologia fork: origin = fork pessoal, upstream = projeto original.
    # A fonte de verdade do delta é sempre upstream; @{u} pode apontar para o fork
    # depois de um `git push -u origin`.
    $upstreamCandidate = "upstream/$Branch"
    $verifyUpstream = Invoke-GitCommand -RepoPath $RepoPath `
        -Arguments @('rev-parse', '--verify', '--quiet', $upstreamCandidate)
    if ($verifyUpstream.ExitCode -eq 0) {
        return $upstreamCandidate
    }

    $tracking = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('rev-parse', '--abbrev-ref', '@{u}')
    if ($tracking.ExitCode -eq 0) {
        $candidate = $tracking.StdOut.Trim()
        if ($candidate -and $candidate -ne 'HEAD') {
            $verify = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('rev-parse', '--verify', '--quiet', $candidate)
            if ($verify.ExitCode -eq 0) {
                return $candidate
            }
        }
    }

    $fallback = "origin/$Branch"
    $verifyFallback = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('rev-parse', '--verify', '--quiet', $fallback)
    if ($verifyFallback.ExitCode -eq 0) {
        return $fallback
    }

    return $null
}

function Get-Divergence {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$UpstreamRef
    )

    $result = Invoke-GitCommand -RepoPath $RepoPath `
        -Arguments @('rev-list', '--left-right', '--count', "HEAD...$UpstreamRef")

    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Ahead = 0; Behind = 0 }
    }

    if ($result.StdOut -match '^\s*(\d+)\s+(\d+)') {
        return [pscustomobject]@{ Ahead = [int]$Matches[1]; Behind = [int]$Matches[2] }
    }

    return [pscustomobject]@{ Ahead = 0; Behind = 0 }
}

function Get-RefSourceIndex {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string[]]$Dirs,
        [Parameter(Mandatory)][string[]]$Includes
    )

    $arguments = @('ls-tree', '-r', $Ref, '--') + $Dirs
    $result = Invoke-GitCommand -RepoPath $RepoPath -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw "Falha ao listar arquivos em ${Ref}: $($result.StdErr.Trim())"
    }

    $index = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in ($result.StdOut -split "`n")) {
        $text = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $tab = $text.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $meta = $text.Substring(0, $tab) -split ' '
        if ($meta.Count -lt 3 -or $meta[1] -ne 'blob') { continue }
        $path = $text.Substring($tab + 1)
        $leaf = [System.IO.Path]::GetFileName($path)
        $matchesInclude = $false
        foreach ($include in $Includes) {
            if ($leaf -like $include) { $matchesInclude = $true; break }
        }
        if ($matchesInclude) {
            $index[$path] = $meta[2]
        }
    }

    return $index
}

function Get-RefFileContent {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$Path
    )

    $result = Invoke-GitCommand -RepoPath $RepoPath -Arguments @('show', "${Ref}:${Path}")
    if ($result.ExitCode -ne 0) {
        return $null
    }
    return $result.StdOut
}

function Resolve-BaseCommit {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$HeadCommit,
        $BaselineEntry
    )

    if ($null -ne $BaselineEntry -and $BaselineEntry -is [System.Collections.IDictionary] -and $BaselineEntry.Contains('baseCommit')) {
        $candidate = [string]$BaselineEntry['baseCommit']
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $verify = Invoke-GitCommand -RepoPath $RepoPath `
                -Arguments @('rev-parse', '--verify', '--quiet', "$candidate^{commit}")
            if ($verify.ExitCode -eq 0) {
                return [pscustomobject]@{
                    Commit = $verify.StdOut.Trim()
                    Source = 'baseline'
                }
            }
            return [pscustomobject]@{
                Commit = $HeadCommit
                Source = 'HEAD (baseline inválido)'
            }
        }
    }

    return [pscustomobject]@{ Commit = $HeadCommit; Source = 'HEAD' }
}

# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------

function Get-Baseline {
    param([Parameter(Mandatory)][string]$RootPath)

    $path = Join-Path $RootPath '.sync-baseline.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        $content = [System.IO.File]::ReadAllText($path, $script:Utf8NoBom)
        $parsed = $content | ConvertFrom-Json -AsHashtable
        if (-not ($parsed -is [System.Collections.IDictionary]) -or -not $parsed.Contains('schemaVersion')) {
            throw 'estrutura inesperada (schemaVersion ausente)'
        }
        return $parsed
    }
    catch {
        Write-Ui "Aviso: .sync-baseline.json ilegível ($($_.Exception.Message)); usando HEAD como base." 'Yellow'
        return $null
    }
}

function Save-Baseline {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)]$Baseline
    )

    $path = Join-Path $RootPath '.sync-baseline.json'
    $json = ($Baseline | ConvertTo-Json -Depth 12) + "`n"
    Write-Utf8File -Path $path -Content $json
}

function Get-BaselineEntry {
    param($Baseline, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Baseline -or -not ($Baseline -is [System.Collections.IDictionary])) { return $null }
    if (-not $Baseline.Contains('repos')) { return $null }
    $repos = $Baseline['repos']
    if (-not ($repos -is [System.Collections.IDictionary])) { return $null }
    if (-not $repos.Contains($Name)) { return $null }
    return $repos[$Name]
}

# ---------------------------------------------------------------------------
# Análise de um repositório
# ---------------------------------------------------------------------------

function Get-RepoAnalysis {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RootPath,
        $Baseline
    )

    $repoPath = Join-Path $RootPath $Config.Name
    $result = [ordered]@{
        Name             = $Config.Name
        Path             = $repoPath
        Branch           = ''
        HeadCommit       = ''
        HeadShort        = ''
        RemoteUrl        = ''
        UpstreamRef      = ''
        UpstreamCommit   = ''
        BaseCommit       = ''
        BaseSource       = ''
        Ahead            = 0
        Behind           = 0
        DirtyFiles       = @()
        SourceDirtyFiles = @()
        FetchError       = ''
        Error            = ''
        Warnings         = @()
        Files            = @()
        Added            = 0
        Modified         = 0
        Removed          = 0
        Pending          = 0
        BaseKeyCount     = 0
        MissingKeys      = 0
        ExtraKeys        = 0
        CoveragePercent  = 100.0
        Status           = ''
    }

    try {
        $snapshot = Get-RepoSnapshot -RepoPath $repoPath
        $result.Branch = $snapshot.Branch
        $result.HeadCommit = $snapshot.HeadCommit
        $result.HeadShort = $snapshot.HeadShort
        $result.RemoteUrl = $snapshot.RemoteUrl
        $result.DirtyFiles = @($snapshot.DirtyLines)

        $sourceDirty = @()
        foreach ($line in $snapshot.DirtyLines) {
            $statusCode = if ($line.Length -ge 2) { $line.Substring(0, 2) } else { '' }
            $pathPart = $line
            if ($pathPart.Length -gt 3) { $pathPart = $pathPart.Substring(3) }
            $normalized = ($pathPart -replace '\\', '/')
            $leaf = [System.IO.Path]::GetFileName($normalized)
            $matched = $false
            foreach ($entry in $Config.Sources) {
                if ($matched) { break }
                $dirPrefix = ($entry.Dir -replace '\\', '/').TrimEnd('/') + '/'
                if (-not $normalized.StartsWith($dirPrefix, [System.StringComparison]::Ordinal)) { continue }
                foreach ($include in $entry.Includes) {
                    if ($leaf -like $include) {
                        if ($statusCode -eq '??') {
                            $sourceDirty += $normalized
                        }
                        else {
                            # Diferença apenas de CRLF não é alteração de conteúdo.
                            $contentDiff = Invoke-GitCommand -RepoPath $repoPath `
                                -Arguments @('diff', 'HEAD', '--quiet', '--ignore-cr-at-eol', '--', $normalized)
                            if ($contentDiff.ExitCode -ne 0) {
                                $sourceDirty += $normalized
                            }
                        }
                        $matched = $true
                        break
                    }
                }
            }
        }
        $result.SourceDirtyFiles = @($sourceDirty | Select-Object -Unique)

        # --- fetch ---
        if (-not $ReadOnly -and -not $NoFetch -and -not [string]::IsNullOrWhiteSpace($snapshot.RemoteUrl)) {
            $fetchRemote = 'origin'
            $remoteList = Invoke-GitCommand -RepoPath $repoPath -Arguments @('remote')
            if ($remoteList.ExitCode -eq 0) {
                $remotes = @($remoteList.StdOut -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($remotes -contains 'upstream') { $fetchRemote = 'upstream' }
            }
            $fetch = Invoke-GitCommand -RepoPath $repoPath `
                -Arguments @('-c', 'http.sslBackend=openssl', 'fetch', $fetchRemote) `
                -TimeoutSeconds $script:FetchTimeoutSeconds
            if ($fetch.ExitCode -ne 0) {
                $message = $fetch.StdErr.Trim()
                if ([string]::IsNullOrWhiteSpace($message)) { $message = 'falha sem mensagem do Git' }
                $result.FetchError = $message
                $result.Warnings += "git fetch falhou; usando referências locais: $message"
            }
        }
        elseif ($ReadOnly) {
            $result.Warnings += 'Modo somente leitura: git fetch não executado.'
        }
        elseif ($NoFetch) {
            $result.Warnings += 'Modo offline (-NoFetch): git fetch não executado.'
        }

        # --- upstream ---
        $upstreamRef = Resolve-UpstreamRef -RepoPath $repoPath -Branch $snapshot.Branch
        if ($upstreamRef) {
            $verifyUpstream = Invoke-GitCommand -RepoPath $repoPath `
                -Arguments @('rev-parse', '--verify', '--quiet', $upstreamRef)
            if ($verifyUpstream.ExitCode -eq 0) {
                $result.UpstreamRef = $upstreamRef
                $result.UpstreamCommit = $verifyUpstream.StdOut.Trim()
                $divergence = Get-Divergence -RepoPath $repoPath -UpstreamRef $upstreamRef
                $result.Ahead = $divergence.Ahead
                $result.Behind = $divergence.Behind
            }
        }

        # --- base ---
        $baselineEntry = Get-BaselineEntry -Baseline $Baseline -Name $Config.Name
        $base = Resolve-BaseCommit -RepoPath $repoPath -HeadCommit $snapshot.HeadCommit -BaselineEntry $baselineEntry
        $result.BaseCommit = $base.Commit
        $result.BaseSource = $base.Source

        $upstreamForDelta = if ($result.UpstreamCommit) { $result.UpstreamCommit } else { $base.Commit }

        # --- cobertura via ledger (torbox-app) ---
        $ledgerCovered = $null
        $ledgerEntry = $Config.Sources | Where-Object { $_.CoverageMode -eq 'ledger' } | Select-Object -First 1
        if ($ledgerEntry) {
            $ledgerCovered = New-OrdinalMap
            $ledgerWarnings = [System.Collections.Generic.List[string]]::new()

            $deltaPath = Join-Path $repoPath (Join-Path $ledgerEntry.TargetDir $ledgerEntry.TargetFileName)
            $deltaContent = Read-WorkingText -Path $deltaPath
            if ($null -eq $deltaContent) {
                $ledgerWarnings.Add("Arquivo delta ausente: $($ledgerEntry.TargetDir)/$($ledgerEntry.TargetFileName)")
            }
            else {
                try {
                    $deltaMap = (Get-KeyMapForContent -Content $deltaContent -SourceEntry $ledgerEntry).Keys
                    foreach ($key in $deltaMap.Keys) { $ledgerCovered[$key] = $deltaMap[$key] }
                }
                catch {
                    $ledgerWarnings.Add("Falha ao ler delta pt-BR: $($_.Exception.Message)")
                }
            }

            $inheritedPath = Join-Path $repoPath $ledgerEntry.InheritedLedger
            $inheritedContent = Read-WorkingText -Path $inheritedPath
            if ($null -eq $inheritedContent) {
                $ledgerWarnings.Add("Ledger ausente: $($ledgerEntry.InheritedLedger)")
            }
            else {
                try {
                    $inheritedObj = $inheritedContent.TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable
                    if ($inheritedObj.Contains($ledgerEntry.InheritedLocale)) {
                        $localeNode = $inheritedObj[$ledgerEntry.InheritedLocale]
                        $inheritedMap = New-OrdinalMap
                        Add-JsonLeaves -Node $localeNode -Prefix '' -ExcludePrefixes @() -Map $inheritedMap
                        foreach ($key in $inheritedMap.Keys) {
                            if (-not $ledgerCovered.ContainsKey($key)) {
                                $ledgerCovered[$key] = $inheritedMap[$key]
                            }
                        }
                    }
                    else {
                        $ledgerWarnings.Add("Locale '$($ledgerEntry.InheritedLocale)' ausente em $($ledgerEntry.InheritedLedger)")
                    }
                }
                catch {
                    $ledgerWarnings.Add("Falha ao ler ledger inherited.json: $($_.Exception.Message)")
                }
            }

            $result.Warnings += $ledgerWarnings.ToArray()
        }

        # --- delta por arquivo ---
        $files = [System.Collections.Generic.List[object]]::new()
        $totalAdded = 0
        $totalModified = 0
        $totalRemoved = 0
        $totalMissing = 0
        $totalBaseKeys = 0
        $totalExtra = 0

        foreach ($sourceEntry in $Config.Sources) {
            $includeDirs = @($sourceEntry.Dir)
            $baseIndex = Get-RefSourceIndex -RepoPath $repoPath -Ref $base.Commit `
                -Dirs $includeDirs -Includes $sourceEntry.Includes
            $upstreamIndex = Get-RefSourceIndex -RepoPath $repoPath -Ref $upstreamForDelta `
                -Dirs $includeDirs -Includes $sourceEntry.Includes

            $allPaths = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($path in $baseIndex.Keys) { [void]$allPaths.Add($path) }
            foreach ($path in $upstreamIndex.Keys) { [void]$allPaths.Add($path) }

            foreach ($path in $allPaths) {
                $baseHash = $null
                $upstreamHash = $null
                if ($baseIndex.ContainsKey($path)) { $baseHash = $baseIndex[$path] }
                if ($upstreamIndex.ContainsKey($path)) { $upstreamHash = $upstreamIndex[$path] }

                $baseContent = $null
                $upstreamContent = $null
                if ($baseHash) {
                    $baseContent = Get-RefFileContent -RepoPath $repoPath -Ref $base.Commit -Path $path
                }
                if ($upstreamHash) {
                    if ($baseHash -and $baseHash -eq $upstreamHash) {
                        $upstreamContent = $baseContent
                    }
                    else {
                        $upstreamContent = Get-RefFileContent -RepoPath $repoPath -Ref $upstreamForDelta -Path $path
                    }
                }

                $fileWarning = ''
                $baseMap = New-OrdinalMap
                $upstreamMap = New-OrdinalMap
                $parseFailed = $false

                if ($null -ne $baseContent) {
                    try {
                        $baseMap = (Get-KeyMapForContent -Content $baseContent -SourceEntry $sourceEntry).Keys
                    }
                    catch {
                        $parseFailed = $true
                        $fileWarning = "Fonte base ilegível em ${path}: $($_.Exception.Message)"
                        $result.Warnings += $fileWarning
                    }
                }
                if ($null -ne $upstreamContent) {
                    try {
                        $upstreamMap = (Get-KeyMapForContent -Content $upstreamContent -SourceEntry $sourceEntry).Keys
                    }
                    catch {
                        $parseFailed = $true
                        $fileWarning = "Fonte upstream ilegível em ${path}: $($_.Exception.Message)"
                        $result.Warnings += $fileWarning
                    }
                }
                elseif ($upstreamHash) {
                    $fileWarning = "Não foi possível ler ${path} em ${upstreamForDelta}."
                    $result.Warnings += $fileWarning
                }

                $delta = if ($parseFailed) {
                    [pscustomobject]@{ Added = @(); Modified = @(); Removed = @() }
                }
                else {
                    Compare-KeyMaps -Base $baseMap -Upstream $upstreamMap
                }

                # cobertura
                $targetRel = if ($sourceEntry.TargetFileName) {
                    Join-Path $sourceEntry.TargetDir $sourceEntry.TargetFileName
                }
                else {
                    Join-Path $sourceEntry.TargetDir ([System.IO.Path]::GetFileName($path))
                }
                $targetPath = Join-Path $repoPath $targetRel
                $targetExists = Test-Path -LiteralPath $targetPath -PathType Leaf
                $missing = [System.Collections.Generic.List[string]]::new()
                $extra = [System.Collections.Generic.List[string]]::new()

                if ($sourceEntry.CoverageMode -eq 'ledger' -and $null -ne $ledgerCovered) {
                    foreach ($key in $baseMap.Keys) {
                        if (-not $ledgerCovered.ContainsKey($key)) { $missing.Add($key) }
                    }
                }
                else {
                    $targetMap = New-OrdinalMap
                    if ($targetExists) {
                        $targetContent = Read-WorkingText -Path $targetPath
                        if ($null -ne $targetContent) {
                            try {
                                $targetMap = (Get-KeyMapForContent -Content $targetContent -SourceEntry $sourceEntry).Keys
                            }
                            catch {
                                $result.Warnings += "Alvo pt-BR ilegível em ${targetRel}: $($_.Exception.Message)"
                            }
                        }
                    }
                    else {
                        if ($baseMap.Count -gt 0) {
                            $result.Warnings += "Arquivo alvo ausente: $($targetRel)"
                        }
                    }

                    foreach ($key in $baseMap.Keys) {
                        if (-not $targetMap.ContainsKey($key)) { $missing.Add($key) }
                    }
                    foreach ($key in $targetMap.Keys) {
                        if (-not $upstreamMap.ContainsKey($key)) { $extra.Add($key) }
                    }
                }

                $totalAdded += $delta.Added.Count
                $totalModified += $delta.Modified.Count
                $totalRemoved += $delta.Removed.Count
                $totalMissing += $missing.Count
                $totalBaseKeys += $baseMap.Count
                $totalExtra += $extra.Count

                $files.Add([ordered]@{
                    path         = $path
                    target       = ($targetRel -replace '\\', '/')
                    targetExists = $targetExists
                    baseKeys     = $baseMap.Count
                    upstreamKeys = $upstreamMap.Count
                    added        = @($delta.Added)
                    modified     = @($delta.Modified)
                    removed      = @($delta.Removed)
                    missing      = @($missing | Sort-Object)
                    extra        = @($extra | Sort-Object)
                    warning      = $fileWarning
                })
            }
        }

        $result.Files = @($files)
        $result.Added = $totalAdded
        $result.Modified = $totalModified
        $result.Removed = $totalRemoved
        $result.Pending = $totalAdded + $totalModified
        $result.BaseKeyCount = $totalBaseKeys
        $result.MissingKeys = $totalMissing
        $result.ExtraKeys = $totalExtra

        if ($totalBaseKeys -gt 0) {
            $covered = [Math]::Max(0, $totalBaseKeys - $totalMissing)
            $result.CoveragePercent = [Math]::Round(($covered / $totalBaseKeys) * 100.0, 1)
        }
        else {
            $result.CoveragePercent = 100.0
        }

        # --- status ---
        if (-not $result.UpstreamRef) {
            $result.Status = 'Sem remoto'
        }
        elseif ($result.Pending -gt 0) {
            $result.Status = 'Novas strings'
        }
        elseif ($result.Removed -gt 0) {
            $result.Status = 'Removidas'
        }
        elseif ($result.MissingKeys -gt 0) {
            $result.Status = 'Lacunas pt-BR'
        }
        else {
            $result.Status = 'Atualizado'
        }
    }
    catch {
        $result.Status = 'Erro'
        $result.Error = $_.Exception.Message
    }

    return $result
}

# ---------------------------------------------------------------------------
# Apresentação
# ---------------------------------------------------------------------------

function Get-RemoteIndicator {
    param([Parameter(Mandatory)]$RepoResult)
    if (-not $RepoResult.UpstreamRef) { return 'sem' }
    if ($RepoResult.Ahead -eq 0 -and $RepoResult.Behind -eq 0) { return '=' }
    $parts = @()
    if ($RepoResult.Ahead -gt 0) { $parts += ('↑' + $RepoResult.Ahead) }
    if ($RepoResult.Behind -gt 0) { $parts += ('↓' + $RepoResult.Behind) }
    return ($parts -join ' ')
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'Atualizado' { return 'Green' }
        'Novas strings' { return 'Yellow' }
        'Removidas' { return 'Magenta' }
        'Lacunas pt-BR' { return 'DarkYellow' }
        'Sem remoto' { return 'DarkGray' }
        default { return 'Red' }
    }
}

function Write-KeyList {
    param(
        [string]$Label,
        [string[]]$Keys,
        [int]$Limit,
        [string]$Color
    )
    if ($Keys.Count -eq 0) { return }
    $shown = @($Keys | Select-Object -First $Limit)
    $suffix = if ($Keys.Count -gt $shown.Count) { " (+$($Keys.Count - $shown.Count))" } else { '' }
    Write-Ui ("      {0}{1}: {2}{3}" -f $Label, $suffix, ($shown -join ', '), '') $Color
}

function Write-Report {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$RootPath,
        [int]$DetailLimit,
        [bool]$IsReadOnly,
        [bool]$IsNoFetch
    )

    Write-Ui ''
    Write-Ui '========================================================================================' 'DarkCyan'
    Write-Ui (' DELTA SYNC pt-BR  |  v{0}  |  {1}' -f $script:Version, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'DarkCyan'
    Write-Ui (' Raiz: {0}' -f $RootPath) 'DarkCyan'
    $modeText = if ($IsReadOnly) {
        'SOMENTE LEITURA (sem fetch, sem escrita)'
    }
    elseif ($IsNoFetch) {
        'OFFLINE (-NoFetch: sem rede, refs locais)'
    }
    else {
        'NORMAL (fetch + análise)'
    }
    Write-Ui (' Modo: {0}' -f $modeText) 'DarkCyan'
    Write-Ui '========================================================================================' 'DarkCyan'
    Write-Ui ''

    $header = '{0,-13} {1,-11} {2,-8} {3,-9} {4,-15} {5,6} {6,7} {7,8} {8,-13} {9,-9}' -f `
        'PROJETO', 'BRANCH', 'HEAD', 'REMOTO', 'ESTADO', 'NOVAS', 'MODIF.', 'REMOV.', 'COBERTURA', 'LOCAL'
    Write-Ui $header 'White'
    Write-Ui ('-' * 108) 'DarkGray'

    foreach ($result in $Results) {
        $coverageText = if ($result.BaseKeyCount -eq 0) { 'n/a' } else { Format-Percent -Value $result.CoveragePercent -Missing $result.MissingKeys }
        $dirtyText = if ($result.DirtyFiles.Count -eq 0) { 'limpo' } else { "$($result.DirtyFiles.Count) alt." }
        $line = '{0,-13} {1,-11} {2,-8} {3,-9} {4,-15} {5,6} {6,7} {7,8} {8,-13} {9,-9}' -f `
            (Format-Cell $result.Name 13),
            (Format-Cell $result.Branch 11),
            (Format-Cell $result.HeadShort 8),
            (Format-Cell (Get-RemoteIndicator -RepoResult $result) 9),
            (Format-Cell $result.Status 15),
            $result.Added,
            $result.Modified,
            $result.Removed,
            (Format-Cell $coverageText 13),
            (Format-Cell $dirtyText 9)

        Write-Ui $line (Get-StatusColor $result.Status)
    }

    Write-Ui ''
    Write-Ui 'LEGENDA' 'DarkGray'
    Write-Ui '  Atualizado      nenhuma chave nova/alterada no upstream desde a base.' 'Gray'
    Write-Ui '  Novas strings   há chaves adicionadas ou modificadas para traduzir.' 'Gray'
    Write-Ui '  Removidas       o upstream removeu chaves; há traduções órfãs para revisar.' 'Gray'
    Write-Ui '  Lacunas pt-BR   o upstream não mudou, mas faltam chaves no pt-BR.' 'Gray'
    Write-Ui '  REMOTO          = igual | ↑N commits locais à frente | ↓N commits upstream ausentes.' 'Gray'
    Write-Ui '  COBERTURA       % das chaves da base presentes no pt-BR (N = faltando).' 'Gray'
    Write-Ui ''

    $pendingRepos = @($Results | Where-Object { $_.Pending -gt 0 -or $_.Removed -gt 0 })
    if ($pendingRepos.Count -gt 0) {
        Write-Ui 'DETALHES DAS PENDÊNCIAS' 'DarkCyan'
        foreach ($result in $pendingRepos) {
            if ($result.Status -eq 'Erro') { continue }
            Write-Ui ''
            Write-Ui ("  {0}  [{1}]  base={2} ({3})  upstream={4}" -f `
                $result.Name, $result.Status, $result.BaseCommit.Substring(0, [Math]::Min(9, $result.BaseCommit.Length)),
                $result.BaseSource, $result.UpstreamRef) 'White'
            foreach ($file in $result.Files) {
                if ($file.Added.Count -eq 0 -and $file.Modified.Count -eq 0 -and $file.Removed.Count -eq 0) { continue }
                Write-Ui ("    {0}" -f $file.Path) 'Gray'
                if ($file.Added.Count -gt 0 -or $file.Modified.Count -gt 0 -or $file.Removed.Count -gt 0) {
                    Write-Ui ("      +{0} novas   ~{1} alteradas   -{2} removidas" -f `
                        $file.Added.Count, $file.Modified.Count, $file.Removed.Count) 'DarkGray'
                }
                Write-KeyList -Label 'novas' -Keys $file.Added -Limit $DetailLimit -Color 'Yellow'
                Write-KeyList -Label 'alteradas' -Keys $file.Modified -Limit $DetailLimit -Color 'Yellow'
                Write-KeyList -Label 'removidas' -Keys $file.Removed -Limit $DetailLimit -Color 'Magenta'
            }
        }
        Write-Ui ''
    }

    $gapRepos = @($Results | Where-Object { $_.MissingKeys -gt 0 })
    if ($gapRepos.Count -gt 0) {
        Write-Ui 'LACUNAS DE COBERTURA pt-BR' 'DarkCyan'
        foreach ($result in $gapRepos) {
            Write-Ui ("  {0}: {1} chave(s) da base sem tradução" -f $result.Name, $result.MissingKeys) 'DarkYellow'
            foreach ($file in $result.Files) {
                if ($file.Missing.Count -eq 0) { continue }
                $shown = @($file.Missing | Select-Object -First $DetailLimit)
                $suffix = if ($file.Missing.Count -gt $shown.Count) { " (+$($file.Missing.Count - $shown.Count))" } else { '' }
                Write-Ui ("    {0}{1}: {2}" -f $file.Path, $suffix, ($shown -join ', ')) 'DarkGray'
            }
        }
        Write-Ui ''
    }

    $errored = @($Results | Where-Object { $_.Status -eq 'Erro' })
    if ($errored.Count -gt 0) {
        Write-Ui 'ERROS' 'Red'
        foreach ($result in $errored) {
            Write-Ui ("  {0}: {1}" -f $result.Name, $result.Error) 'Red'
        }
        Write-Ui ''
    }

    $dirtyRepos = @($Results | Where-Object { $_.DirtyFiles.Count -gt 0 })
    $sourceDirtyRepos = @($Results | Where-Object { $_.SourceDirtyFiles.Count -gt 0 })
    if ($dirtyRepos.Count -gt 0) {
        Write-Ui 'PROTEÇÃO DO TRABALHO LOCAL' 'DarkCyan'
        Write-Ui ("  {0} repositório(s) com alterações não commitadas. Nenhum pull/merge/checkout/reset foi executado." -f $dirtyRepos.Count) 'Gray'
        foreach ($result in $dirtyRepos) {
            Write-Ui ("    {0}: {1} arquivo(s) — inclui traduções em andamento" -f $result.Name, $result.DirtyFiles.Count) 'DarkGray'
        }
        if ($sourceDirtyRepos.Count -gt 0) {
            Write-Ui '  ATENÇÃO: arquivo-fonte em inglês com alteração local (pode ser trabalho não commitado):' 'Yellow'
            foreach ($result in $sourceDirtyRepos) {
                Write-Ui ("    {0}: {1}" -f $result.Name, ($result.SourceDirtyFiles -join ', ')) 'Yellow'
            }
        }
        Write-Ui ''
    }

    $fetchFailed = @($Results | Where-Object { $_.FetchError })
    if ($fetchFailed.Count -gt 0) {
        Write-Ui 'FALHAS DE FETCH (análise feita com referências locais)' 'Yellow'
        foreach ($result in $fetchFailed) {
            Write-Ui ("  {0}: {1}" -f $result.Name, $result.FetchError) 'Yellow'
        }
        Write-Ui ''
    }

    $baselineNote = @($Results | Where-Object { $_.BaseSource -ne 'baseline' -and $_.Status -ne 'Erro' })
    if ($baselineNote.Count -gt 0) {
        Write-Ui 'BASE DA COMPARAÇÃO' 'DarkCyan'
        Write-Ui '  Sem baseline fixado para parte dos repositórios: a base usada é o HEAD local.' 'Gray'
        Write-Ui '  Depois de concluir um ciclo de tradução, rode: .\sync-check.ps1 -UpdateBaseline' 'Gray'
        Write-Ui ''
    }

    $atualizados = @($Results | Where-Object { $_.Status -eq 'Atualizado' }).Count
    $novas = @($Results | Where-Object { $_.Status -eq 'Novas strings' }).Count
    $removidas = @($Results | Where-Object { $_.Status -eq 'Removidas' }).Count
    $lacunas = @($Results | Where-Object { $_.Status -eq 'Lacunas pt-BR' }).Count
    $erros = $errored.Count
    $totalPendentes = [int](Get-SumProperty -Items $Results -Name 'Pending')
    if ($null -eq $totalPendentes) { $totalPendentes = 0 }

    Write-Ui 'RESUMO' 'DarkCyan'
    Write-Ui ("  Analisados: {0}  |  Atualizados: {1}  |  Novas strings: {2}  |  Removidas: {3}  |  Lacunas: {4}  |  Erros: {5}" -f `
        $Results.Count, $atualizados, $novas, $removidas, $lacunas, $erros) 'White'
    Write-Ui ("  Chaves pendentes de tradução: {0}" -f $totalPendentes) 'White'

    if ($novas -gt 0) {
        Write-Ui ''
        Write-Ui 'PRÓXIMO PASSO' 'DarkCyan'
        Write-Ui '  Abra a sessão isolada do projeto e use o prompt correspondente em GUIA_ATUALIZACAO.md.' 'Gray'
        Write-Ui '  Para obter o delta em JSON: .\sync-check.ps1 -Repo <nome> -Json' 'Gray'
    }
    Write-Ui ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$rootPath = if ([string]::IsNullOrWhiteSpace($Root)) { (Get-Location).Path } else { $Root }
$rootPath = [System.IO.Path]::GetFullPath($rootPath)

if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    [Console]::Error.WriteLine("Raiz inexistente: $rootPath")
    exit 2
}

if ($ReadOnly -and $UpdateBaseline) {
    [Console]::Error.WriteLine('Parâmetros incompatíveis: -ReadOnly não pode ser combinado com -UpdateBaseline.')
    exit 2
}

if ($Force -and -not $UpdateBaseline) {
    [Console]::Error.WriteLine('O parâmetro -Force só tem efeito com -UpdateBaseline.')
    exit 2
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    [Console]::Error.WriteLine('Git não encontrado no PATH.')
    exit 2
}

$selectedConfigs = $script:RepoConfigs
if ($Repo) {
    $wanted = @(
        $Repo |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    $unknown = @($wanted | Where-Object { $name = $_; -not ($script:RepoConfigs | Where-Object { $_.Name -eq $name }) })
    if ($unknown.Count -gt 0) {
        [Console]::Error.WriteLine("Repositório(s) desconhecido(s): $($unknown -join ', ')")
        [Console]::Error.WriteLine("Válidos: $($script:RepoConfigs.Name -join ', ')")
        exit 2
    }
    $selectedConfigs = @($script:RepoConfigs | Where-Object { $wanted -contains $_.Name })
}

$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'never'
# Evita que operações opcionais (ex.: refresh do índice pelo git status)
# escrevam em .git durante o modo somente leitura.
$env:GIT_OPTIONAL_LOCKS = '0'

$exitCode = 0
$results = [System.Collections.Generic.List[object]]::new()
$baselineUpdated = [System.Collections.Generic.List[string]]::new()

try {
    Initialize-TempDir

    if (-not $Json) {
        Write-Ui ("Delta Sync pt-BR v{0} — analisando {1} repositório(s)..." -f $script:Version, $selectedConfigs.Count) 'DarkCyan'
    }

    $baseline = Get-Baseline -RootPath $rootPath

    foreach ($config in $selectedConfigs) {
        if (-not $Json) {
            Write-Ui ("  [{0}] consultando..." -f $config.Name) 'DarkGray'
        }
        $analysis = Get-RepoAnalysis -Config $config -RootPath $rootPath -Baseline $baseline
        $results.Add($analysis)
    }

    if ($UpdateBaseline) {
        $baselineObject = if ($baseline) { $baseline } else {
            [ordered]@{
                schemaVersion = 1
                updatedAt     = ''
                repos         = [ordered]@{}
            }
        }
        if (-not ($baselineObject['repos'] -is [System.Collections.IDictionary])) {
            $baselineObject['repos'] = [ordered]@{}
        }

        foreach ($result in $results) {
            if ($result.Status -eq 'Erro' -or $result.Status -eq 'Sem remoto') {
                if (-not $Json) {
                    Write-Ui ("  [{0}] baseline não atualizado: {1}" -f $result.Name, $result.Status) 'DarkYellow'
                }
                continue
            }
            if (($result.Pending -gt 0 -or $result.MissingKeys -gt 0) -and -not $Force) {
                if (-not $Json) {
                    Write-Ui ("  [{0}] baseline NÃO atualizado: {1} chave(s) pendente(s), {2} lacuna(s). Traduza, valide e commite antes, ou use -Force." -f `
                        $result.Name, $result.Pending, $result.MissingKeys) 'Yellow'
                }
                continue
            }
            if ($result.DirtyFiles.Count -gt 0 -and -not $Json) {
                Write-Ui ("  [{0}] aviso: há {1} alteração(ões) local(is) não commitada(s); recomenda-se commitar antes de fixar a base." -f `
                    $result.Name, $result.DirtyFiles.Count) 'DarkYellow'
            }
            $baselineObject['repos'][$result.Name] = [ordered]@{
                baseCommit  = $result.UpstreamCommit
                upstreamRef = $result.UpstreamRef
                updatedAt   = (Get-Date).ToString('o')
                note        = 'Base fixada após ciclo de sincronização'
            }
            $baselineUpdated.Add($result.Name)
            if (-not $Json) {
                Write-Ui ("  [{0}] baseline fixado em {1}" -f $result.Name, $result.UpstreamCommit.Substring(0, [Math]::Min(9, $result.UpstreamCommit.Length))) 'Green'
            }
        }

        if ($baselineUpdated.Count -gt 0) {
            $baselineObject['updatedAt'] = (Get-Date).ToString('o')
            Save-Baseline -RootPath $rootPath -Baseline $baselineObject
        }
    }

    if ($Json) {
        $summary = [ordered]@{
            analyzed        = $results.Count
            updated         = @($results | Where-Object { $_.Status -eq 'Atualizado' }).Count
            newStrings      = @($results | Where-Object { $_.Status -eq 'Novas strings' }).Count
            removals        = @($results | Where-Object { $_.Status -eq 'Removidas' }).Count
            gaps            = @($results | Where-Object { $_.Status -eq 'Lacunas pt-BR' }).Count
            errors          = @($results | Where-Object { $_.Status -eq 'Erro' }).Count
            pendingKeys     = [int](Get-SumProperty -Items $results.ToArray() -Name 'Pending')
            missingKeys     = [int](Get-SumProperty -Items $results.ToArray() -Name 'MissingKeys')
        }
        $document = [ordered]@{
            tool            = 'sync-check.ps1'
            version         = $script:Version
            generatedAt     = (Get-Date).ToString('o')
            root            = $rootPath
            mode            = if ($ReadOnly) { 'readonly' } elseif ($NoFetch) { 'nofetch' } else { 'normal' }
            summary         = $summary
            baselineUpdated = @($baselineUpdated)
            repos           = @($results | ForEach-Object {
                [ordered]@{
                    name            = $_.Name
                    branch          = $_.Branch
                    head            = $_.HeadCommit
                    headShort       = $_.HeadShort
                    upstreamRef     = $_.UpstreamRef
                    upstreamCommit  = $_.UpstreamCommit
                    baseCommit      = $_.BaseCommit
                    baseSource      = $_.BaseSource
                    ahead           = $_.Ahead
                    behind          = $_.Behind
                    status          = $_.Status
                    added           = $_.Added
                    modified        = $_.Modified
                    removed         = $_.Removed
                    pending         = $_.Pending
                    baseKeys        = $_.BaseKeyCount
                    missingKeys     = $_.MissingKeys
                    extraKeys       = $_.ExtraKeys
                    coveragePercent = $_.CoveragePercent
                    dirtyFiles      = @($_.DirtyFiles)
                    sourceDirty     = @($_.SourceDirtyFiles)
                    fetchError      = $_.FetchError
                    error           = $_.Error
                    warnings        = @($_.Warnings)
                    files           = @($_.Files)
                }
            })
        }
        $jsonText = $document | ConvertTo-Json -Depth 20
        [Console]::Out.WriteLine($jsonText)
    }
    else {
        Write-Report -Results $results.ToArray() -RootPath $rootPath -DetailLimit $DetailLimit `
            -IsReadOnly:$ReadOnly -IsNoFetch:$NoFetch
    }

    $errorCount = @($results | Where-Object { $_.Status -eq 'Erro' }).Count
    $pendingCount = [int](Get-SumProperty -Items $results.ToArray() -Name 'Pending')
    if ($null -eq $pendingCount) { $pendingCount = 0 }

    if ($errorCount -gt 0) {
        $exitCode = 2
    }
    elseif ($FailOnPending -and $pendingCount -gt 0) {
        $exitCode = 1
    }
    else {
        $exitCode = 0
    }
}
catch {
    [Console]::Error.WriteLine("Falha inesperada: $($_.Exception.Message)")
    $exitCode = 2
}
finally {
    Remove-TempDir
}

exit $exitCode
