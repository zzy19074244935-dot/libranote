# 打包函数部署 zip（Windows PowerShell）
# 用法：在 serverless 目录运行  .\build_function.ps1
# 产物：function.zip（zip 根目录直接是 main.py，可直接上传 veFaaS）
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$deps = Join-Path $root 'deps'
$stage = Join-Path $root 'stage'

Write-Host '[1/3] pip install -t deps -r requirements.txt'
pip install -t $deps -r (Join-Path $root 'requirements.txt') --upgrade

Write-Host '[2/3] assembling stage folder'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -Path (Join-Path $deps '*') -Destination $stage -Recurse -Force
Copy-Item -Path (Join-Path $root 'main.py') -Destination $stage -Force
Copy-Item -Path (Join-Path $root 'requirements.txt') -Destination $stage -Force
Copy-Item -Path (Join-Path $root 'fonts') -Destination (Join-Path $stage 'fonts') -Recurse -Force

Write-Host '[3/3] zipping'
$zip = Join-Path $root 'function.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

$sizeMB = [math]::Round((Get-Item $zip).Length / 1MB, 2)
Write-Host "Done: $zip ($sizeMB MB)"
