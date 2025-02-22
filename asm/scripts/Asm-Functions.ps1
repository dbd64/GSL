#Appveyor related functions
function Get-AppVeyorBuild {
    param()

    if (-not ($env:APPVEYOR_API_TOKEN)) {
        throw "missing api token for AppVeyor."
    }

    Invoke-RestMethod -Uri "https://ci.appveyor.com/api/projects/$env:APPVEYOR_ACCOUNT_NAME/$env:APPVEYOR_PROJECT_SLUG/build/$($env:APPVEYOR_BUILD_VERSION)" -Method GET -Headers @{
        "Authorization" = "Bearer $env:APPVEYOR_API_TOKEN"
        "Content-type"  = "application/json"
    }
}

function appveyorFinished {
    param()
    $buildData = Get-AppVeyorBuild
    $lastJob = ($buildData.build.jobs | Select-Object -Last 1).jobId

    if ($lastJob -ne $env:APPVEYOR_JOB_ID) {
        return $false
    }

    [datetime]$stop = ([datetime]::Now).AddMinutes($env:TIMEOUT_MINS)

    do {

        $allSuccess = $true
        (Get-AppVeyorBuild).build.jobs | Where-Object {$_.jobId -ne $env:APPVEYOR_JOB_ID} | Foreach-Object `
            { 
                $job = $_
                switch ($job.status) {
                    "failed" { throw "AppVeyor's Job ($($job.jobId)) failed." }
                    "success" { continue }
                    Default { $allSuccess = $false }
                }
            }
        if ($allSuccess) { return $true }
        Start-sleep 5
    } while (([datetime]::Now) -lt $stop)

    throw "Test jobs were not finished in $env:TIMEOUT_MINS minutes"
}

# Returns true if any Appveyor build is "failed" or "cancelled"
function Get-Any-Appveyor-Failures {
    (Get-AppVeyorBuild).build.jobs | Foreach-Object `
    { 
        $job = $_
        switch ($job.status) {
            "failed"    { return $true }
            "cancelled" { return $true }
        }
    }
    return $false
}

#Build System independent functions

function Remove-Asm-Branches {
    if(-not (Test-Path env:APPVEYOR_PULL_REQUEST_NUMBER)) {
        # Delete all branches for asm if this is the last build
        $build = (Get-AppVeyorBuild).build
        $jobs = $build.jobs
        $lastJob = ($jobs | Select-Object -Last 1)

        if (($lastJob.jobId -eq $env:APPVEYOR_JOB_ID) -or (Get-Any-Appveyor-Failures)) {
          $jobs | Foreach-Object { 
            $branchName = "asm/$($env:APPVEYOR_REPO_COMMIT)/appveyor-$($_.jobId)"
            git ls-remote --heads --exit-code https://github.com/dadonenf/GSL.git $branchName
            if($?){
              cmd.exe /c "git push origin --delete asm/$($env:APPVEYOR_REPO_COMMIT)/appveyor-$($_.jobId) 2>&1"
            }
          }
        }
      }

}


# Returns true if all builds are finished. Throws if any failure or timeout. If the current build is not last, then returns false
function Get-All-Builds-Finished {
    return appveyorFinished
}

function Run-Command-With-Retry {
    param(
        [string]$cmd,
        [string]$cleanup_cmd = "",
        [int]$maxTries = 3
    )

    while ($maxTries -gt 0) {
        cmd.exe /c $cmd
        if($?){
            return
        } else {
            cmd.exe /c $cleanup_cmd
            $maxTries = $maxTries - 1
        }
    }

    throw "Command $($command) failed with exit code $($LastExitCode)"
}

function collectAsm {
    cmd.exe /c "git checkout $($env:APPVEYOR_REPO_BRANCH) 2>&1"
    cmd.exe /c "git fetch --all 2>&1" 

    # Create branch to merge asm into
    $asmFinalBranch = "asm/$($env:APPVEYOR_REPO_COMMIT)/final"
    cmd.exe /c "git checkout -b $($asmFinalBranch) $($env:APPVEYOR_REPO_COMMIT) 2>&1"

    #merge all branches into final branch
    (Get-AppVeyorBuild).build.jobs | Foreach-Object { 
        $branchName = "asm/$($env:APPVEYOR_REPO_COMMIT)/appveyor-$($_.jobId)"

        #Check that all branches exist
        cmd.exe /c "git ls-remote --heads --exit-code https://github.com/dadonenf/GSL.git $($branchName)"
        if(-not $?){
            throw "Missing branch for job $($_.jobId)"
        }

        #Only merge in asm if there is any change between the current branch and the repo branch
        cmd.exe /c "git diff-tree --quiet origin/$($branchName)..$($env:APPVEYOR_REPO_COMMIT)"
        if(-not $?){
            # Use cherry-pick as the asm branches only have a single commit
            cmd.exe /c "git cherry-pick origin/$($branchName) 2>&1"
            if(-not $?){
                throw "Failed merge of $($branchName)"
            }
        }
    }

    #Merge all branches into $($env:APPVEYOR_REPO_BRANCH)
    cmd.exe /c "git checkout $($env:APPVEYOR_REPO_BRANCH) 2>&1"
    cmd.exe /c "git merge --squash $($asmFinalBranch) 2>&1"
    if(-not $?){
        throw "Failed merge"
    }
    cmd.exe /c "git diff-index --cached --quiet --exit-code HEAD"
    if(-not $?) {
        git commit -m "[skip ci] Update ASM for $($env:APPVEYOR_REPO_COMMIT)"
        Run-Command-With-Retry -cmd "git push 2>&1" -cleanup_cmd "git pull --rebase 2>&1"
    }
}


function Publish-Asm {
    # Wait for all jobs
    if(Get-All-Builds-Finished) {
        # Collect ASM (currently from Appveyor only)
        collectAsm
    }
}