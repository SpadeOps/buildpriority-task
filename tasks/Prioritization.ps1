<#
.Synopsis
   Script To priorize specifics jobs of a pipeline. It will loop through all pools (if none given), through all Job request still in queue.
   If any JobRequest is started by the Pipeline, the script will prioritized it before every other. Possibility to restrict prioritization to only specific given JobNames.
#>

[CmdletBinding(SupportsShouldProcess = $true)]

param (
    [Parameter()] #Required
    [ValidateNotNullOrEmpty()]
    [string] $OrganizationUri,
	
    [Parameter()] #Required
    [ValidateNotNullOrEmpty()]
    [string] $BuildId,
    
    [Parameter()]
    [System.Collections.ArrayList] $PoolIdList = @(),
    
    [Parameter()]
    [System.Collections.ArrayList] $JobNameList = @(),

    [Parameter()]
    [Int] $Depth = 50
)

#Specific assignment for BuildPriority task extension usage
if (Get-Command 'Get-VstsInput' -errorAction SilentlyContinue) { 
    $OrganizationUri = Get-VstsInput -Name 'input_OrganizationUri' -Require
    $BuildId = Get-VstsInput -Name 'input_BuildId' -AsInt -Require
    [string]$input_PoolIdList = Get-VstsInput -Name 'input_PoolIdList' -Default $null
    if($input_PoolIdList) {$PoolIdList = [System.Collections.ArrayList]@($input_PoolIdList -Split "," -Replace "`"","" )}
    [string]$input_JobNameList = Get-VstsInput -Name 'input_JobNameList' -Default $null
    if($input_JobNameList) {$JobNameList = [System.Collections.ArrayList]@($input_JobNameList -Split "," -Replace "`"","" )}
    $Depth = Get-VstsInput -Name 'input_Depth' -AsInt
}

# parameters verification 
if ((-not $OrganizationUri) -or (-not $BuildId)) {
    Write-Error ("Build ID and Organization URI cannot be null !")
    Exit 1
}
if (-not $env:SYSTEM_ACCESSTOKEN) {
    Write-Error ("Environnment variable SYSTEM_ACCESSTOKEN not defined !")
    Exit 1
}

#Encode the Personal Access Token (PAT) to Base64 String
$base64AuthInfo = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$env:SYSTEM_ACCESSTOKEN"))
$headers = @{Authorization = ("Basic {0}" -f $base64AuthInfo); 'Content-Type' = 'application/json' }
try {
    #If no Pool Id list is given, loop through all the pool we can access
    if($PoolIdList.Count -eq 0) {
        $poolsRequest = Invoke-WebRequest -Uri ("{0}_apis/distributedtask/pools" -f $OrganizationUri) -Method Get -Headers $headers
        foreach($poolsData in ($poolsRequest.Content | ConvertFrom-Json).value) {
            [void]$PoolIdList.Add($poolsData.id)
        }
    }
    if($PoolIdList.Count -eq 0) {
        Write-Error ("[ERROR] Your SYSTEM_ACCESSTOKEN doesn't have access to any agent Pool")
        Exit 1
    }

    #Loop trough all pools
    foreach($PoolId in $PoolIdList) {

        #We ensure we have access to this Pool Id (Powershell error on the request if we do not have access to it)
        try{
            $poolData = Invoke-WebRequest -Uri ("{0}/_apis/distributedtask/pools/{1}" -f $OrganizationUri, $PoolId) -Method Get -Headers $headers
        }
        catch
        {
            if($_.Exception.Response.StatusCode.Value__ -eq 404) {
                Write-Error ("[ERROR " + $_.Exception.Response.StatusCode.Value__ + "]Your SYSTEM_ACCESSTOKEN may not have access to Poll ID $PoolId : " + $_.Exception.Response.StatusDescription)
            } else {
                Write-Error $_.Exception
            }
            Exit 1
        }
        Write-Host ("Starting to loop through all jobRequests of pool Id $PoolId : " + ($poolData.Content | ConvertFrom-Json).name)

        $jobrequestsList = Invoke-WebRequest -Uri ("{0}/_apis/distributedtask/pools/{1}/jobrequests" -f $OrganizationUri, $PoolId) -Method Get -Headers $headers
        # Loop through all jobRequests of the pool
        $jobrequestData = $jobrequestsList.Content | ConvertFrom-Json
        for($i=0; ($i -lt $jobrequestData.value.Count -or $i -lt $Depth); $i++){
            $jobrequest = $jobrequestData.value[$i]

            #Don't priorize an already assigned job
            if($jobrequest.assignTime) { continue }

            #If the request is for the build we are looking for
            if ($BuildId -eq $jobrequest.owner.id) {
                
                # If we specified any jobs name, we verify it's one of them
                if($JobNameList.Count -gt 0) {
                    #orchestrationId field is {planId}.{JobName}.{StageName}[.{iteration}]
                    if(-not ($JobNameList -contains ($jobrequest.orchestrationId -split "\.")[1])) {
                        continue
                    }
                }

                #We send request to priorize the job
                $requestId = $jobrequest.requestId;
                $patchRequestBody = "{`"requestId`":`"" + $requestId + "`"}"
                $patchRequestUrl = "{0}_apis/distributedtask/pools/{1}/jobrequests/{2}?lockToken=00000000-0000-0000-0000-000000000000&updateOptions=1&api-version=5.0-preview.1" -f $OrganizationUri, $PoolId, $requestId
                #Sending Patch request to increase priority of 
                try
                {
                    [void](Invoke-WebRequest -Uri $patchRequestUrl -Method PATCH -Body $patchRequestBody -Headers $headers)
                    Write-Host ("Job request {0} of Build {1} correctly prioritized" -f $requestId, $jobrequest.owner.name)
                }
                catch #Error while get the list of jobRequest
                {
                    if($_.Exception.Response.StatusCode.Value__) {
                        Write-Error ("[ERROR " + $_.Exception.Response.StatusCode.Value__ + "]Cannot have right to modify Pool $PoolId : " + $_.Exception.Response.StatusDescription)
                    } else {
                        Write-Error $_.Exception
                    }
                }
            }
        }
    } #End of loop through all Pool

} finally {
    if(-not $requestId) {
        Write-Warning "No job request have been prioritized"
    }
}
            