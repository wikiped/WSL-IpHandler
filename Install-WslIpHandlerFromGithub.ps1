﻿$ModuleName = 'WSL-IpHandler'

function PromptForChoice {
    param(
        [string]$Title,
        [string]$Text,
        [string]$FirstOption,
        [string]$FirstHelp,
        [string]$SecondOption,
        [string]$SecondHelp
    )
    $firstChoice = New-Object System.Management.Automation.Host.ChoiceDescription -ArgumentList "&$FirstOption", $FirstHelp
    $secondChoice = New-Object System.Management.Automation.Host.ChoiceDescription -ArgumentList "&$SecondOption", $SecondHelp
    $Host.UI.PromptForChoice($Title, $Text, @($firstChoice, $secondChoice), 0)
}

if ($PSVersionTable.PSVersion.Major -ne 7) {
    $promptParams = @{
        Title = "Incompatible Powershell version detected: $($PSVersionTable.PSVersion)!"
        Text = "$ModuleName has only been tested to work with Powershell Core version 7.1+. Please confirm if you want to continue installing the module:"
        FirstOption = 'No'
        SecondOption = 'Yes'
    }
    if ((PromptForChoice @promptParams) -eq 0) {
        Write-Warning "$ModuleName installation was cancelled."
        exit
    }
}

$ModulesDirectory = "$(Split-Path $Profile)\Modules"
$ModulesDirectoryInfo = New-Item $ModulesDirectory -Type Directory -ErrorAction SilentlyContinue
$targetDirectory = Join-Path $ModulesDirectoryInfo.FullName $ModuleName

Push-Location $ModulesDirectory

$targetDirectoryExistsAndNotEmpty = (Test-Path $targetDirectory -PathType Container) -and (Get-ChildItem $targetDirectory -ErrorAction SilentlyContinue).Count

if ($targetDirectoryExistsAndNotEmpty) {
    $targetDeletePromptParams = @{
        Title = "'$targetDirectory' already exists and is not empty!"
        Text = 'Please confirm if you want to continue and delete all files it contains!'
        FirstOption = 'Yes'
        FirstHelp = "Yes: all files in '$targetDirectory' will be permanently deleted."
        SecondOption = 'No'
        SecondHelp = "No: all files in '$targetDirectory' will be left as is and installation process will be aborted."
    }
    switch ((PromptForChoice @targetDeletePromptParams)) {
        0 {
            Remove-Item (Join-Path $targetDirectory '*') -Recurse -Force
        }
        1 {
            Write-Warning "$ModuleName installation was cancelled."
            exit
        }
        Default { Throw "Strange choice: '$_', can't help with that!" }
    }
}

$git = Get-Command 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1

if ($null -ne $git) {
    $gitPromptParams = @{
        Title = "Found git.exe at: $($git.Path)"
        Text = "Use git version: $($git.Version) to clone repository to '$targetDirectory'?"
        FirstOption = 'Yes'
        FirstHelp = "Yes: git.exe will be use to clone module's repository to '$targetDirectory'."
        SecondOption = 'No'
        SecondHelp = "No: HTTP protocol will be used to download repository zip file and expanded it to '$targetDirectory'."

    }
    $chooseGit = PromptForChoice @gitPromptParams
}
else {
    $chooseGit = -1
}

if ($chooseGit -eq 0) {
    git clone https://github.com/wikiped/Wsl-IpHandler
}
else {
    $outFile = "$ModuleName.zip"
    Invoke-WebRequest -Uri https://codeload.github.com/wikiped/WSL-IpHandler/zip/refs/heads/master -OutFile $outFile
    Expand-Archive -Path $outFile -DestinationPath '.'
    Remove-Item -Path $outFile
    Rename-Item -Path "${ModuleName}-master" -NewName $ModuleName
}

Pop-Location
Write-Host "WSL-IpHandler was installed in: '$targetDirectory'"
