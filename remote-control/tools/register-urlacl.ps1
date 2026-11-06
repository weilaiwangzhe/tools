param(
    [int]$Port = 28780,
    [string]$User = "$env:USERDOMAIN\$env:USERNAME"
)

$url = "http://+:$Port/"
Write-Host "Registering $url for $User"
netsh http add urlacl url=$url user=$User
Write-Host "If Windows Firewall blocks the port, add an inbound rule for the chosen port before public-direct testing."
