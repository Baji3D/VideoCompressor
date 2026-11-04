# Removes everything install.ps1 added.

$dest = Join-Path $env:LOCALAPPDATA "Programs\VideoCompressor"
$hkcu = [Microsoft.Win32.Registry]::CurrentUser

$assoc = $hkcu.OpenSubKey("Software\Classes\SystemFileAssociations")
if ($assoc) {
    foreach ($ext in $assoc.GetSubKeyNames()) {
        $hkcu.DeleteSubKeyTree("Software\Classes\SystemFileAssociations\$ext\shell\VideoCompressor", $false)
    }
    $assoc.Close()
}
$hkcu.DeleteSubKeyTree("Software\Microsoft\Windows\CurrentVersion\Uninstall\VideoCompressor", $false)
Remove-Item (Join-Path ([Environment]::GetFolderPath("Programs")) "Video Compressor.lnk") -ErrorAction SilentlyContinue
Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show("Video Compressor has been removed.", "Video Compressor") | Out-Null
