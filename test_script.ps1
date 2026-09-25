#!/usr/bin/env pwsh
# Simple test to verify the script syntax
try {
    .\Start-LocalAgent.ps1 -ShowVersion
    Write-Host "Script executed successfully!" -ForegroundColor Green
} catch {
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}
