# Child host waits for an event: assign its Windows Job before any tool runs.
function Initialize-CoreJobType {
    if('PassAiPro.Execution.OwnedJob' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PassAiPro.Execution {
  public sealed class OwnedJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Limits {
      public long ProcessTime,JobTime; public uint Flags; public UIntPtr Minimum,Maximum;
      public uint ActiveLimit; public UIntPtr Affinity; public uint Priority,Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct Io { public ulong ReadOps,WriteOps,OtherOps,ReadBytes,WriteBytes,OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct Extended { public Limits Basic; public Io Io; public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory; }
    [StructLayout(LayoutKind.Sequential)] struct Accounting { public long User,Kernel,PeriodUser,PeriodKernel; public uint Faults,Total,Active,Terminated; }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref Extended value,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting value,uint size,IntPtr returned);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public OwnedJob() {
      handle=CreateJobObject(IntPtr.Zero,null);
      if(handle==IntPtr.Zero) throw new Win32Exception();
      var value=new Extended(); value.Basic.Flags=0x2000;
      if(!SetInformationJobObject(handle,9,ref value,(uint)Marshal.SizeOf(typeof(Extended)))) {
        var error=new Win32Exception(); CloseHandle(handle);handle=IntPtr.Zero;throw error;
      }
    }
    public void Assign(IntPtr process) { if(!AssignProcessToJobObject(handle,process)) throw new Win32Exception(); }
    public uint Active { get { Accounting value; if(!QueryInformationJobObject(handle,1,out value,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception(); return value.Active; } }
    public void Stop() { if(!TerminateJobObject(handle,124)) throw new Win32Exception(); }
    public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle);handle=IntPtr.Zero; } }
  }
}
'@
}

function ConvertTo-CoreNativeArguments {
    param([string[]]$Values)
    $quoted=@(foreach($value in $Values){
        if($value.Contains([char]0)){throw 'NUL is not a valid native argument.'}
        '"'+[regex]::Replace([regex]::Replace($value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
    })
    $quoted -join ' '
}

function Invoke-CoreOwnedProcess {
    param([Parameter(Mandatory=$true)]$Run,[Parameter(Mandatory=$true)][ValidatePattern('^[a-z0-9-]+$')][string]$Step,
          [Parameter(Mandatory=$true)][string]$FilePath,[string[]]$Arguments=@(),
          [Parameter(Mandatory=$true)][string]$WorkingDirectory,[ValidateRange(1,600)][int]$TimeoutSeconds=60)
    Assert-PlainPath $FilePath;Assert-PlainPath $WorkingDirectory
    if([IO.Path]::GetExtension($FilePath) -ine '.exe'){throw 'Owned execution requires an explicit executable.'}
    Initialize-CoreJobType
    $prefix=Join-Path $Run.Artifacts $Step
    $requestPath=$prefix+'-request.json';$receiptPath=$prefix+'-process.json'
    if(Test-Path -LiteralPath $requestPath){throw 'Each owned step can run only once in its execution directory.'}
    $id=[Guid]::NewGuid().ToString('N')
    $stdout=$prefix+'-stdout.bin';$stderr=$prefix+'-stderr.bin';$hostResult=$prefix+'-host.json'
    $eventName='Local\PASS_AI_PRO_'+$id
    $event=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$eventName)
    $job=$null;$process=$null;$timedOut=$false;$errorText='';$active=-1;$exitCode=125;$childPid=$null;$cleanupOk=$false
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $started=[DateTime]::UtcNow.ToString('o')
    try{
        Write-CoreJson -Path $requestPath -Value ([ordered]@{operation_id=$id;file=$FilePath;arguments=$Arguments;working_directory=$WorkingDirectory;stdout=$stdout;stderr=$stderr;host_result=$hostResult})
        Set-CoreRunStatus -Run $Run -Status STARTED -Phase $Step
        Write-CoreJson -Path $receiptPath -Value ([ordered]@{run_id=$Run.Id;step=$Step;status='STARTED';started_utc=$started;timeout_seconds=$TimeoutSeconds})
        $job=[PassAiPro.Execution.OwnedJob]::new()
        $hostExe=Join-Path $PSHOME $(if($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'})
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$hostExe
        $start.Arguments=ConvertTo-CoreNativeArguments @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'process_host.ps1'),'-RequestPath',$requestPath,'-StartEventName',$eventName)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
        $start.WorkingDirectory=$WorkingDirectory
        $process=[Diagnostics.Process]::Start($start)
        $job.Assign($process.Handle)
        [void]$event.Set()
        $remaining=[math]::Max(1,($TimeoutSeconds*1000)-[int]$watch.ElapsedMilliseconds)
        if(-not $process.WaitForExit($remaining)){$timedOut=$true;$exitCode=124}
        elseif(Test-Path -LiteralPath $hostResult){
            $result=Get-Content -LiteralPath $hostResult -Raw -Encoding UTF8 | ConvertFrom-Json
            if($result.operation_id -cne $id){throw 'Owned host identity mismatch.'}
            $exitCode=[int]$result.exit_code;$childPid=$result.child_pid;$errorText=[string]$result.error
        }else{throw 'Owned host ended without a result.'}
    }catch{$errorText=$_.Exception.Message;$exitCode=125}
    finally{
        if($null -ne $job){
            try{
                $job.Stop()
                $cleanup=[Diagnostics.Stopwatch]::StartNew()
                do{$active=[int]$job.Active;if($active -eq 0){break};[Threading.Thread]::Sleep(25)}while($cleanup.ElapsedMilliseconds -lt 10000)
                $cleanupOk=$active -eq 0
            }catch{$errorText+='; cleanup: '+$_.Exception.Message}
        }
        if($null -ne $process){
            if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(10000)}
            $process.Dispose()
        }
        if($null -ne $job){$job.Dispose()}
        $event.Dispose();$watch.Stop()
    }
    $ok=-not $timedOut -and $exitCode -eq 0 -and $cleanupOk -and [string]::IsNullOrEmpty($errorText)
    $receipt=[pscustomobject]@{run_id=$Run.Id;operation_id=$id;step=$Step;status=$(if($ok){'PASS'}else{'FAIL'});started_utc=$started;ended_utc=[DateTime]::UtcNow.ToString('o');seconds=$watch.Elapsed.TotalSeconds;timeout_seconds=$TimeoutSeconds;timed_out=$timedOut;exit_code=$exitCode;child_pid=$childPid;cleanup_success=$cleanupOk;remaining_owned_processes=$active;error=$errorText;stdout=$stdout;stderr=$stderr;host_result=$hostResult}
    Write-CoreJson -Path $receiptPath -Value $receipt
    return $receipt
}

function Get-CoreProcessLog {
    param([Parameter(Mandatory=$true)]$Result,[string]$LogPath='')
    $text=''
    foreach($path in @($Result.stdout,$Result.stderr)){if(Test-Path -LiteralPath $path -PathType Leaf){$text+=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))}}
    if($LogPath){[IO.File]::WriteAllText($LogPath,$text,[Text.UTF8Encoding]::new($false))}
    if($Result.status -cne 'PASS'){throw ('Owned step '+$Result.step+' failed: timeout='+$Result.timed_out+' exit='+$Result.exit_code+' remaining='+$Result.remaining_owned_processes+' '+$Result.error)}
    return $text
}
