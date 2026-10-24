#
# Add-AppxDevPackage.ps1 is a PowerShell script designed to install app
# packages created by Visual Studio for developers.  To run this script from
# Explorer, right-click on its icon and choose "Run with PowerShell".
#
# Visual Studio supplies this script in the folder generated with its
# "Prepare Package" command.  The same folder will also contain the app
# package (a .appx file), the signing certificate (a .cer file), and a
# "Dependencies" subfolder containing all the framework packages used by the
# app.
#
# This script simplifies installing these packages by automating the
# following functions:
#   1. Find the app package and signing certificate in the script directory
#   2. Prompt the user to acquire a developer license and to install the
#      certificate if necessary
#   3. Find dependency packages that are applicable to the operating system's
#      CPU architecture
#   4. Install the package along with all applicable dependencies
#
# All command line parameters are reserved for use internally by the script.
# Users should launch this script from Explorer.
#

# .Link
# http://go.microsoft.com/fwlink/?LinkId=243053

param(
    [switch]$Force = $false,
    [switch]$GetDeveloperLicense = $false,
    [switch]$SkipLoggingTelemetry = $false,
    [string]$CertificatePath = $null
)

$ErrorActionPreference = "Stop"

# The language resources for this script are placed in the
# "Add-AppDevPackage.resources" subfolder alongside the script.  Since the
# current working directory might not be the directory that contains the
# script, we need to create the full path of the resources directory to
# pass into Import-LocalizedData
$ScriptPath = $null
try
{
    $ScriptPath = (Get-Variable MyInvocation).Value.MyCommand.Path
    $ScriptDir = Split-Path -Parent $ScriptPath
}
catch {}

if (!$ScriptPath)
{
    PrintMessageAndExit $UiStrings.ErrorNoScriptPath $ErrorCodes.NoScriptPath
}

$LocalizedResourcePath = Join-Path $ScriptDir "Add-AppDevPackage.resources"
Import-LocalizedData -BindingVariable UiStrings -BaseDirectory $LocalizedResourcePath

$ErrorCodes = Data {
    ConvertFrom-StringData @'
    Success = 0
    NoScriptPath = 1
    NoPackageFound = 2
    ManyPackagesFound = 3
    NoCertificateFound = 4
    ManyCertificatesFound = 5
    BadCertificate = 6
    PackageUnsigned = 7
    CertificateMismatch = 8
    ForceElevate = 9
    LaunchAdminFailed = 10
    GetDeveloperLicenseFailed = 11
    InstallCertificateFailed = 12
    AddPackageFailed = 13
    ForceDeveloperLicense = 14
    CertUtilInstallFailed = 17
    CertIsCA = 18
    BannedEKU = 19
    NoBasicConstraints = 20
    NoCodeSigningEku = 21
    InstallCertificateCancelled = 22
    BannedKeyUsage = 23
    ExpiredCertificate = 24
'@
}

$IMAGE_FILE_MACHINE_i386  = 0x014c
$IMAGE_FILE_MACHINE_AMD64 = 0x8664
$IMAGE_FILE_MACHINE_ARM64 = 0xAA64
$IMAGE_FILE_MACHINE_ARM   = 0x01c0
$IMAGE_FILE_MACHINE_THUMB = 0x01c2
$IMAGE_FILE_MACHINE_ARMNT = 0x01c4

$MACHINE_ATTRIBUTES_UserEnabled    = 0x01
$MACHINE_ATTRIBUTES_KernelEnabled  = 0x02
$MACHINE_ATTRIBUTES_Wow64Container = 0x04

# First try to use IsWow64Process2 to determine the OS architecture
try
{
    $IsWow64Process2_MethodDefinition = @"
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
"@

    $Kernel32 = Add-Type -MemberDefinition $IsWow64Process2_MethodDefinition -Name "Kernel32" -Namespace "Win32" -PassThru

    $Proc = Get-Process -id $pid
    $processMachine = New-Object uint16
    $nativeMachine = New-Object uint16

    $Res = $Kernel32::IsWow64Process2($Proc.Handle, [ref] $processMachine, [ref] $nativeMachine)
    if ($Res -eq $True)
    {
        switch ($nativeMachine)
        {
            $IMAGE_FILE_MACHINE_i386  { $ProcessorArchitecture = "x86" }
            $IMAGE_FILE_MACHINE_AMD64 { $ProcessorArchitecture = "amd64" }
            $IMAGE_FILE_MACHINE_ARM64 { $ProcessorArchitecture = "arm64" }
            $IMAGE_FILE_MACHINE_ARM   { $ProcessorArchitecture = "arm" }
            $IMAGE_FILE_MACHINE_THUMB { $ProcessorArchitecture = "arm" }
            $IMAGE_FILE_MACHINE_ARMNT { $ProcessorArchitecture = "arm" }
        }
    }
}
catch
{
    # Ignore exception and fall back to using environment variables to determine the OS architecture
}

$Amd64AppsSupportedOnArm64 = $False
if ($null -eq $ProcessorArchitecture)
{
    $ProcessorArchitecture = $Env:Processor_Architecture

    # Getting $Env:Processor_Architecture on arm64 machines will return x86.  So check if the environment
    # variable "ProgramFiles(Arm)" is also set, if it is we know the actual processor architecture is arm64.
    # The value will also be x86 on amd64 machines when running the x86 version of PowerShell.
    if ($ProcessorArchitecture -eq "x86")
    {
        if ($null -ne ${Env:ProgramFiles(Arm)})
        {
            $ProcessorArchitecture = "arm64"
        }
        elseif ($null -ne ${Env:ProgramFiles(x86)})
        {
            $ProcessorArchitecture = "amd64"
        }
    }
}
elseif ("arm64" -eq $ProcessorArchitecture)
{
    # If we successfully determined the OS to be arm64 with the above call to IsWow64Process2 and we're on Win11+
    # we need to check for a special case where amd64 apps are supported as well.
    if ([Environment]::OSVersion.Version -ge (new-object 'Version' 10,0,22000))
    {
        try
        {
            $GetMachineTypeAttributes_MethodDefinition = @"
[DllImport("api-ms-win-core-processthreads-l1-1-7.dll", EntryPoint = "GetMachineTypeAttributes", ExactSpelling = true, PreserveSig = false)]
public static extern void GetMachineTypeAttributes(ushort Machine, out ushort machineTypeAttributes);
"@

            $ProcessThreads = Add-Type -MemberDefinition $GetMachineTypeAttributes_MethodDefinition -Name "processthreads_l1_1_7" -Namespace "Win32" -PassThru
            $machineTypeAttributes = New-Object uint16

            $ProcessThreads::GetMachineTypeAttributes($IMAGE_FILE_MACHINE_AMD64, [ref] $machineTypeAttributes)

            # We're looking for the case where the UserEnabled flag is set
            if (($machineTypeAttributes -band $MACHINE_ATTRIBUTES_UserEnabled) -ne 0)
            {
                $Amd64AppsSupportedOnArm64 = $True
            }
        }
        catch
        {
            # Ignore exceptions and maintain assumption that amd64 apps aren't supported on this machine
        }
    }
}

function PrintMessageAndExit($ErrorMessage, $ReturnCode)
{
    Write-Host $ErrorMessage
    try
    {
        # Log telemetry data regarding the use of the script if possible.
        # There are three ways that this can be disabled:
        #   1. If the "TelemetryDependencies" folder isn't present.  This can be excluded at build time by setting the MSBuild property AppxLogTelemetryFromSideloadingScript to false
        #   2. If the SkipLoggingTelemetry switch is passed to this script.
        #   3. If Visual Studio telemetry is disabled via the registry.
        $TelemetryAssembliesFolder = (Join-Path $PSScriptRoot "TelemetryDependencies")
        if (!$SkipLoggingTelemetry -And (Test-Path $TelemetryAssembliesFolder))
        {
            $job = Start-Job -FilePath (Join-Path $TelemetryAssembliesFolder "LogSideloadingTelemetry.ps1") -ArgumentList $TelemetryAssembliesFolder, "VS/DesignTools/SideLoadingScript/AddAppDevPackage", $ReturnCode, $ProcessorArchitecture
            Wait-Job -Job $job -Timeout 60 | Out-Null
        }
    }
    catch
    {
        # Ignore telemetry errors
    }

    if (!$Force)
    {
        Pause
    }
    
    exit $ReturnCode
}

#
# Warns the user about installing certificates, and presents a Yes/No prompt
# to confirm the action.  The default is set to No.
#
function ConfirmCertificateInstall
{
    $Answer = $host.UI.PromptForChoice(
                    "", 
                    $UiStrings.WarningInstallCert, 
                    [System.Management.Automation.Host.ChoiceDescription[]]@($UiStrings.PromptYesString, $UiStrings.PromptNoString), 
                    1)
    
    return $Answer -eq 0
}

#
# Validates whether a file is a valid certificate using CertUtil.
# This needs to be done before calling Get-PfxCertificate on the file, otherwise
# the user will get a cryptic "Password: " prompt for invalid certs.
#
function ValidateCertificateFormat($FilePath)
{
    # certutil -verify prints a lot of text that we don't need, so it's redirected to $null here
    certutil.exe -verify $FilePath > $null
    if ($LastExitCode -lt 0)
    {
        PrintMessageAndExit ($UiStrings.ErrorBadCertificate -f $FilePath, $LastExitCode) $ErrorCodes.BadCertificate
    }
    
    # Check if certificate is expired
    $cert = Get-PfxCertificate $FilePath
    if (($cert.NotBefore -gt (Get-Date)) -or ($cert.NotAfter -lt (Get-Date)))
    {
        PrintMessageAndExit ($UiStrings.ErrorExpiredCertificate -f $FilePath) $ErrorCodes.ExpiredCertificate
    }
}

#
# Verify that the developer certificate meets the following restrictions:
#   - The certificate must contain a Basic Constraints extension, and its
#     Certificate Authority (CA) property must be false.
#   - The certificate's Key Usage extension must be either absent, or set to
#     only DigitalSignature.
#   - The certificate must contain an Extended Key Usage (EKU) extension with
#     Code Signing usage.
#   - The certificate must NOT contain any other EKU except Code Signing and
#     Lifetime Signing.
#
# These restrictions are enforced to decrease security risks that arise from
# trusting digital certificates.
#
function CheckCertificateRestrictions
{
    Set-Variable -Name BasicConstraintsExtensionOid -Value "2.5.29.19" -Option Constant
    Set-Variable -Name KeyUsageExtensionOid -Value "2.5.29.15" -Option Constant
    Set-Variable -Name EkuExtensionOid -Value "2.5.29.37" -Option Constant
    Set-Variable -Name CodeSigningEkuOid -Value "1.3.6.1.5.5.7.3.3" -Option Constant
    Set-Variable -Name LifetimeSigningEkuOid -Value "1.3.6.1.4.1.311.10.3.13" -Option Constant
    Set-Variable -Name UwpSigningEkuOid -Value "1.3.6.1.4.1.311.84.3.1" -Option Constant
    Set-Variable -Name DisposableSigningEkuOid -Value "1.3.6.1.4.1.311.84.3.2" -Option Constant

    $CertificateExtensions = (Get-PfxCertificate $CertificatePath).Extensions
    $HasBasicConstraints = $false
    $HasCodeSigningEku = $false

    foreach ($Extension in $CertificateExtensions)
    {
        # Certificate must contain the Basic Constraints extension
        if ($Extension.oid.value -eq $BasicConstraintsExtensionOid)
        {
            # CA property must be false
            if ($Extension.CertificateAuthority)
            {
                PrintMessageAndExit $UiStrings.ErrorCertIsCA $ErrorCodes.CertIsCA
            }
            $HasBasicConstraints = $true
        }

        # If key usage is present, it must be set to digital signature
        elseif ($Extension.oid.value -eq $KeyUsageExtensionOid)
        {
            if ($Extension.KeyUsages -ne "DigitalSignature")
            {
                PrintMessageAndExit ($UiStrings.ErrorBannedKeyUsage -f $Extension.KeyUsages) $ErrorCodes.BannedKeyUsage
            }
        }

        elseif ($Extension.oid.value -eq $EkuExtensionOid)
        {
            # Certificate must contain the Code Signing EKU
            $EKUs = $Extension.EnhancedKeyUsages.Value
            if ($EKUs -contains $CodeSigningEkuOid)
            {
                $HasCodeSigningEKU = $True
            }

            # EKUs other than code signing and lifetime signing are not allowed
            foreach ($EKU in $EKUs)
            {
                if ($EKU -ne $CodeSigningEkuOid -and $EKU -ne $LifetimeSigningEkuOid -and $EKU -ne $UwpSigningEkuOid -and $EKU -ne $DisposableSigningEkuOid)
                {
                    PrintMessageAndExit ($UiStrings.ErrorBannedEKU -f $EKU) $ErrorCodes.BannedEKU
                }
            }
        }
    }

    if (!$HasBasicConstraints)
    {
        PrintMessageAndExit $UiStrings.ErrorNoBasicConstraints $ErrorCodes.NoBasicConstraints
    }
    if (!$HasCodeSigningEKU)
    {
        PrintMessageAndExit $UiStrings.ErrorNoCodeSigningEku $ErrorCodes.NoCodeSigningEku
    }
}

#
# Performs operations that require administrative privileges:
#   - Prompt the user to obtain a developer license
#   - Install the developer certificate (if -Force is not specified, also prompts the user to confirm)
#
function DoElevatedOperations
{
    if ($GetDeveloperLicense)
    {
        Write-Host $UiStrings.GettingDeveloperLicense

        if ($Force)
        {
            PrintMessageAndExit $UiStrings.ErrorForceDeveloperLicense $ErrorCodes.ForceDeveloperLicense
        }
        try
        {
            Show-WindowsDeveloperLicenseRegistration
        }
        catch
        {
            $Error[0] # Dump details about the last error
            PrintMessageAndExit $UiStrings.ErrorGetDeveloperLicenseFailed $ErrorCodes.GetDeveloperLicenseFailed
        }
    }

    if ($CertificatePath)
    {
        Write-Host $UiStrings.InstallingCertificate

        # Make sure certificate format is valid and usage constraints are followed
        ValidateCertificateFormat $CertificatePath
        CheckCertificateRestrictions

        # If -Force is not specified, warn the user and get consent
        if ($Force -or (ConfirmCertificateInstall))
        {
            # Add cert to store
            certutil.exe -addstore TrustedPeople $CertificatePath
            if ($LastExitCode -lt 0)
            {
                PrintMessageAndExit ($UiStrings.ErrorCertUtilInstallFailed -f $LastExitCode) $ErrorCodes.CertUtilInstallFailed
            }
        }
        else
        {
            PrintMessageAndExit $UiStrings.ErrorInstallCertificateCancelled $ErrorCodes.InstallCertificateCancelled
        }
    }
}

#
# Checks whether the machine is missing a valid developer license.
#
function CheckIfNeedDeveloperLicense
{
    $Result = $true
    try
    {
        $Result = (Get-WindowsDeveloperLicense | Where-Object { $_.IsValid } | Measure-Object).Count -eq 0
    }
    catch {}

    return $Result
}

#
# Launches an elevated process running the current script to perform tasks
# that require administrative privileges.  This function waits until the
# elevated process terminates, and checks whether those tasks were successful.
#
function LaunchElevated
{
    # Set up command line arguments to the elevated process
    $RelaunchArgs = '-ExecutionPolicy Unrestricted -file "' + $ScriptPath + '"'

    if ($Force)
    {
        $RelaunchArgs += ' -Force'
    }
    if ($NeedDeveloperLicense)
    {
        $RelaunchArgs += ' -GetDeveloperLicense'
    }
    if ($SkipLoggingTelemetry)
    {
        $RelaunchArgs += ' -SkipLoggingTelemetry'
    }
    if ($NeedInstallCertificate)
    {
        $RelaunchArgs += ' -CertificatePath "' + $DeveloperCertificatePath.FullName + '"'
    }

    # Launch the process and wait for it to finish
    try
    {
        $PowerShellExePath = (Get-Process -Id $PID).Path
        $AdminProcess = Start-Process $PowerShellExePath -Verb RunAs -ArgumentList $RelaunchArgs -PassThru
    }
    catch
    {
        $Error[0] # Dump details about the last error
        PrintMessageAndExit $UiStrings.ErrorLaunchAdminFailed $ErrorCodes.LaunchAdminFailed
    }

    while (!($AdminProcess.HasExited))
    {
        Start-Sleep -Seconds 2
    }

    # Check if all elevated operations were successful
    if ($NeedDeveloperLicense)
    {
        if (CheckIfNeedDeveloperLicense)
        {
            PrintMessageAndExit $UiStrings.ErrorGetDeveloperLicenseFailed $ErrorCodes.GetDeveloperLicenseFailed
        }
        else
        {
            Write-Host $UiStrings.AcquireLicenseSuccessful
        }
    }
    if ($NeedInstallCertificate)
    {
        $Signature = Get-AuthenticodeSignature $DeveloperPackagePath -Verbose
        if ($Signature.Status -ne "Valid")
        {
            PrintMessageAndExit ($UiStrings.ErrorInstallCertificateFailed -f $Signature.Status) $ErrorCodes.InstallCertificateFailed
        }
        else
        {
            Write-Host $UiStrings.InstallCertificateSuccessful
        }
    }
}

#
# Finds all applicable dependency packages according to OS architecture, and
# installs the developer package with its dependencies.  The expected layout
# of dependencies is:
#
# <current dir>
#     \Dependencies
#         <Architecture neutral dependencies>.appx\.msix
#         \x86
#             <x86 dependencies>.appx\.msix
#         \x64
#             <x64 dependencies>.appx\.msix
#         \arm
#             <arm dependencies>.appx\.msix
#         \arm64
#             <arm64 dependencies>.appx\.msix
#
function InstallPackageWithDependencies
{
    $DependencyPackagesDir = (Join-Path $ScriptDir "Dependencies")
    $DependencyPackages = @()
    if (Test-Path $DependencyPackagesDir)
    {
        # Get architecture-neutral dependencies
        $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "*.appx") | Where-Object { $_.Mode -NotMatch "d" }
        $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "*.msix") | Where-Object { $_.Mode -NotMatch "d" }

        # Get architecture-specific dependencies
        if (($ProcessorArchitecture -eq "x86" -or $ProcessorArchitecture -eq "amd64" -or $ProcessorArchitecture -eq "arm64") -and (Test-Path (Join-Path $DependencyPackagesDir "x86")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x86\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x86\*.msix") | Where-Object { $_.Mode -NotMatch "d" }
        }
        if ((($ProcessorArchitecture -eq "amd64") -or ($ProcessorArchitecture -eq "arm64" -and $Amd64AppsSupportedOnArm64)) -and (Test-Path (Join-Path $DependencyPackagesDir "x64")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x64\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "x64\*.msix") | Where-Object { $_.Mode -NotMatch "d" }
        }
        if (($ProcessorArchitecture -eq "arm" -or $ProcessorArchitecture -eq "arm64") -and (Test-Path (Join-Path $DependencyPackagesDir "arm")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "arm\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "arm\*.msix") | Where-Object { $_.Mode -NotMatch "d" }
        }
        if (($ProcessorArchitecture -eq "arm64") -and (Test-Path (Join-Path $DependencyPackagesDir "arm64")))
        {
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "arm64\*.appx") | Where-Object { $_.Mode -NotMatch "d" }
            $DependencyPackages += Get-ChildItem (Join-Path $DependencyPackagesDir "arm64\*.msix") | Where-Object { $_.Mode -NotMatch "d" }
        }
    }
    Write-Host $UiStrings.InstallingPackage

    $AddPackageSucceeded = $False
    try
    {
        if ($DependencyPackages.FullName.Count -gt 0)
        {
            Write-Host $UiStrings.DependenciesFound
            $DependencyPackages.FullName
            Add-AppxPackage -Path $DeveloperPackagePath.FullName -DependencyPath $DependencyPackages.FullName -ForceApplicationShutdown
        }
        else
        {
            Add-AppxPackage -Path $DeveloperPackagePath.FullName -ForceApplicationShutdown
        }
        $AddPackageSucceeded = $?
    }
    catch
    {
        $Error[0] # Dump details about the last error
    }

    if (!$AddPackageSucceeded)
    {
        if ($NeedInstallCertificate)
        {
            PrintMessageAndExit $UiStrings.ErrorAddPackageFailedWithCert $ErrorCodes.AddPackageFailed
        }
        else
        {
            PrintMessageAndExit $UiStrings.ErrorAddPackageFailed $ErrorCodes.AddPackageFailed
        }
    }
}

#
# Main script logic when the user launches the script without parameters.
#
function DoStandardOperations
{
    # Check for an .appx or .msix file in the script directory
    $PackagePath = Get-ChildItem (Join-Path $ScriptDir "*.appx") | Where-Object { $_.Mode -NotMatch "d" }
    if ($PackagePath -eq $null)
    {
        $PackagePath = Get-ChildItem (Join-Path $ScriptDir "*.msix") | Where-Object { $_.Mode -NotMatch "d" }
    }
    $PackageCount = ($PackagePath | Measure-Object).Count

    # Check for an .appxbundle or .msixbundle file in the script directory
    $BundlePath = Get-ChildItem (Join-Path $ScriptDir "*.appxbundle") | Where-Object { $_.Mode -NotMatch "d" }
    if ($BundlePath -eq $null)
    {
        $BundlePath = Get-ChildItem (Join-Path $ScriptDir "*.msixbundle") | Where-Object { $_.Mode -NotMatch "d" }
    }
    $BundleCount = ($BundlePath | Measure-Object).Count

    # Check for an .eappx or .emsix file in the script directory
    $EncryptedPackagePath = Get-ChildItem (Join-Path $ScriptDir "*.eappx") | Where-Object { $_.Mode -NotMatch "d" }
    if ($EncryptedPackagePath -eq $null)
    {
        $EncryptedPackagePath = Get-ChildItem (Join-Path $ScriptDir "*.emsix") | Where-Object { $_.Mode -NotMatch "d" }
    }
    $EncryptedPackageCount = ($EncryptedPackagePath | Measure-Object).Count

    # Check for an .eappxbundle or .emsixbundle file in the script directory
    $EncryptedBundlePath = Get-ChildItem (Join-Path $ScriptDir "*.eappxbundle") | Where-Object { $_.Mode -NotMatch "d" }
    if ($EncryptedBundlePath -eq $null)
    {
        $EncryptedBundlePath = Get-ChildItem (Join-Path $ScriptDir "*.emsixbundle") | Where-Object { $_.Mode -NotMatch "d" }
    }
    $EncryptedBundleCount = ($EncryptedBundlePath | Measure-Object).Count

    $NumberOfPackages = $PackageCount + $EncryptedPackageCount
    $NumberOfBundles = $BundleCount + $EncryptedBundleCount

    # There must be at least one package or bundle
    if ($NumberOfPackages + $NumberOfBundles -lt 1)
    {
        PrintMessageAndExit $UiStrings.ErrorNoPackageFound $ErrorCodes.NoPackageFound
    }
    # We must have exactly one bundle OR no bundle and exactly one package
    elseif ($NumberOfBundles -gt 1 -or
            ($NumberOfBundles -eq 0 -and $NumberOfpackages -gt 1))
    {
        PrintMessageAndExit $UiStrings.ErrorManyPackagesFound $ErrorCodes.ManyPackagesFound
    }

    # First attempt to install a bundle or encrypted bundle. If neither exists, fall back to packages and then encrypted packages
    if ($BundleCount -eq 1)
    {
        $DeveloperPackagePath = $BundlePath
        Write-Host ($UiStrings.BundleFound -f $DeveloperPackagePath.FullName)
    }
    elseif ($EncryptedBundleCount -eq 1)
    {
        $DeveloperPackagePath = $EncryptedBundlePath
        Write-Host ($UiStrings.EncryptedBundleFound -f $DeveloperPackagePath.FullName)
    }
    elseif ($PackageCount -eq 1)
    {
        $DeveloperPackagePath = $PackagePath
        Write-Host ($UiStrings.PackageFound -f $DeveloperPackagePath.FullName)
    }
    elseif ($EncryptedPackageCount -eq 1)
    {
        $DeveloperPackagePath = $EncryptedPackagePath
        Write-Host ($UiStrings.EncryptedPackageFound -f $DeveloperPackagePath.FullName)
    }
    
    # The package must be signed
    $PackageSignature = Get-AuthenticodeSignature $DeveloperPackagePath
    $PackageCertificate = $PackageSignature.SignerCertificate
    if (!$PackageCertificate)
    {
        PrintMessageAndExit $UiStrings.ErrorPackageUnsigned $ErrorCodes.PackageUnsigned
    }

    # Test if the package signature is trusted.  If not, the corresponding certificate
    # needs to be present in the current directory and needs to be installed.
    $NeedInstallCertificate = ($PackageSignature.Status -ne "Valid")

    if ($NeedInstallCertificate)
    {
        # List all .cer files in the script directory
        $DeveloperCertificatePath = Get-ChildItem (Join-Path $ScriptDir "*.cer") | Where-Object { $_.Mode -NotMatch "d" }
        $DeveloperCertificateCount = ($DeveloperCertificatePath | Measure-Object).Count

        # There must be exactly 1 certificate
        if ($DeveloperCertificateCount -lt 1)
        {
            PrintMessageAndExit $UiStrings.ErrorNoCertificateFound $ErrorCodes.NoCertificateFound
        }
        elseif ($DeveloperCertificateCount -gt 1)
        {
            PrintMessageAndExit $UiStrings.ErrorManyCertificatesFound $ErrorCodes.ManyCertificatesFound
        }

        Write-Host ($UiStrings.CertificateFound -f $DeveloperCertificatePath.FullName)

        # The .cer file must have the format of a valid certificate
        ValidateCertificateFormat $DeveloperCertificatePath

        # The package signature must match the certificate file
        if ($PackageCertificate -ne (Get-PfxCertificate $DeveloperCertificatePath))
        {
            PrintMessageAndExit $UiStrings.ErrorCertificateMismatch $ErrorCodes.CertificateMismatch
        }
    }

    $NeedDeveloperLicense = CheckIfNeedDeveloperLicense

    # Relaunch the script elevated with the necessary parameters if needed
    if ($NeedDeveloperLicense -or $NeedInstallCertificate)
    {
        Write-Host $UiStrings.ElevateActions
        if ($NeedDeveloperLicense)
        {
            Write-Host $UiStrings.ElevateActionDevLicense
        }
        if ($NeedInstallCertificate)
        {
            Write-Host $UiStrings.ElevateActionCertificate
        }

        $IsAlreadyElevated = ([Security.Principal.WindowsIdentity]::GetCurrent().Groups.Value -contains "S-1-5-32-544")
        if ($IsAlreadyElevated)
        {
            if ($Force -and $NeedDeveloperLicense)
            {
                PrintMessageAndExit $UiStrings.ErrorForceDeveloperLicense $ErrorCodes.ForceDeveloperLicense
            }
            if ($Force -and $NeedInstallCertificate)
            {
                Write-Warning $UiStrings.WarningInstallCert
            }
        }
        else
        {
            if ($Force)
            {
                PrintMessageAndExit $UiStrings.ErrorForceElevate $ErrorCodes.ForceElevate
            }
            else
            {
                Write-Host $UiStrings.ElevateActionsContinue
                Pause
            }
        }

        LaunchElevated
    }

    InstallPackageWithDependencies
}

#
# Main script entry point
#
if ($GetDeveloperLicense -or $CertificatePath)
{
    DoElevatedOperations
}
else
{
    DoStandardOperations
    PrintMessageAndExit $UiStrings.Success $ErrorCodes.Success
}

# SIG # Begin signature block
# MIIpagYJKoZIhvcNAQcCoIIpWzCCKVcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAYh/586NhEPWiO
# +3D6/pj3+lXDRXkK9+wCdlGR7safL6CCDdYwgga9MIIEpaADAgECAhMzAAAAHEif
# gd+hsLd3AAAAAAAcMA0GCSqGSIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0
# aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0yNDA4MDgyMTM2MjNaFw0zNTA2MjMy
# MjA0MDFaMF8xCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xMDAuBgNVBAMTJ01pY3Jvc29mdCBXaW5kb3dzIENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJp9a30nwXYq
# Lq7j1TT/zCtt7vxU+CCj+7BkifS/B2gXKGU7OV9SXRJGP1yFs5p6jpsYi4cYzF56
# AV0AEmmEjV8wT2lvPU5BhN3wV30HqYPIYEj5P3WXf0kXD9fvjUf1GAtXEriJ8w7A
# LNaVEm9Rs4ePA0ZsYHaCbU5kBUJQDXv76hafOcQgdFCA3I3zYtfzX2vOwx87uDOa
# CuyKORZih9c3zTf+TLC5QYLyhVMBnDXEHDOrvaw92DSyIqpdgRWpufzqDFy1egVj
# koXZhb+9pZ9heUzNXTXhOoXzexh6YzAL4flBWm+Bc1hQyESenEvBJznV+25u3h77
# jjgMUY44+WXQ4u9qddDe/U5SeAaKRvvibmi4z7QRpLvZsla0CPiOUGz00Do5sfkC
# 0EwlsSzfM3+8A9rsyFVOgWDVPzt98OJP2EoaEOq8GE9GCoN2i7/4C2FCwff1BSCT
# JWZO1Wcr2MteJE6UxGV+ihA8nN51YPKD2dYGoewrXvRzC/1HoUeSvlZf0mf9GHEt
# vvkbJVRRo6PBf0md5t87Vb1mM/fIp1eypyaxmXkgpcBwuylsOq2kSVOJ5wBPoaEs
# sJkeMcKnEuuu++UKdDHlS0DtsYjN0QnOucvTdSsdvhzKOSjJF3XVqr9f2C945LXT
# 5rxKIHUIEDBcNYU6BKDDH6rfpKOOCSilAgMBAAGjggFGMIIBQjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFB6C3w7XjLPXAjSDDtqr
# rWW5r7jsMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBL
# oEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggr
# BgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNS
# b29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQEMBQADggIBAENf+N8/
# u+mUjDtc9btoA52RBc0XVDSBMQBMqxu56hXHBwuctUWs1XBqDDMIFCHu9c6Y/UF+
# TN8EIgjnujApKYmHP4f4EM3ARSmlzrpF5ozOJx0BA5FUv1jmpdf/2ZbqpvCxlxv/
# G1R4KjrSmmqPHzs6igw3b7RTbj7BxIS8fOIkwYWQhB2fLjlg+3HSrDGPFIhpIJWV
# amMIR7a72OGonjdf45rspwqIHuynZU4avy9ruB/Rhhbwm+fMb8BMecIaTmkohx/E
# ZZ5GNWcN6oTYW3G2BM3B3YznWkl9t4shP60fMue+2ksdHGWSE8EVTdSmGUdj0jrU
# c46lGVFJISF3/MxcxnlNeP1Khyr+ZzT4Ets/I7mufpaLnLalzMR2zIuhGOAWWswe
# sbjtFzkVUFgDR2SW903I0XKlbPEA6q8epHGJ9roxh85nsEKcBNUw4Scp68KCqSpF
# BaKiyV1skd+l8U50WNePMb9Bzz0OfASal8v5sQG+DW01kN+I+RKUIbM5I50wJjiH
# ymQFNDsbobFx9I95mCEEPU7fUZ3VT/HOUVbkmX7ltIC/eQAu5GO8fu+ceETMybvb
# oxUM4dYNC+PzooUxfmC0DuKRwB21bX9+acuIBkxIm4Ed3O19w1VLoA7UNOUuJ7z6
# NQ2W/+q7cnfOPl2QVL4qlgCblUT2vmQpllV3MIIHETCCBPmgAwIBAgITMwAAAUpg
# DRBAlPZmoAAAAAABSjANBgkqhkiG9w0BAQwFADBfMQswCQYDVQQGEwJVUzEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTAwLgYDVQQDEydNaWNyb3NvZnQg
# V2luZG93cyBDb2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwMzEyMTgyNzE5WhcN
# MjcwMzAzMTgyNzE5WjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMR4wHAYDVQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDKaQMrapGq5cI79SX2ircaP4YxWDLz0jrPYc7I
# CnLyoLB1eXYI6DMAUNnNU5vDn7B0iRcDGeeSX4ni6DSr2SMNFaMdam7Z+a0mZvB0
# 0qUotNPG+3lilYeKD6aNmIC6snVgcB+d2pGOf/JpV4Ydeklxa8esYTs0tyrXVmXE
# iunUTVedZz5dXH0LRR2FvIt1XE6GlypzlD96cKq2OBgapzALdbRtUWxI/6oNW2oc
# M1+ooOg7kdj7c9/ypyigz1vGy4lHaX3Z4QM34gZELFBDRvcBbHJewxJ0s5PUUu63
# t9RfBbgKzNYgcd3KK0JteXvkLWEFsz6w4Ja6qPJxKP56ChJsZSjaJP7a7A3GQrZ8
# k8aGvXrc3t/MT3HQDDCF6N6fnhOhpXs2d8hOzH2T5RNV2ftO0B7vk0/qXNlpLxpM
# 33J8R/0QNlSvC2H8ezmd7ZV4JVz9SNaz0muMsfeDJnefIpGl7xGPOPND/uK3Bmgy
# pQVqF5PYLZq9at5IheI0rZTpxy5rHrZJ4oPjGh0S39DfkgvuTDQXqPn9IcpQJEP6
# qmtosiyhkaMglU7kmm66t+FtJ+utGOBufD2Ro+alI6mQebiEDQfg43a0glAy0Dnn
# ZDznUhQgcEW6yp0rtAtcqPkHkHv++7UqYgUYCrBsL3iV/S0AEygEhrApyf8oiFSh
# YCZFmQIDAQABo4IBrzCCAaswDgYDVR0PAQH/BAQDAgeAMB8GA1UdJQQYMBYGCisG
# AQQBgjc9BgEGCCsGAQUFBwMDMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFK4G09BO
# Jk2qR7FI29j8StEoE3j7MEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQLExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTUwMTE1MCs1MDc0MzAwHwYDVR0jBBgw
# FoAUHoLfDteMs9cCNIMO2qutZbmvuOwwagYDVR0fBGMwYTBfoF2gW4ZZaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwV2luZG93
# cyUyMENvZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyNC5jcmwwdwYIKwYBBQUHAQEE
# azBpMGcGCCsGAQUFBzAChltodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L2NlcnRzL01pY3Jvc29mdCUyMFdpbmRvd3MlMjBDb2RlJTIwU2lnbmluZyUyMFBD
# QSUyMDIwMjQuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQCRZDvy+1Qo7btu1R+bAFzu
# dA4nmCjyPw/WzQHe9uttZ17Go58MPoawLzIb71Srh06xh/pTp/5ZQvYNWXn08KOA
# j49BHZF2UO57ijYESoVrJDMus6qjR1HNAqHFB2T9yw+Jge4clnW/BA8ZAyK+gT6n
# FOEZC9tBW1iZ229LDOmYpK8f+bJJEuHRV/efuVv9rTpMzBXCvme54Ynow0uqfckp
# HEC54IdCAo6miiyKzbR/92S45Abk2XWOiQ9f7Rt+BrpccL+0CcHK7j8ofm4uDiKV
# dKjUyh+k0lvsrvK1ZNIibWKQDsq87fI1I/MmRXMscAtL0rlESKWlP/Aev2l5h1FU
# VsDaheY63BtXXduZwCKVnsgqwmhzttrzvkOBOTq7e/B/B/9TNgHxSbCP/ueO0k3u
# 1IgfOwbk84YlonoUchT/MTvm1Qg5VoG5hi0K3t1UfBV9ZwtDxvjruqKwx7xEn4HS
# 8DT7NIH4S8ZpR5KZkdf2l1x+n0YyQkHDCGTVKHlMI1WkZUtq5X/gtBkFXyAi/deQ
# lD3xE6NGtESaE5uNUgCcpU0AQgUq/xd5lb8InWNGiTvbqDit1nUJDFMsiUvbSwHf
# yO6BIY19J9VDKOAQlDQrNDKSRWRvxXhV7BpnQ6CZ/t9SwlEWgSQAmzJ4FCExDOht
# Lv6cN65nN3rxbIBpdYfQUjGCGuowghrmAgEBMHYwXzELMAkGA1UEBhMCVVMxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEwMC4GA1UEAxMnTWljcm9zb2Z0
# IFdpbmRvd3MgQ29kZSBTaWduaW5nIFBDQSAyMDI0AhMzAAABSmANEECU9magAAAA
# AAFKMA0GCWCGSAFlAwQCAQUAoIGuMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCA/
# 8sllbhmdgHazXDKfJje5ZPISyNOJfdmSfAvZZC8tJDBCBgorBgEEAYI3AgEMMTQw
# MqAUgBIATQBpAGMAcgBvAHMAbwBmAHShGoAYaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tMA0GCSqGSIb3DQEBAQUABIICACsAnCGiG9NyFHvhYuN2ijrLpEtmQ8YNN/3e
# ObiSl2kE4+wy20g/nYP34cPdg0cs9vjElzCOZ7yLaKMQzK7IMXDABANERtgEoB3N
# hiMPnPUIYJ8rk4LIHap9rRMg55zGOXpT5Tl8YsoSsbgIydYGZ1K5kVIbaAUVIDiP
# +i6oGjriwbA7Ml6rhqRe8TzjduxegfUtHh7qPEygT6jieURktwCqXdl0YNiKWf9Z
# dU9nEGABY3DhIwQ27/oueRQNSZpxMcZAhbLUEwE91ZbOn0iQVbdaxrTkvSDv9JxK
# YyQjfhkQSTNvGs4vY0KWGUPKXKNfyzJdfiygDS+fAMuwtAPihriF2kkEu5bYpdpr
# YStQdwp6DY9n+CPMw0XHzag8/0l1sscxwNDUlV7MVSfIcJ2gnmBUh8ovt5nyO6I8
# 7HYNfhguVwLh1JBF5uTImaDCQIeHqYP0zzUXMXtWA+wpmIewCbZluffOmRtrsmAD
# ii3M8Zl8+GuBA6JqmLMA6g6SNzmOmJxaxV0RLCZG6VA1nJicMSOaQxH85Y5dlyDz
# UtE5m9JVI5PGqrmWnUDgXWfJ1o7hdRFh1AW1RNMYNkcDcLMLTmJyCy7M0EPwHExP
# VpXU85eSnd2DkWpSsz9x8I4kBxXJ7/FHjCgPCvelPne/VrbJ1daDUs8+KYGTWjPs
# B9BpXC4YoYIXlDCCF5AGCisGAQQBgjcDAwExgheAMIIXfAYJKoZIhvcNAQcCoIIX
# bTCCF2kCAQMxDzANBglghkgBZQMEAgEFADCCAVIGCyqGSIb3DQEJEAEEoIIBQQSC
# AT0wggE5AgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIErU9aw2sVUf
# lvJXJ9YaeWWfMwtWluarxTCIpbS74iAbAgZqqft5EJUYEzIwMjYxMDE0MDA1OTQw
# LjU2MlowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RjAwLTA1RTAtRDk0NzElMCMGA1UE
# AxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEeowggcgMIIFCKADAgEC
# AhMzAAACHqOspG45b3xJAAEAAAIeMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MDIxOTE5Mzk0OVoXDTI3MDUxNzE5Mzk0
# OVowgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNV
# BAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGll
# bGQgVFNTIEVTTjo3RjAwLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB
# AKXROO1sPCxHsV7xpzqiXmzXOG1Op3YBalyFCEun0bmaZIzbc3l/JAYJDUPTqs4D
# c+BcoX7vq9e84KzZWwu/WjCPiYcTISqKrwYnnIL79A1hGlk8Dx7s6B6TMM7pL/i/
# L+NMxhuneuG4WIooLNNY5C10VwX4PSTfr0jumb8TTtLI0waS413mWPlIn3VSoW5l
# +MwHpxDbCHvua2JFRV2PnfKN02qP4ZCX5hrPb0GOvOftTWWf4mkuWdvTF0aZmgg8
# plvAFVxa3Ivi7KEwvtJJOaI59ZdT6D7I2XQJ2gsYvwu1YcSLwWy5M95J1KqZ4yu8
# toSaJtNVNLi9BBjw0+dvq4jnLqI1X28EVybwtT+UNOMZOo9rtQFPiB1/kmbfBit8
# IVng/+PkyipPQk41xrnSO3hMYj3RKKFdoMRiqTbdLQglndSRSm6QNFOMrvXcEjKR
# 9/HIGox5Cp87TO9Z9THsGuZSm6BBzD334PEuXaB/65ASlGaeVutUn129b12zh+oQ
# 83aMbRDAXU8FKCU1xXVKmpkqK1CAEZLC7/zYArO2gIfBhEdE3DPBNV7/Uo1O+aoB
# 3hSB6zjLA4fTaFpqBPzBhjw51Z2MqfeTTnbD6SZzRQLQX6JVdMZkgzG+j2IFlChd
# 6HNG1Yn9U60q8LJLdywrM3utK1YnCNJbPp205/SX7K0tAgMBAAGjggFJMIIBRTAd
# BgNVHQ4EFgQU5goWmuoEHQlmYlwULhw8+Z4XgmQwHwYDVR0jBBgwFoAUn6cVXQBe
# Yl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZOaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBD
# QSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBcBggrBgEFBQcwAoZQaHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBU
# aW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYDVR0TAQH/BAIwADAWBgNV
# HSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQEL
# BQADggIBAKShkHk2clUVvnAp6NGieTnXxrZME1ikpwEy18voFLQBFoAE4wZguU82
# 6EjUfCZ6U/2FfeirdNoSb9wOSTM1ADMN50+ChEjZHv7ymg1Ja8dcQCztJk4Ob3Hs
# qqUGQ1kz17HhdjXI2ZU4CZYONGvuMqNqJBue1/sQLgY2KTEYZpVY6N9i3dD1fSv8
# qzwoGVvMNH3OMD9MJy1HhyjValTVlEsWsH1uXx1HGxufJPapDjUTt1PXZHfR4gZT
# OISzkY37bpX+i9c6LbR0mIzXeFha/LU00kCGQo6UsHU426d3p9+E91Rwday7xX6V
# HRpqQxXrgeoNsu6ZmsI3BSh9XHfEyTwXi0Jgm1DEtPLBzfSxkAPVLawLX3n3HoqL
# ED6njUUtSXyDrigfLdt9icfnF3gk4GBChqqd0aNxy3Gv7wSSeOErKuADOtNwoslt
# R7OCjJ7xusIsn7Lo8CgSOldGRJgBTzB9DdhZFyToAvChXtSKfz6ukZBJteEXpzV1
# MVqReYKEKW53ggANj+3olGQn7ToXMv6MN3wotXxCPvsl+K5OI8gbkb/GWcahkVxf
# 7LIG0O/NkTjx35j4dhR39y+EfUUqXsAf7kDKi2olIWa8z8G5hHHYHbRqxVeKVXaT
# Yls07csYLPdD52kSXPCx8muRrU3+B62Zrt9amjCw2+ghoRC+Np3xMIIHcTCCBVmg
# AwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG9w0BAQsFADCBiDELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9z
# b2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMjEwOTMwMTgy
# MjI1WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAx
# MDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAOThpkzntHIhC3miy9ck
# eb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az/1xPx2b3lVNxWuJ+Slr+
# uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V29YZQ3MFEyHFcUTE3oAo4
# bo3t1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oaezOtgFt+jBAcnVL+tuhi
# JdxqD89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkNyjYtcI4xyDUoveO0hyTD
# 4MmPfrVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7KMtXAhjBcTyziYrLNueKN
# iOSWrAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRfNN0Sidb9pSB9fvzZnkXf
# tnIv231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SUHDSCD/AQ8rdHGO2n6Jl8
# P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoYWmEBc8pnol7XKHYC4jMY
# ctenIPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5C4lh8zYGNRiER9vcG9H9
# stQcxWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8FdsaN8cIFRg/eKtFtvUe
# h17aj54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TASBgkrBgEEAYI3FQEEBQID
# AQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1Kc8Q/y8E7jAdBgNVHQ4E
# FgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUwUzBRBgwrBgEEAYI3TIN9
# AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsG
# AQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTAD
# AQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0w
# S6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3Rz
# L01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYI
# KwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWlj
# Um9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3DQEBCwUAA4ICAQCdVX38
# Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEztTnXwnE2P9pkbHzQdTlt
# uw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJWAAOwBb6J6Gngugnue99q
# b74py27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G82jfZfakVqr3lbYoVSfQ
# JL1AoL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/AyeixmJ5/ALaoHCgRlCGVJ1
# ijbCHcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI95ko+ZjtPu4b6MhrZlvSP
# 9pEB9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1jdEgssU5HLcEUBHG/ZPkk
# vnNtyo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZKCS6OEuabvshVGtqRRFH
# qfG3rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xBZj1p/cvBQUl+fpO+y/g7
# 5LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuPNtq6TPmb/wrpNPgkNWcr
# 4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvpe784cETRkPHIqzqKOghi
# f9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA00wggI1AgEBMIH5oYHRpIHO
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046N0YwMC0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVAIP9A2QoMhbhUgXuPeiLaput
# HRr/oIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAwDQYJKoZI
# hvcNAQELBQACBQDueLaUMCIYDzIwMjYxMDEzMTM1NDI4WhgPMjAyNjEwMTQxMzU0
# MjhaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO54tpQCAQAwBwIBAAICId4wBwIB
# AAICEoIwCgIFAO56CBQCAQAwNgYKKwYBBAGEWQoEAjEoMCYwDAYKKwYBBAGEWQoD
# AqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG9w0BAQsFAAOCAQEAfISD
# 9CXS5Q2zVWksOmAXeRNcVh5k2B+GfNwEJNtr7Jfa8Vu4/TB5FogueuFc1axzBRVl
# IEfClZTJf2tvxXdQFw8/Dam9MGsXEKvQvyRHnfpBuyCEgIlBrGlYCrOaA/+CS4TS
# WNU3/cBMiunS4WUjWB6KQYz0gqZ0ghPBvGFTz7ZmMWRH0ZxICGCjXGM5RneQzKuZ
# td8aSeRQCbwkMIbh57pT+2X6HzNLKIL/bPOFAxmWNpGrwiUEmYQ+FyIuWc+CnqU7
# 6TkfMeDvlYPq2wQruLyK2z2Sx8eoHaAze3tm2i28+qddLjmyw6y4RnijWzQsfuol
# bDTk8XYypK3Ep8m/GjGCBA0wggQJAgEBMIGTMHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwAhMzAAACHqOspG45b3xJAAEAAAIeMA0GCWCGSAFlAwQCAQUAoIIB
# SjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIOGr
# +XeHxH6lEYVAX9aNx/CawHugqU6Pv0N8ljlmEkHVMIH6BgsqhkiG9w0BCRACLzGB
# 6jCB5zCB5DCBvQQgL4FdavP2B4yAzwG+fxurEeOEdcnb0QGLMhMjDQH284IwgZgw
# gYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAh6jrKRuOW98
# SQABAAACHjAiBCBuLDczipjtFL+AzOChK8UkBN/t0or0BY54CA0zv1NCrTANBgkq
# hkiG9w0BAQsFAASCAgA8N6G5gzoXOxCbUUUzUE9i/cL55GXr9syA+QCzQUhc/xQD
# koNjXqZyRBvCjCVHEoyBLR9POkeiuzZB2fIze0OtESYJEV7pis+CHYOdCz8SNj9O
# xmQAcjRXht+sJy/htW4JyMcs40rByjAoOoddo06Co377iCXwohFnmT81sH0+BYe6
# KQRqeBmnBQzFM0TsXKjEBal88AdVdBLS3JNeHbpaUL/u6ZwG2kZ2s6McODjDu1Ri
# W8tj2y+yXbOplH0g3SfhvkjfFyGtcR6vzgBFvVTWQmSY19QfZQxJYhiVEyIBVncq
# n9m4sNqvRbvv+wbXxF6ZAIBXASNFx/gfvRvJfJ4zt4t3U1L5tULjCIi4FDbQyfPU
# g3sydFeYJXPzSZgeBkpIotQHplXD+arImPQZOfnoxbxSND+F2towpdmZDo0dYrnR
# ACd+tDXlSvwMdKOA0ebuiGxVcKUXlM2KgIw8/3sHJ09Qa2ZLYG+xAFs8qIbEqDM8
# OYI4eCnTo4YyeFE6O6q4RbR9ZyQc0R0/+oIog0fBZ3fKzf45+Ev72DHPGEn/wNTt
# gMwSTPhxur3UVWE7cONJqsclQ4jZwZLdU28keemyYowt2My2Du9SQDqITVvleUk4
# hhKCk9zGRaM/Oj0SNy7JDTDhtdDAi22HNwE64P9BKwjTC88zvBitM1bHY3sDww==
# SIG # End signature block
