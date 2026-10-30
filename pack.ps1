# 定义下载 URL 和路径变量
$CacheDir = "$PSScriptRoot\cache"
$UrlWitchCachePath = @{
  "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_arm64.tar.gz" = "$CacheDir\AdGuardHome_linux_arm64.tar.gz"
  "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_armv7.tar.gz" = "$CacheDir\AdGuardHome_linux_armv7.tar.gz"
}

# 创建缓存目录
if (-Not (Test-Path -Path $CacheDir)) {
  Write-Host "Creating cache directory..."
  New-Item -Path $CacheDir -ItemType Directory
}

# 下载文件，有缓存时不再下载
Write-Host "Downloading AdGuardHome..."
foreach ($url in $UrlWitchCachePath.Keys) {
  $CachePath = $UrlWitchCachePath[$url]
  if (-Not (Test-Path -Path $CachePath)) {
    Write-Host "Downloading $url..."
    Invoke-WebRequest -Uri $url -OutFile $CachePath
    if ($?) {
      Write-Host "Download completed successfully."
    }
    else {
      Write-Host "Download failed. Exiting..."
      exit 1
    }
  }
  else {
    Write-Host "File already exists in cache. Skipping download."
  }
}

# 使用 tar 解压文件
Write-Host "Extracting AdGuardHome..."
foreach ($url in $UrlWitchCachePath.Keys) {
  $CachePath = $UrlWitchCachePath[$url]
  if ($CachePath -match 'AdGuardHome_linux_(arm64|armv7)\.tar\.gz$') {
    $ExtractDir = "./cache/" + $matches[1]
  }
  else {
    throw "Invalid file path: $CachePath"
  }
  if (-Not (Test-Path -Path $ExtractDir)) {
    New-Item -Path $ExtractDir -ItemType Directory
    Write-Host "Extracting $CachePath..."
    tar -xzf $CachePath -C $ExtractDir
    if ($?) {
      Write-Host "Extraction completed successfully."
    }
    else {
      Write-Host "Extraction failed"
      exit 1
    }
  }
}

# 给项目打包，使用 7-Zip 压缩 zip
Write-Host "Packing AdGuardHome..."
$OutputPathArm64 = "$CacheDir\AdGuardHomeForRoot_arm64.zip"
$OutputPathArmv7 = "$CacheDir\AdGuardHomeForRoot_armv7.zip"
if (Test-Path -Path $OutputPathArm64) {
  Remove-Item -Path $OutputPathArm64
}
if (Test-Path -Path $OutputPathArmv7) {
  Remove-Item -Path $OutputPathArmv7
}

# 设置项目根目录
$ProjectRoot = "$PSScriptRoot\src"
$env:PATH += ";C:\Program Files\7-Zip"

# Per-architecture update channel, mirroring pack.sh.
#
# The root manager's update check reads the updateJson baked into module.prop, and
# one JSON can only name one zipUrl, so with a single file every armv7 device is
# offered the arm64 build (which the installer now rejects). arm64 keeps pointing
# at version.json so existing installations keep working; armv7 gets its own file.
$UpdateJsonBase = "https://raw.githubusercontent.com/twoone-3/AdGuardHomeForRoot/main"

function New-ModulePropForArch {
  param([string]$UpdateJson, [string]$Suffix)
  # 7z stores the base name, so stage a patched copy and rename it inside the
  # archive afterwards. LF endings and no BOM are required: module.prop is parsed
  # by shell scripts on the device.
  $tmp = Join-Path $env:TEMP ("agh-module-$Suffix.prop")
  $lines = (Get-Content -Path "$ProjectRoot\module.prop") -replace '^updateJson=.*', "updateJson=$UpdateJson"
  $text = ($lines -join "`n") + "`n"
  [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
  if (-Not (Select-String -Path $tmp -Pattern "^updateJson=$([regex]::Escape($UpdateJson))$" -Quiet)) {
    Write-Host "Failed to stamp updateJson for $Suffix"
    exit 1
  }
  Write-Host "Update channel ($Suffix): $UpdateJson"
  return $tmp
}

# pack arm64
7z a -tzip $OutputPathArm64 "$ProjectRoot\*.sh"
7z a -tzip $OutputPathArm64 "$ProjectRoot\settings.conf"
7z a -tzip $OutputPathArm64 "$ProjectRoot\module.prop"
7z a -tzip $OutputPathArm64 "$ProjectRoot\META-INF"
7z a -tzip $OutputPathArm64 "$ProjectRoot\scripts"
7z a -tzip $OutputPathArm64 "$ProjectRoot\webroot"
7z a -tzip $OutputPathArm64 "$ProjectRoot\bin\"
7z a -tzip $OutputPathArm64 "$CacheDir\arm64\AdGuardHome\AdGuardHome"
7z rn $OutputPathArm64 "AdGuardHome" "bin/AdGuardHome"

# pack armv7 — same layout, but its module.prop carries the armv7 update channel
$PropArmv7 = New-ModulePropForArch "$UpdateJsonBase/version-armv7.json" "armv7"
7z a -tzip $OutputPathArmv7 "$ProjectRoot\*.sh"
7z a -tzip $OutputPathArmv7 "$ProjectRoot\settings.conf"
7z a -tzip $OutputPathArmv7 "$ProjectRoot\META-INF"
7z a -tzip $OutputPathArmv7 "$ProjectRoot\scripts"
7z a -tzip $OutputPathArmv7 "$ProjectRoot\webroot"
7z a -tzip $OutputPathArmv7 "$ProjectRoot\bin\"
7z a -tzip $OutputPathArmv7 $PropArmv7
7z rn $OutputPathArmv7 (Split-Path -Leaf $PropArmv7) "module.prop"
7z a -tzip $OutputPathArmv7 "$CacheDir\armv7\AdGuardHome\AdGuardHome"
7z rn $OutputPathArmv7 "AdGuardHome" "bin/AdGuardHome"
Remove-Item -Force $PropArmv7

Write-Host "Packing completed successfully."