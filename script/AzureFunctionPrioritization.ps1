using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

#Parameters of the function
$AuthToken = $Request.body['AuthToken']
$OrganizationUri = $Request.body['OrganizationUri']
$BuildId = $Request.body['BuildId']
$PoolIdList = if($Request.body['PoolIdList']) {$Request.body['PoolIdList'] -Split ","} else {New-Object System.Collections.ArrayList}
$JobNameList = if($Request.body['JobNameList']) {$Request.body['JobNameList'] -Split ","} else {New-Object System.Collections.ArrayList}
$Depth = if($Request.body['Depth']) {$Request.body['Depth']} else {"50"}

# parameters verification 
if ((-not $OrganizationUri) -or (-not $BuildId)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "Build ID and Organization URI cannot be null"
    })
    Write-Error "Build ID and Organization URI cannot be null"
    Exit 0
}
if (-not $AuthToken) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "Environnment variable SYSTEM_ACCESSTOKEN not defined"
    })
    Write-Error "Environnment variable SYSTEM_ACCESSTOKEN not defined"
    Exit 0
}

#Encode the Personal Access Token (PAT) to Base64 String
$base64AuthInfo = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$AuthToken"))
$headers = @{Authorization = ("Basic {0}" -f $base64AuthInfo); 'Content-Type' = 'application/json' }

#Prepare response body
$FinalBody = New-Object System.Collections.ArrayList

#Starting script execution
#If no Pool Id list is given, loop through all the pool we can access
if($PoolIdList.Count -eq 0) {
    try {
        $poolsRequest = Invoke-WebRequest -Uri ("{0}_apis/distributedtask/pools" -f $OrganizationUri) -Method Get -Headers $headers
        foreach($poolsData in ($poolsRequest.content | ConvertFrom-Json).value) {
            [void]$PoolIdList.Add($poolsData.id)
        }
    }
    catch {
        #We cannot access to any pool
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Unauthorized
            Body = "Your SYSTEM_ACCESSTOKEN doesn't have access to any agent Pool"
        })
        Write-Error "Your SYSTEM_ACCESSTOKEN doesn't have access to any agent Pool"
        Exit 0
    }
}

#Loop trough all pools
foreach($PoolId in $PoolIdList) {

    #We ensure we have access to this Pool Id (Powershell error on the request if we do not have access to it)
    try{
        $poolData = Invoke-WebRequest -Uri ("{0}/_apis/distributedtask/pools/{1}" -f $OrganizationUri, $PoolId) -Method Get -Headers $headers
    }
    catch
    {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]:: Unauthorized
            Body = ("Your SYSTEM_ACCESSTOKEN may not have access to Poll ID $PoolId : " + $_.Exception.Response.StatusDescription)
        })
        Write-Error ("Your SYSTEM_ACCESSTOKEN may not have access to Poll ID $PoolId : " + $_.Exception.Response.StatusDescription)
        Exit 0
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
        if ($jobrequest.owner.id -eq $BuildId) {
            # If we specified any specific jobs name, we verify it's one of them
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
                [void]$FinalBody.Add(("Job request {0} of Build {1} correctly prioritized" -f $requestId, $jobrequest.owner.name))
                Write-Host ("Job request {0} of Build {1} correctly prioritized" -f $requestId, $jobrequest.owner.name)
                #No exit, continue to search for new job to prioritize
            }
            catch #Error while get sending the prioritization request
            {
                Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]:: Unauthorized
                    Body = ("Cannot have right to modify Pool $PoolId : " + $_.Exception.Response.StatusDescription)
                })
                Write-Error ("Cannot have right to modify Pool $PoolId : " + $_.Exception.Response.StatusDescription)
                Exit 0
            }
        }
    }
} #End of loop through all Pool

if($FinalBody.Count -eq 0) {
    [void]$FinalBody.Add("No job request have been prioritized")
    Write-Warning "No job request have been prioritized"
}
# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $FinalBody
})
