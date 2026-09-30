<#
.SYNOPSIS
Select a model from a local server and launch Copilot or Claude Code.
.EXAMPLE
.\Start-LocalAgent.ps1
Shows a menu of available coding agents, then prompts for model selection.

.EXAMPLE
.\Start-LocalAgent.ps1 -Client Claude -BaseUrl http://localhost:1234

.EXAMPLE
.\Start-LocalAgent.ps1 -Client Claude -ServerType LlamaCpp
Connects to a running llama.cpp server at http://localhost:8080.

.EXAMPLE
.\Start-LocalAgent.ps1 -ShowVersion
Displays the current version of the script and exits.

.NOTES
Claude Code requires an Anthropic-compatible /v1/messages endpoint, such as
LM Studio 0.4.1 or later or a current llama.cpp server with --jinja enabled.
An OpenAI-only server is not sufficient.
#>

param(
    # Optional. When omitted, an interactive menu of supported coding agents is shown.
    [string]$Client,

    [ValidateNotNullOrEmpty()]
    [string]$BaseUrl = 'http://localhost:1234/v1',

    # Used for model discovery/management and Claude Code; optional when auth is off.
    [string]$ClaudeAuthToken = $env:LM_API_TOKEN,

    [switch]$Help,

    # Display the script version and exit.
    [switch]$ShowVersion,

    # Other compatible servers manage their own model lifecycle.
    [ValidateSet('LMStudio', 'OpenAICompatible', 'LlamaCpp', 'llama.cpp')]
    [string]$ServerType = 'LMStudio'
)

# Single source of truth for the script version. Bump this on each release.
$Version = '0.1'

if ($ShowVersion) {
    "Local Agent Launcher version $Version"
    exit
}

if ($Help) {
    Get-Help $MyInvocation.MyCommand -Full
    exit
}

# Accept the project's spelling as an alias and use its default server port.
# An explicit BaseUrl always takes precedence, including custom ports/proxies.
if ($ServerType -eq 'llama.cpp') { $ServerType = 'LlamaCpp' }
if ($ServerType -eq 'LlamaCpp' -and -not $PSBoundParameters.ContainsKey('BaseUrl')) {
    $BaseUrl = 'http://localhost:8080/v1'
}

# -----------------------------------------------------------------------------
# Ensure the script's folder is on PATH so '.\Start-LocalAgent.ps1' can be run
# by name from any terminal (including VS Code). Running via a full path always
# works regardless of PATH, so this is just a non-fatal heads-up.
# -----------------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ($null -ne $scriptDir) {
    $pathEntries = @([Environment]::GetEnvironmentVariable('Path', 'User'),
                     [Environment]::GetEnvironmentVariable('Path', 'Machine')) |
        Where-Object { $_ }
    if ($scriptDir -notin $pathEntries) {
        Write-Host "The script's folder '$scriptDir' is not on the PATH environment variable." -ForegroundColor Yellow
        Write-Host "Add it so you can run '.\Start-LocalAgent.ps1' from any terminal or VS Code:" -ForegroundColor Yellow
        Write-Host "`$env:PATH += ';$scriptDir'" -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
# Configuration for supported coding agents.
# Add new clients here to extend the tool's functionality.
# -----------------------------------------------------------------------------
$ClientConfigs = [ordered]@{
    Copilot = @{
        DisplayName = 'Copilot'
        CommandName = 'copilot.exe'
        EnvVars = @{
            COPILOT_PROVIDER_BASE_URL = $null
            COPILOT_PROVIDER_TYPE      = 'openai'
            COPILOT_MODEL               = 'MODEL_PLACEHOLDER'
            COPILOT_OFFLINE             = 'true'
        }
    }
    Claude = @{
        DisplayName = 'Claude'
        CommandName = 'claude'
        EnvVars = @{
            ANTHROPIC_BASE_URL                = $null
            ANTHROPIC_AUTH_TOKEN              = $null
            ANTHROPIC_API_KEY                 = $null
            CLAUDE_CODE_OAUTH_TOKEN           = $null
            CLAUDE_CODE_USE_BEDROCK           = $null
            CLAUDE_CODE_USE_VERTEX            = $null
            CLAUDE_CODE_USE_FOUNDRY           = $null
            CLAUDE_CODE_USE_ANTHROPIC_AWS      = $null
            CLAUDE_CODE_USE_MANTLE            = $null
            ANTHROPIC_MODEL                   = 'MODEL_PLACEHOLDER'
            ANTHROPIC_DEFAULT_OPUS_MODEL      = 'MODEL_PLACEHOLDER'
            ANTHROPIC_DEFAULT_SONNET_MODEL    = 'MODEL_PLACEHOLDER'
            ANTHROPIC_DEFAULT_HAIKU_MODEL     = 'MODEL_PLACEHOLDER'
            ANTHROPIC_DEFAULT_FABLE_MODEL     = 'MODEL_PLACEHOLDER'
            ANTHROPIC_SMALL_FAST_MODEL        = 'MODEL_PLACEHOLDER'
            CLAUDE_CODE_SUBAGENT_MODEL        = 'MODEL_PLACEHOLDER'
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
            CLAUDE_CODE_ATTRIBUTION_HEADER    = '0'
        }
    }
}

# Fetch the model IDs advertised by the server.
function Get-Models([string]$openAiBaseUrl, [hashtable]$headers) {
    try {
        $json = Invoke-RestMethod -Uri "$openAiBaseUrl/models" -Headers $headers -TimeoutSec 15 -ErrorAction Stop
    } catch {
        throw "Failed to fetch models from $openAiBaseUrl/models. Check the server address, server status, and authentication. $($_.Exception.Message)"
    }

    # The OpenAI /models endpoint wraps results in a `data` field; fall back to top-level if not.
    $modelEntries = if ($null -ne $json.data) { $json.data } else { $json }

    # Keep an array even when the server returns exactly one model.
    return @($modelEntries | ForEach-Object { $_.id } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

# Native discovery includes downloaded models even when just-in-time loading is off.
function Get-LMStudioModels([string]$serverUrl, [hashtable]$headers) {
    try {
        $json = Invoke-RestMethod -Uri "$serverUrl/api/v1/models" -Headers $headers -Method Get -TimeoutSec 15 -ErrorAction Stop
        if ($null -eq $json.models -or $json.models -isnot [System.Collections.IList]) {
            throw 'Invalid LM Studio response: expected a models array.'
        }
        foreach ($model in $json.models) {
            if ([string]::IsNullOrWhiteSpace($model.key) -or
                $model.type -notin @('llm', 'embedding') -or
                $null -eq $model.loaded_instances -or
                $model.loaded_instances -isnot [System.Collections.IList]) {
                throw 'Invalid LM Studio model entry: expected key, type, and loaded_instances.'
            }
            foreach ($instance in $model.loaded_instances) {
                if ([string]::IsNullOrWhiteSpace($instance.id)) {
                    throw 'Invalid LM Studio loaded instance: missing id.'
                }
            }
        }
        return $json.models
    } catch {
        throw "Failed to fetch models from $serverUrl/api/v1/models. Check LM Studio's server, API version, and authentication. For llama.cpp, use -ServerType LlamaCpp; for other servers, use -ServerType OpenAICompatible. $($_.Exception.Message)"
    }
}

# Identify a well-known local model server from its URL so the agent menu can show
# which backend each client is pointing at. Explicit llama.cpp mode takes priority;
# otherwise retain the port hints for LM Studio and Ollama.
function Get-ServerLabel([string]$baseUrl, [string]$serverType) {
    if ($serverType -eq 'LlamaCpp') { return 'llama.cpp' }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { return $null }
    try {
        $uri = [uri]$baseUrl
    } catch {
        return $null
    }
    switch ($uri.Port) {
        1234   { return 'LM Studio' }
        11434  { return 'Ollama' }
        default { return $null }
    }
}

# Load a model and return its confirmed instance ID for inference.
function Load-Model([string]$serverUrl, [hashtable]$headers, [string]$modelId) {
    try {
        Write-Host "Loading model: $modelId..." -ForegroundColor Cyan
        $body = @{ model = $modelId } | ConvertTo-Json
        $json = Invoke-RestMethod -Uri "$serverUrl/api/v1/models/load" -Headers $headers -Body $body -ContentType 'application/json' -Method Post -TimeoutSec 600 -ErrorAction Stop
        if ($json.status -cne 'loaded' -or [string]::IsNullOrWhiteSpace($json.instance_id)) {
            throw 'LM Studio did not confirm a loaded model instance.'
        }
        Write-Host "Model loaded successfully." -ForegroundColor Green
        return $json.instance_id
    } catch {
        throw "Failed to load model $modelId. Error: $($_.Exception.Message)"
    }
}

# An instance ID can differ from its model's key.
function Unload-Model([string]$serverUrl, [hashtable]$headers, [string]$instanceId) {
    try {
        Write-Host "Unloading model instance: $instanceId..." -ForegroundColor Cyan
        $body = @{ instance_id = $instanceId } | ConvertTo-Json
        $json = Invoke-RestMethod -Uri "$serverUrl/api/v1/models/unload" -Headers $headers -Body $body -ContentType 'application/json' -Method Post -TimeoutSec 60 -ErrorAction Stop
        if ($json.instance_id -cne $instanceId) {
            throw 'LM Studio did not confirm the requested instance was unloaded.'
        }
        Write-Host "Model unloaded successfully." -ForegroundColor Green
    } catch {
        throw "Failed to unload model instance $instanceId. Error: $($_.Exception.Message)"
    }
}

# Ensure the selected language model is loaded and return its inference ID.
function Ensure-ModelLoaded(
    [string]$serverUrl,
    [hashtable]$headers,
    [string]$selectedModel
) {
    # Refresh after the menu: another client may have changed the loaded models.
    $models = @(Get-LMStudioModels -serverUrl $serverUrl -headers $headers)
    $selected = @($models | Where-Object { $_.type -eq 'llm' -and $_.key -ceq $selectedModel })
    if ($selected.Count -ne 1) {
        throw "Selected model '$selectedModel' is no longer uniquely available in LM Studio. Select a model again."
    }

    # Free memory occupied by other language models; leave embedding models alone.
    foreach ($model in $models) {
        if ($model.type -eq 'llm' -and $model.key -cne $selectedModel) {
            foreach ($instance in $model.loaded_instances) {
                Unload-Model -serverUrl $serverUrl -headers $headers -instanceId $instance.id
            }
        }
    }

    if ($selected[0].loaded_instances.Count -gt 0) {
        Write-Host "Selected model '$selectedModel' is already loaded." -ForegroundColor Green
        return $selected[0].loaded_instances[0].id
    }
    return Load-Model -serverUrl $serverUrl -headers $headers -modelId $selectedModel
}

# -----------------------------------------------------------------------------
# Function to set environment variables and launch the client.
# -----------------------------------------------------------------------------
function Invoke-Client(
    [Parameter(Mandatory=$true)] [string]$Client,
    [Parameter(Mandatory=$true)] [System.Management.Automation.CommandInfo]$command,
    [Parameter(Mandatory=$true)] [string]$selectedModel,
    [Parameter(Mandatory=$true)] [string]$serverUrl,
    [Parameter(Mandatory=$true)] [string]$openAiBaseUrl,
    [string]$ClaudeAuthToken,
    [hashtable]$headers,
    [string]$ServerType
) {
    $config = $ClientConfigs[$Client]
    $clientEnvironment = @{}

    # LM Studio clients must use a confirmed instance before launching, on any host.
    if ($ServerType -eq 'LMStudio') {
        $selectedModel = Ensure-ModelLoaded -serverUrl $serverUrl -headers $headers -selectedModel $selectedModel
    }

    # Map the environment variables from configuration.
    foreach ($key in $config.EnvVars.Keys) {
        $val = $config.EnvVars[$key]

        # Handle specific dynamic values that depend on input parameters.
        if ($key -eq 'ANTHROPIC_BASE_URL') { $val = $serverUrl }
        elseif ($key -eq 'ANTHROPIC_AUTH_TOKEN') { $val = $ClaudeAuthToken }
        elseif ($key -eq 'COPILOT_PROVIDER_BASE_URL') { $val = $openAiBaseUrl }
        # Apply the selected model to the client and its model aliases.
        if ($val -eq 'MODEL_PLACEHOLDER') { $val = $selectedModel }

        $clientEnvironment[$key] = $val
    }

    # Child processes inherit these values; restore the caller's environment on exit.
    $previousEnvironment = @{}
    foreach ($name in $clientEnvironment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        foreach ($name in $clientEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $clientEnvironment[$name], 'Process')
        }

        Write-Host "Launching $Client..." -ForegroundColor Cyan
        if ($Client -eq 'Claude') {
            Write-Host "Using $serverUrl/v1/messages (requires an Anthropic-compatible server)." -ForegroundColor Cyan
            # Run in this terminal so Claude Code can read input and use the current project.
            & $command.Source --model $selectedModel
            if ($LASTEXITCODE -ne 0) {
                throw "Claude Code exited with code $LASTEXITCODE."
            }
        } else {
            Start-Process -FilePath $command.Source -ErrorAction Stop
        }
    } finally {
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
}

# -----------------------------------------------------------------------------
# Standalone helper: check whether the selected client (Copilot CLI or Claude
# Code) is installed on this machine.
# Returns the resolved command (a CommandInfo) so the caller can launch it.
# Throws a helpful, install-hint error when the client is missing from PATH.
# -----------------------------------------------------------------------------
function Get-ClientCommand([string]$Client) {
    $config = $ClientConfigs[$Client]
    if ($null -eq $config) { throw "Unknown client '$Client'." }

    $commandName = $config.CommandName
    $command = Get-Command $commandName -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        if ($Client -eq 'Claude') {
            throw "Claude Code was not found on PATH. Install it with: winget install Anthropic.ClaudeCode. Then open a new terminal."
        }
        throw "$commandName was not found on PATH. Please check your installation and then open a new terminal."
    }
    return $command
}

# -----------------------------------------------------------------------------
# Main script logic
# -----------------------------------------------------------------------------

# Resolve the coding agent: use -Client when given, otherwise show a menu.
if (-not $PSBoundParameters.ContainsKey('Client')) {
    Write-Host "--- Select a coding agent ---" -ForegroundColor Cyan
    # Identify the backend so each agent line can show which server it points at.
    $serverLabel = Get-ServerLabel -baseUrl $BaseUrl -serverType $ServerType

    # Show the server address once above the list so each agent line stays short.
    Write-Host "Server: $BaseUrl" -ForegroundColor DarkGray
    $clientKeys = @($ClientConfigs.Keys)
    for ($i = 0; $i -lt $clientKeys.Count; $i++) {
        $agent = $ClientConfigs[$clientKeys[$i]]
        if ($serverLabel) {
            Write-Host ("{0}. {1} [{2}]" -f ($i + 1), $agent.DisplayName, $serverLabel) -ForegroundColor Green
        } else {
            Write-Host ("{0}. {1}" -f ($i + 1), $agent.DisplayName) -ForegroundColor Green
        }
    }
    $agentChoice = Read-Host "`nSelect an agent (number)"
    $agentIndex = 0
    if (-not [int]::TryParse($agentChoice, [ref]$agentIndex) -or $agentIndex -lt 1 -or $agentIndex -gt $clientKeys.Count) {
        throw 'Invalid selection. Please restart the script and choose a listed agent number.'
    }
    $Client = $clientKeys[$agentIndex - 1]
} elseif (-not $ClientConfigs.Contains($Client)) {
    throw "Unknown client '$Client'. Available clients: $($ClientConfigs.Keys -join ', ')."
}

$serverUri = $null
if (-not [uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$serverUri) -or
    $serverUri.Scheme -notin @('http', 'https') -or
    $serverUri.Query -or $serverUri.Fragment -or $serverUri.UserInfo) {
    throw 'BaseUrl must be an HTTP(S) server URL without credentials, a query, or a fragment.'
}

# Copilot uses /v1; Claude appends /v1/messages to the server root.
$serverUrl = $BaseUrl.TrimEnd('/') -replace '/v1$', ''
$openAiBaseUrl = "$serverUrl/v1"
# Resolve the installed client executable (throws with an install hint if missing).
$command = Get-ClientCommand -Client $Client

$headers = @{}
if ($Client -eq 'Claude') {
    if ([string]::IsNullOrWhiteSpace($ClaudeAuthToken)) {
        $ClaudeAuthToken = 'lmstudio'
    }
}
if (-not [string]::IsNullOrWhiteSpace($ClaudeAuthToken)) {
    $headers.Authorization = "Bearer $ClaudeAuthToken"
}

# Keep the helper output as an array, even when it returns only one model.
$loadedInstances = @{}
if ($ServerType -eq 'LMStudio') {
    # Retain each llm's loaded instances so the selection list can show what is already running.
    $lmModels = @(Get-LMStudioModels -serverUrl $serverUrl -headers $headers |
        Where-Object { $_.type -eq 'llm' })
    foreach ($model in $lmModels) {
        if ($null -ne $model.loaded_instances -and $model.loaded_instances.Count -gt 0) {
            $loadedInstances[$model.key] = @($model.loaded_instances | ForEach-Object { $_.id })
        }
    }
    $models = @($lmModels | ForEach-Object { $_.key })
} else {
    $models = @(Get-Models -openAiBaseUrl $openAiBaseUrl -headers $headers)
}
if ($models.Count -eq 0) {
    throw "No models were returned by $serverUrl. Make a language model available on the server and try again."
}

Write-Host "--- $Client Model Selection ---" -ForegroundColor Cyan
for ($i = 0; $i -lt $models.Count; $i++) {
    $modelId = $models[$i]
    if ($loadedInstances.ContainsKey($modelId) -and $loadedInstances[$modelId].Count -gt 0) {
        Write-Host ("{0}. {1} (loaded: {2})" -f ($i + 1), $modelId, ($loadedInstances[$modelId] -join ', '))
    } else {
        Write-Host ("{0}. {1}" -f ($i + 1), $modelId)
    }
}
Write-Host ("{0}. Exit" -f ($models.Count + 1))

$choice = Read-Host "`nSelect a model (number)"
$exitOption = $models.Count + 1
if ($choice -eq $exitOption) {
    Write-Host "Exiting..." -ForegroundColor Yellow
    exit
}

$modelIndex = 0
if (-not [int]::TryParse($choice, [ref]$modelIndex) -or $modelIndex -lt 1 -or $modelIndex -gt $models.Count) {
    throw 'Invalid selection. Please restart the script and choose a listed model number or Exit.'
}
$selectedModel = $models[$modelIndex - 1]
Write-Host "Selected: $selectedModel" -ForegroundColor Green

Invoke-Client `
    -Client $Client `
    -command $command `
    -selectedModel $selectedModel `
    -serverUrl $serverUrl `
    -openAiBaseUrl $openAiBaseUrl `
    -ClaudeAuthToken $ClaudeAuthToken `
    -headers $headers `
    -ServerType $ServerType
