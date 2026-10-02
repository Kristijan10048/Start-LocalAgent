$launcherPath = Join-Path $PSScriptRoot 'Start-LocalAgent.ps1'

Describe 'Local Agent Launcher' {
    function New-TestModel([string]$Key, [string[]]$Instances = @(), [string]$Type = 'llm') {
        @{ key = $Key; type = $Type; max_context_length = 131072; loaded_instances = @($Instances | ForEach-Object { @{ id = $_; config = @{ context_length = 32768 } } }) }
    }
    # Exercise the real launcher without starting a client or contacting a server.
    $stubPath = Join-Path $TestDrive 'claude.ps1'
    @'
$global:ModelLauncherTestLaunch = @{
    Arguments = @($args)
    Directory = $PWD.Path
    Environment = @{}
}
Get-ChildItem Env: | ForEach-Object {
    $global:ModelLauncherTestLaunch.Environment[$_.Name] = $_.Value
}
if ($global:ModelLauncherTestThrow) { throw 'Simulated launch failure' }
exit $global:ModelLauncherTestExitCode
'@ | Set-Content -LiteralPath $stubPath
    $stubCommand = Get-Command $stubPath -CommandType ExternalScript

    $environmentNames = @(
        'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY',
        'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX',
        'CLAUDE_CODE_USE_FOUNDRY', 'CLAUDE_CODE_USE_ANTHROPIC_AWS', 'CLAUDE_CODE_USE_MANTLE',
        'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL',
        'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_FABLE_MODEL',
        'ANTHROPIC_SMALL_FAST_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL',
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'CLAUDE_CODE_ATTRIBUTION_HEADER',
        'CLAUDE_CODE_MAX_CONTEXT_TOKENS', 'DISABLE_COMPACT',
        'COPILOT_PROVIDER_BASE_URL', 'COPILOT_PROVIDER_TYPE', 'COPILOT_MODEL', 'COPILOT_OFFLINE'
    )

    BeforeEach {
        $script:savedEnvironment = @{}
        foreach ($name in $environmentNames) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, 'previous-value', 'Process')
        }
        $global:ModelLauncherTestState = @{ Command = $stubCommand }
        $global:ModelLauncherTestState.Response = @{ data = @(@{ id = 'qwen/local-coder' }) }
        $global:ModelLauncherTestState.PropsResponse = @{ default_generation_settings = @{ n_ctx = 65536 }; total_slots = 4 }
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(New-TestModel 'qwen/local-coder' @('qwen/local-coder')) }
        $global:ModelLauncherTestState.Requests = New-Object System.Collections.ArrayList
        $global:ModelLauncherTestState.ListCount = 0
        $global:ModelLauncherTestState.AgentSelection = '1'
        $global:ModelLauncherTestState.Selection = '1'
        $global:ModelLauncherTestState.MissingCommand = $false
        $global:ModelLauncherTestState.RequestFailure = $false
        $global:ModelLauncherTestLaunch = $null
        $global:ModelLauncherTestThrow = $false
        $global:ModelLauncherTestExitCode = 0
        Mock Get-Command {
            if (-not $global:ModelLauncherTestState.MissingCommand) { $global:ModelLauncherTestState.Command }
        } -ParameterFilter { $Name -eq 'claude' -or $Name -eq 'copilot.exe' }
        Mock Invoke-RestMethod {
            $state = $global:ModelLauncherTestState
            $state.Request = @{ Uri = $Uri; Headers = $Headers; Method = $Method; Body = $Body; ContentType = $ContentType; TimeoutSec = $(if ($TimeoutSec) { $TimeoutSec } else { $ConnectionTimeoutSeconds }) }
            [void]$state.Requests.Add($state.Request)
            if ($state.RequestFailure) { throw 'Simulated HTTP failure' }
            if ($Uri -like '*/api/v1/models') {
                $state.ListCount++
                if ($state.ListCount -gt 1 -and $state.StatusFailure) { throw 'Simulated status failure' }
                if ($state.ListCount -gt 1 -and $state.ContainsKey('RefreshResponse')) { return $state.RefreshResponse }
                return $state.NativeResponse
            }
            if ($Uri -like '*/api/v1/models/load') {
                if ($state.LoadFailure) { throw 'Simulated load failure' }
                if ($state.ContainsKey('LoadResponse')) { return $state.LoadResponse }
                return @{ status = 'loaded'; instance_id = ($Body | ConvertFrom-Json).model; load_config = @{ context_length = 16384 } }
            }
            if ($Uri -like '*/api/v1/models/unload') {
                if ($state.UnloadFailure) { throw 'Simulated unload failure' }
                if ($state.ContainsKey('UnloadResponse')) { return $state.UnloadResponse }
                return @{ instance_id = ($Body | ConvertFrom-Json).instance_id }
            }
            if ($Uri -like '*/v1/models') { return $state.Response }
            if ($Uri -like '*/props?model=*') {
                if ($state.PropsFailure) { throw 'Simulated props failure' }
                return $state.PropsResponse
            }
            throw "Unexpected endpoint: $Uri"
        }
        Mock Read-Host {
            if ($Prompt -like '*Select an agent*') {
                $global:ModelLauncherTestState.AgentSelection
            } else {
                $global:ModelLauncherTestState.Selection
            }
        }
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock Start-Process {
            $global:ModelLauncherTestLaunch = @{
                Url = $env:COPILOT_PROVIDER_BASE_URL
                Model = $env:COPILOT_MODEL
                Provider = $env:COPILOT_PROVIDER_TYPE
                Offline = $env:COPILOT_OFFLINE
                ClaudeUrl = $env:ANTHROPIC_BASE_URL
            }
        }
    }

    AfterEach {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name], 'Process')
        }
        Remove-Variable ModelLauncherTestLaunch, ModelLauncherTestThrow, ModelLauncherTestExitCode, ModelLauncherTestState -Scope Global
    }

    # Verifies that with a single available model, its full (un-normalized) ID is passed as --model, all Claude env vars are applied, and process-level environment variables are restored to their previous values.
    It 'keeps the complete ID when only one model is available and restores the environment' {
        & $launcherPath -Client Claude -ClaudeAuthToken ''
        $launch = $global:ModelLauncherTestLaunch
        $launch.Arguments.Count | Should Be 2
        $launch.Arguments[0] | Should Be '--model'
        $launch.Arguments[1] | Should Be 'qwen/local-coder'
        $launch.Directory | Should Be $PWD.Path
        $launch.Environment.ANTHROPIC_BASE_URL | Should Be 'http://localhost:1234'
        $launch.Environment.ANTHROPIC_AUTH_TOKEN | Should Be 'lmstudio'
        $launch.Environment.ANTHROPIC_API_KEY | Should BeNullOrEmpty
        $launch.Environment.CLAUDE_CODE_OAUTH_TOKEN | Should BeNullOrEmpty
        $launch.Environment.CLAUDE_CODE_USE_BEDROCK | Should BeNullOrEmpty
        $launch.Environment.CLAUDE_CODE_USE_VERTEX | Should BeNullOrEmpty
        $launch.Environment.CLAUDE_CODE_USE_FOUNDRY | Should BeNullOrEmpty
        $launch.Environment.CLAUDE_CODE_USE_ANTHROPIC_AWS | Should BeNullOrEmpty
        $launch.Environment.CLAUDE_CODE_USE_MANTLE | Should BeNullOrEmpty
        $launch.Environment.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC | Should Be '1'
        $launch.Environment.CLAUDE_CODE_ATTRIBUTION_HEADER | Should Be '0'
        $launch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be '32768'
        $launch.Environment.DISABLE_COMPACT | Should Be '1'
        foreach ($name in @('ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
                'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
                'ANTHROPIC_DEFAULT_FABLE_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL')) {
            $launch.Environment[$name] | Should Be 'qwen/local-coder'
        }
        $launch.Environment.COPILOT_MODEL | Should Be 'previous-value'
        foreach ($name in $environmentNames) {
            [Environment]::GetEnvironmentVariable($name, 'Process') | Should Be 'previous-value'
        }
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It -ParameterFilter { $Prompt -like '*Select an agent*' }
    }

    # Confirms BaseUrl normalization for both discovery and the Claude client: ANTHROPIC_BASE_URL becomes the root (no trailing /v1), requests target $Root/api/v1/models, and auth is sent as Bearer.
    It 'normalizes root and versioned URLs for discovery and Claude' -TestCases @(
        @{ Url = 'http://localhost:1234'; Root = 'http://localhost:1234' }
        @{ Url = 'http://localhost:1234/v1/'; Root = 'http://localhost:1234' }
        @{ Url = 'http://localhost:11434/'; Root = 'http://localhost:11434' }
        @{ Url = 'https://localhost:8443/proxy/v1/'; Root = 'https://localhost:8443/proxy' }
    ) {
        param($Url, $Root)
        & $launcherPath -Client Claude -BaseUrl $Url -ClaudeAuthToken 'test-token'
        $global:ModelLauncherTestLaunch.Environment.ANTHROPIC_BASE_URL | Should Be $Root
        $global:ModelLauncherTestLaunch.Environment.ANTHROPIC_AUTH_TOKEN | Should Be 'test-token'
        $global:ModelLauncherTestState.Request.Uri | Should Be "$Root/api/v1/models"
        $global:ModelLauncherTestState.Request.Headers.Authorization | Should Be 'Bearer test-token'
        Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly -Scope It
    }

    # Checks that blank, whitespace-only, null, and duplicate IDs are filtered out of the list so selection by number maps to a valid unique model.
    It 'filters empty and duplicate model IDs and selects a model from a bare list' {
        $global:ModelLauncherTestState.Response = @(@{ id = '' }, @{ id = ' ' }, @{ id = 'first' },
            @{ id = 'first' }, @{ id = 'second' }, @{ id = $null })
        $global:ModelLauncherTestState.Selection = '2'
        & $launcherPath -Client Claude -ServerType OpenAICompatible
        $global:ModelLauncherTestLaunch.Arguments[1] | Should Be 'second'
    }

    # Confirms an explicitly chosen -Client Copilot skips the agent menu entirely and passes through its server URL, model, provider type, offline flag, and Claude env passthrough.
    It 'launches explicit Copilot without the agent menu and keeps its server and settings' {
        & $launcherPath -Client Copilot
        $launch = $global:ModelLauncherTestLaunch
        $launch.Url | Should Be 'http://localhost:1234/v1'
        $launch.Model | Should Be 'qwen/local-coder'
        $launch.Provider | Should Be 'openai'
        $launch.Offline | Should Be 'true'
        $launch.ClaudeUrl | Should Be 'previous-value'
        $env:COPILOT_MODEL | Should Be 'previous-value'
        Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It -ParameterFilter { $Prompt -like '*Select an agent*' }
    }

    # Verifies that running with no arguments displays the agent selection menu, then a model menu, and launches the chosen client with the selected model.
    It 'shows the agent menu without parameters and launches the chosen agent and model' -TestCases @(
        @{ AgentChoice = '1'; Client = 'Copilot' }
        @{ AgentChoice = '2'; Client = 'Claude' }
    ) {
        param($AgentChoice, $Client)
        $global:ModelLauncherTestState.AgentSelection = $AgentChoice
        $global:ModelLauncherTestState.NativeResponse = @{ models = @((New-TestModel 'first-model'), (New-TestModel 'second-model')) }
        $global:ModelLauncherTestState.Selection = '2'

        & $launcherPath

        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq '1. Copilot [LM Studio]' -and $ForegroundColor -eq 'Green' }
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq '2. Claude [LM Studio]' -and $ForegroundColor -eq 'Green' }
        Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Prompt -like '*Select an agent*' }
        Assert-MockCalled Read-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Prompt -like '*Select a model*' }
        if ($Client -eq 'Claude') {
            $global:ModelLauncherTestLaunch.Arguments[1] | Should Be 'second-model'
            Assert-MockCalled Get-Command -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'claude' }
            Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
        } else {
            $global:ModelLauncherTestLaunch.Model | Should Be 'second-model'
            Assert-MockCalled Get-Command -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'copilot.exe' }
            Assert-MockCalled Start-Process -Times 1 -Exactly -Scope It
        }
    }

    # Confirms out-of-range, non-numeric, empty, and zero agent selections throw immediately without any HTTP request to the model server.
    It 'rejects invalid agent choices before contacting the model server' -TestCases @(
        @{ Choice = '0' }, @{ Choice = '3' }, @{ Choice = 'abc' }, @{ Choice = '' }
    ) {
        param($Choice)
        $global:ModelLauncherTestState.AgentSelection = $Choice
        { & $launcherPath } | Should Throw 'choose a listed agent number'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
    }

    # Checks that an unknown -Client value throws right away with no prompts or network calls.
    It 'rejects unsupported explicit clients without prompting' {
        { & $launcherPath -Client Unknown } | Should Throw "Unknown client 'Unknown'"
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    # Verifies selecting the Exit option leaves no client launched and does not modify any environment variables.
    It 'exits the model menu without launching or changing the environment' {
        $global:ModelLauncherTestState.Selection = '2'
        & $launcherPath -Client Claude
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        $env:ANTHROPIC_BASE_URL | Should Be 'previous-value'
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    # Confirms -ShowVersion prints the version string and exits before touching the server, prompts, or launch path.
    It 'displays the script version with -ShowVersion before contacting the server' {
        $output = (& $launcherPath -ShowVersion) -join ' '
        $output | Should Match 'Local Agent Launcher version 0.1'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        $env:ANTHROPIC_BASE_URL | Should Be 'previous-value'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }

    # Checks that non-numeric, out-of-range, fractional, and empty model numbers throw 'Invalid selection' without launching anything.
    It 'rejects invalid selections without launching a client' -TestCases @(
        @{ Choice = '0' }, @{ Choice = '-1' }, @{ Choice = '3' },
        @{ Choice = 'abc' }, @{ Choice = '1.5' }, @{ Choice = '999999999999999' }, @{ Choice = '' }
    ) {
        param($Choice)
        $global:ModelLauncherTestState.Selection = $Choice
        { & $launcherPath -Client Claude } | Should Throw 'Invalid selection'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        $env:ANTHROPIC_BASE_URL | Should Be 'previous-value'
    }

    # Verifies Get-ClientCommand throws the install hint for a missing claude executable before any model request is made.
    It 'reports a missing Claude installation before making a request' {
        $global:ModelLauncherTestState.MissingCommand = $true
        { & $launcherPath -Client Claude } | Should Throw 'Claude Code was not found on PATH'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    # Confirms a simulated HTTP failure surfaces 'Failed to fetch models' and no agent menu or prompts appear.
    It 'reports a failed server request without launching a client' {
        $global:ModelLauncherTestState.RequestFailure = $true
        { & $launcherPath -Client Claude } | Should Throw 'Failed to fetch models'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }

    # Checks that when the server returns no language models, the script throws before showing any selection menu.
    It 'reports an empty model list without prompting' {
        $global:ModelLauncherTestState.NativeResponse = @{ models = @() }
        { & $launcherPath -Client Claude } | Should Throw 'No models were returned'
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }

    # Verifies environment variables that were not set (null) are correctly restored to null after a simulated launch failure.
    It 'restores previously unset variables even if Claude fails to launch' {
        [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $null, 'Process')
        $global:ModelLauncherTestThrow = $true
        { & $launcherPath -Client Claude } | Should Throw 'Simulated launch failure'
        $env:ANTHROPIC_BASE_URL | Should BeNullOrEmpty
        $env:ANTHROPIC_AUTH_TOKEN | Should Be 'previous-value'
    }

    # Confirms a non-zero Claude exit propagates as an error including the code, and process env vars are restored.
    It 'reports a nonzero Claude exit code and restores the environment' {
        $global:ModelLauncherTestExitCode = 7
        { & $launcherPath -Client Claude } | Should Throw 'Claude Code exited with code 7'
        $env:ANTHROPIC_BASE_URL | Should Be 'previous-value'
    }

    # Checks that non-HTTP schemes, file paths, query strings, and fragments in BaseUrl throw before any network call.
    It 'rejects invalid server URLs before making a request' -TestCases @(
        @{ Url = 'not-a-url' }, @{ Url = 'file:///C:/models' },
        @{ Url = 'http://localhost:1234?query=value' }, @{ Url = 'http://localhost:1234/#fragment' }
    ) {
        param($Url)
        { & $launcherPath -Client Claude -BaseUrl $Url } | Should Throw 'BaseUrl must be'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    # Verifies the selected model is loaded via POST /api/v1/models/load when not already loaded; both Claude (--model/ANTHROPIC_MODEL) and Copilot (Model) receive the returned instance ID on LAN and localhost roots.
    It 'loads an unloaded model before launching either client on LAN or localhost' -TestCases @(
        @{ Client = 'Claude'; Root = 'http://192.168.1.179:1234' }
        @{ Client = 'Copilot'; Root = 'http://192.168.1.179:1234' }
        @{ Client = 'Claude'; Root = 'http://localhost:1234' }
        @{ Client = 'Copilot'; Root = 'http://localhost:1234' }
        @{ Client = 'Claude'; Root = 'https://models.example/proxy' }
    ) {
        param($Client, $Root)
        $global:ModelLauncherTestState.NativeResponse = '{"models":[{"key":"qwen/local-coder","type":"llm","loaded_instances":[]}]}' | ConvertFrom-Json
        $global:ModelLauncherTestState.LoadResponse = @{ status = 'loaded'; instance_id = 'custom-loaded-id'; load_config = @{ context_length = 49152 } }
        & $launcherPath -Client $Client -BaseUrl "$Root/v1/" -ClaudeAuthToken 'test-token'
        $requests = $global:ModelLauncherTestState.Requests
        $requests.Count | Should Be 3
        $requests[0].Uri | Should Be "$Root/api/v1/models"
        $requests[1].Uri | Should Be "$Root/api/v1/models"
        $requests[2].Uri | Should Be "$Root/api/v1/models/load"
        $requests[2].Method | Should Be 'Post'
        $requests[2].ContentType | Should Be 'application/json'
        ($requests[2].Body | ConvertFrom-Json).model | Should Be 'qwen/local-coder'
        ($requests[2].Body | ConvertFrom-Json).echo_load_config | Should Be $true
        $requests[2].TimeoutSec | Should BeGreaterThan 60
        foreach ($request in $requests) { $request.Headers.Authorization | Should Be 'Bearer test-token' }
        if ($Client -eq 'Claude') {
            $global:ModelLauncherTestLaunch.Arguments[1] | Should Be 'custom-loaded-id'
            $global:ModelLauncherTestLaunch.Environment.ANTHROPIC_MODEL | Should Be 'custom-loaded-id'
            $global:ModelLauncherTestLaunch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be '49152'
        } else {
            $global:ModelLauncherTestLaunch.Model | Should Be 'custom-loaded-id'
        }
    }

    # Simulate an absent folder without changing the user's persistent PATH.
    It 'warns in yellow when the script folder is missing from PATH' {
        Mock Split-Path { 'C:\nonexistent-test-path' } -ParameterFilter {
            $Parent -and $Path -eq $launcherPath
        }
        & $launcherPath -Client Claude
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter {
            $ForegroundColor -eq 'Yellow' -and $Object -like '*not on the PATH*'
        }
    }

    # Confirms that if the selected model already has a loaded instance, its instance ID is reused with no load/unload requests issued.
    It 'reuses an already loaded selection without loading or unloading it' {
        $global:ModelLauncherTestState.NativeResponse = '{"models":[{"key":"qwen/local-coder","type":"llm","loaded_instances":[{"id":"my-coder","config":{"context_length":24576}}]}]}' | ConvertFrom-Json
        & $launcherPath -Client Claude
        $global:ModelLauncherTestLaunch.Arguments[1] | Should Be 'my-coder'
        $global:ModelLauncherTestLaunch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be '24576'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'Post' }
    }

    # Shows which models are already loaded next to each entry, annotating the running instance id(s). Selecting Exit avoids any load/unload side effects.
    It 'marks currently loaded models in the selection list' {
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(
            (New-TestModel 'loaded-model' @('running-instance')),
            (New-TestModel 'fresh-model')
        ) }
        $global:ModelLauncherTestState.Selection = '3'  # Exit option for a two-model list.
        & $launcherPath -Client Copilot
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq '1. loaded-model (loaded: running-instance)' }
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq '2. fresh-model' }
    }

    # Checks that all instances of other llm models are unloaded (but embedding models are left untouched) before the selection is loaded and launched.
    It 'unloads every instance of other language models before loading the selection' {
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(
            (New-TestModel 'qwen/local-coder'),
            (New-TestModel 'other-model' @('old-instance-1', 'old-instance-2')),
            (New-TestModel 'another-model' @('old-instance-3')),
            (New-TestModel 'embedding-model' @('embedding-instance') 'embedding')
        ) }
        & $launcherPath -Client Claude
        $writes = @($global:ModelLauncherTestState.Requests | Where-Object { $_.Method -eq 'Post' })
        $writes.Count | Should Be 4
        for ($i = 0; $i -lt 3; $i++) {
            $writes[$i].Uri | Should Be 'http://localhost:1234/api/v1/models/unload'
            $writes[$i].ContentType | Should Be 'application/json'
            ($writes[$i].Body | ConvertFrom-Json).instance_id | Should Be "old-instance-$($i + 1)"
        }
        $writes[3].Uri | Should Be 'http://localhost:1234/api/v1/models/load'
        $global:ModelLauncherTestLaunch.Arguments[1] | Should Be 'qwen/local-coder'
        Assert-MockCalled Write-Host -Times 0 -Exactly -Scope It -ParameterFilter { $Object -like '*embedding-model*' }
    }

    # Verifies that when re-selecting an already-loaded model, its own instances are preserved and only other models' instances are unloaded.
    It 'keeps selected instances while unloading another language model' {
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(
            (New-TestModel 'qwen/local-coder' @('selected-1', 'selected-2')),
            (New-TestModel 'other-model' @('old-instance'))
        ) }
        & $launcherPath -Client Copilot
        $global:ModelLauncherTestLaunch.Model | Should Be 'selected-1'
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            $Uri -like '*/unload' -and ($Body | ConvertFrom-Json).instance_id -eq 'old-instance'
        }
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Uri -like '*/load' }
    }

    # Confirms a refresh of loaded models happens post-menu so any instance loaded by another client is reused instead of reloaded.
    It 'refreshes model state after the menu before deciding to load' {
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(New-TestModel 'qwen/local-coder') }
        $global:ModelLauncherTestState.RefreshResponse = @{ models = @(New-TestModel 'qwen/local-coder' @('recently-loaded')) }
        $global:ModelLauncherTestState.RefreshResponse.models[0].loaded_instances[0].config.context_length = 57344
        & $launcherPath -Client Claude
        $global:ModelLauncherTestLaunch.Arguments[1] | Should Be 'recently-loaded'
        $global:ModelLauncherTestLaunch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be '57344'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'Post' }
    }

    # Checks that when the selected model is no longer uniquely available, the script throws before unloading or loading anything.
    It 'stops before unloading if the selected model disappeared' {
        $global:ModelLauncherTestState.RefreshResponse = @{ models = @(New-TestModel 'other-model' @('keep-me')) }
        { & $launcherPath -Client Claude } | Should Throw 'no longer uniquely available'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'Post' }
    }

    # Verifies an invalid LM Studio status response aborts the flow with no mutation of loaded models.
    It 'stops on status errors without trying to load or unload' {
        $global:ModelLauncherTestState.StatusFailure = $true
        { & $launcherPath -Client Claude } | Should Throw 'Simulated status failure'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        $env:ANTHROPIC_MODEL | Should Be 'previous-value'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'Post' }
    }

    # Confirms various malformed refresh payloads (error field, missing models array, empty instance id) are rejected without mutating state.
    It 'rejects malformed status responses before changing any loaded model' -TestCases @(
        @{ Response = @{ error = 'unauthorized' } }
        @{ Response = @{ models = @(@{ key = 'qwen/local-coder'; type = 'llm' }) } }
        @{ Response = @{ models = @(@{ key = 'qwen/local-coder'; type = 'llm'; loaded_instances = @(@{ id = '' }) }) } }
    ) {
        param($Response)
        $global:ModelLauncherTestState.RefreshResponse = $Response
        { & $launcherPath -Client Claude } | Should Throw 'Invalid LM Studio'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'Post' }
    }

    # Checks that an unload failure halts the flow so no load request is issued and neither client launches.
    It 'stops after unload failure instead of loading or launching' -TestCases @(
        @{ Client = 'Claude'; InvalidResponse = $false }
        @{ Client = 'Copilot'; InvalidResponse = $false }
        @{ Client = 'Claude'; InvalidResponse = $true }
    ) {
        param($Client, $InvalidResponse)
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(
            (New-TestModel 'qwen/local-coder'), (New-TestModel 'old' @('old-instance'))
        ) }
        if ($InvalidResponse) {
            $global:ModelLauncherTestState.UnloadResponse = @{ instance_id = 'wrong-instance' }
        } else {
            $global:ModelLauncherTestState.UnloadFailure = $true
        }
        { & $launcherPath -Client $Client } | Should Throw 'Failed to unload model instance'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It -ParameterFilter { $Uri -like '*/load' }
    }

    # Verifies a failed load or a non-'loaded' status aborts with both Claude and Copilot env vars restored to previous values.
    It 'stops after load failure or an unconfirmed response' -TestCases @(
        @{ Client = 'Claude'; Response = $null }
        @{ Client = 'Copilot'; Response = $null }
        @{ Client = 'Claude'; Response = @{ status = 'failed'; instance_id = 'qwen/local-coder' } }
        @{ Client = 'Claude'; Response = @{ status = 'loaded' } }
    ) {
        param($Client, $Response)
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(New-TestModel 'qwen/local-coder') }
        if ($null -eq $Response) {
            $global:ModelLauncherTestState.LoadFailure = $true
        } else {
            $global:ModelLauncherTestState.LoadResponse = $Response
        }
        { & $launcherPath -Client $Client } | Should Throw 'Failed to load model'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        $env:ANTHROPIC_MODEL | Should Be 'previous-value'
        $env:COPILOT_MODEL | Should Be 'previous-value'
    }

    # Confirms that -ServerType OpenAICompatible uses the single /v1/models discovery call (no LM Studio load/unload) and still launches a model.
    It 'uses only discovery for explicitly configured compatible servers' -TestCases @(
        @{ Client = 'Claude' }, @{ Client = 'Copilot' }
    ) {
        param($Client)
        & $launcherPath -Client $Client -ServerType OpenAICompatible -BaseUrl http://localhost:11434
        $global:ModelLauncherTestState.Request.Uri | Should Be 'http://localhost:11434/v1/models'
        $global:ModelLauncherTestLaunch | Should Not BeNullOrEmpty
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It
        if ($Client -eq 'Claude') {
            $global:ModelLauncherTestLaunch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should BeNullOrEmpty
            $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be 'previous-value'
            Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter { $Message -like '*Context size detection is unavailable*' }
        }
    }

    It 'uses llama.cpp discovery and preserves model IDs for both clients' -TestCases @(
        @{ Client = 'Claude'; Mode = 'LlamaCpp'; Url = 'http://localhost:8080'; Root = 'http://localhost:8080'; Model = '../models/coder-Q4_K_M.gguf' }
        @{ Client = 'Copilot'; Mode = 'LlamaCpp'; Url = 'http://localhost:8080/v1/'; Root = 'http://localhost:8080'; Model = '../models/coder-Q4_K_M.gguf' }
        @{ Client = 'Claude'; Mode = 'llama.cpp'; Url = 'https://example.test:8443/llama/v1/'; Root = 'https://example.test:8443/llama'; Model = 'local-coder' }
        @{ Client = 'Copilot'; Mode = 'llama.cpp'; Url = 'http://192.168.1.179:1234/'; Root = 'http://192.168.1.179:1234'; Model = 'local-coder' }
    ) {
        param($Client, $Mode, $Url, $Root, $Model)
        $global:ModelLauncherTestState.Response = @{
            object = 'list'
            data = @(@{ id = $Model; object = 'model'; owned_by = 'llamacpp'; meta = $null })
        }
        & $launcherPath -Client $Client -ServerType $Mode -BaseUrl $Url -ClaudeAuthToken 'llama-test-key'
        $global:ModelLauncherTestState.Requests[0].Uri | Should Be "$Root/v1/models"
        foreach ($request in $global:ModelLauncherTestState.Requests) {
            $request.Headers.Authorization | Should Be 'Bearer llama-test-key'
        }
        if ($Client -eq 'Claude') {
            Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly -Scope It
            ([uri]$global:ModelLauncherTestState.Requests[1].Uri).AbsoluteUri | Should Be "$Root/props?model=$([uri]::EscapeDataString($Model))"
            $global:ModelLauncherTestLaunch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be '65536'
            $global:ModelLauncherTestLaunch.Arguments[1] | Should Be $Model
            $global:ModelLauncherTestLaunch.Environment.ANTHROPIC_BASE_URL | Should Be $Root
            $global:ModelLauncherTestLaunch.Environment.ANTHROPIC_AUTH_TOKEN | Should Be 'llama-test-key'
            $global:ModelLauncherTestLaunch.Environment.ANTHROPIC_DEFAULT_SONNET_MODEL | Should Be $Model
        } else {
            Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It
            $global:ModelLauncherTestLaunch.Model | Should Be $Model
            $global:ModelLauncherTestLaunch.Url | Should Be "$Root/v1"
        }
        foreach ($name in $environmentNames) {
            [Environment]::GetEnvironmentVariable($name, 'Process') | Should Be 'previous-value'
        }
    }

    It 'defaults both llama.cpp spellings to port 8080 for either client' -TestCases @(
        @{ Client = 'Claude'; Mode = 'LlamaCpp' }
        @{ Client = 'Copilot'; Mode = 'LlamaCpp' }
        @{ Client = 'Claude'; Mode = 'llama.cpp' }
        @{ Client = 'Copilot'; Mode = 'llama.cpp' }
    ) {
        param($Client, $Mode)
        & $launcherPath -Client $Client -ServerType $Mode -ClaudeAuthToken ''
        $global:ModelLauncherTestState.Requests[0].Uri | Should Be 'http://localhost:8080/v1/models'
        $global:ModelLauncherTestLaunch | Should Not BeNullOrEmpty
        if ($Client -eq 'Claude') {
            Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly -Scope It
        } else {
            Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It
        }
    }

    It 'labels an explicit llama.cpp server correctly even on another backend port' -TestCases @(
        @{ Mode = 'LlamaCpp'; Url = 'http://localhost:1234' }
        @{ Mode = 'llama.cpp'; Url = 'http://localhost:11434' }
    ) {
        param($Mode, $Url)
        & $launcherPath -ServerType $Mode -BaseUrl $Url
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq '1. Copilot [llama.cpp]' }
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { $Object -eq '2. Claude [llama.cpp]' }
    }

    It 'stops on llama.cpp discovery failure or an empty model list' -TestCases @(
        @{ Client = 'Claude'; Failure = $true; Message = 'Failed to fetch models' }
        @{ Client = 'Copilot'; Failure = $true; Message = 'Failed to fetch models' }
        @{ Client = 'Claude'; Failure = $false; Message = 'No models were returned' }
        @{ Client = 'Copilot'; Failure = $false; Message = 'No models were returned' }
    ) {
        param($Client, $Failure, $Message)
        $global:ModelLauncherTestState.RequestFailure = $Failure
        $global:ModelLauncherTestState.Response = @{ object = 'list'; data = @() }
        { & $launcherPath -Client $Client -ServerType LlamaCpp } | Should Throw $Message
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It
        Assert-MockCalled Read-Host -Times 0 -Exactly -Scope It
    }

    It 'uses the selected LM Studio instance context rather than another instance or model maximum' {
        $first = New-TestModel 'first-model' @('first-instance')
        $second = New-TestModel 'second-model' @('selected-instance', 'other-instance')
        $second.loaded_instances[0].config.context_length = 49152
        $second.loaded_instances[1].config.context_length = 98304
        $global:ModelLauncherTestState.NativeResponse = @{ models = @($first, $second) }
        $global:ModelLauncherTestState.Selection = '2'
        & $launcherPath -Client Claude
        $global:ModelLauncherTestLaunch.Arguments[1] | Should Be 'selected-instance'
        $global:ModelLauncherTestLaunch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be '49152'
    }

    It 'rejects missing or invalid runtime context instead of inheriting a stale limit' -TestCases @(
        @{ Mode = 'LMStudio'; Value = $null }
        @{ Mode = 'LMStudio'; Value = 0 }
        @{ Mode = 'LMStudio'; Value = -1 }
        @{ Mode = 'LMStudio'; Value = 123.5 }
        @{ Mode = 'LMStudio'; Value = 'unknown' }
        @{ Mode = 'LlamaCpp'; Value = $null }
        @{ Mode = 'LlamaCpp'; Value = 0 }
        @{ Mode = 'LlamaCpp'; Value = -1 }
        @{ Mode = 'LlamaCpp'; Value = '999999999999999' }
    ) {
        param($Mode, $Value)
        $global:ModelLauncherTestState.NativeResponse.models[0].loaded_instances[0].config.context_length = $Value
        $global:ModelLauncherTestState.PropsResponse.default_generation_settings.n_ctx = $Value
        { & $launcherPath -Client Claude -ServerType $Mode } | Should Throw 'Cannot determine the context size'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be 'previous-value'
    }

    It 'stops if a newly loaded LM Studio model omits its applied context size' {
        $global:ModelLauncherTestState.NativeResponse = @{ models = @(New-TestModel 'qwen/local-coder') }
        $global:ModelLauncherTestState.LoadResponse = @{ status = 'loaded'; instance_id = 'custom-loaded-id' }
        { & $launcherPath -Client Claude } | Should Throw 'Cannot determine the context size'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
    }

    It 'stops when llama.cpp context lookup fails' {
        $global:ModelLauncherTestState.PropsFailure = $true
        { & $launcherPath -Client Claude -ServerType LlamaCpp } | Should Throw 'Simulated props failure'
        $global:ModelLauncherTestLaunch | Should BeNullOrEmpty
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be 'previous-value'
    }

    It 'restores an unset context variable after Claude launch failure' {
        [Environment]::SetEnvironmentVariable('CLAUDE_CODE_MAX_CONTEXT_TOKENS', $null, 'Process')
        $global:ModelLauncherTestThrow = $true
        { & $launcherPath -Client Claude } | Should Throw 'Simulated launch failure'
        $global:ModelLauncherTestLaunch.Environment.CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should Be '32768'
        $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS | Should BeNullOrEmpty
    }
}
