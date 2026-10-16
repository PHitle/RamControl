param([switch]$SelfTest,[switch]$UiTest,[ValidateSet('en','ru')][string]$Language)
$ErrorActionPreference='Stop'
$script:translations=@{}
foreach($code in @('en','ru')) {
 $script:translations[$code]=Import-PowerShellDataFile (Join-Path $PSScriptRoot "locales\$code.psd1")
}
$script:settingsPath=Join-Path $PSScriptRoot 'settings.json'
if(-not $Language) {
 try {
  $saved=Get-Content $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if($saved.language -in @('en','ru')) {$Language=$saved.language}
 } catch {}
}
if(-not $Language) {$Language=if([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru') {'ru'} else {'en'}}
$script:language=$Language
function T([string]$Key) {
 if(-not $script:translations[$script:language].ContainsKey($Key)) {throw "Missing translation: $Key"}
 return $script:translations[$script:language][$Key]
}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'RamNative.cs')
function Convert-Limits([string]$Minimum,[string]$Maximum) {
 [uint64]$lo=0;[uint64]$hi=0
 if(-not [uint64]::TryParse($Minimum,[ref]$lo) -or -not [uint64]::TryParse($Maximum,[ref]$hi)) {throw (T 'WholeNumber')}
 if($lo -lt 1 -or $hi -lt $lo -or $hi -gt 16777216) {throw (T 'Range')}
 return @([uint64]($lo*1MB),[uint64]($hi*1MB))
}
function Get-Identity([int]$ProcessId) {
 $p=[Diagnostics.Process]::GetProcessById($ProcessId)
 try {return "$ProcessId/$($p.StartTime.ToUniversalTime().Ticks)"} finally {$p.Dispose()}
}
if($SelfTest) {
 foreach($key in $script:translations.en.Keys) {
  if(-not $script:translations.ru.ContainsKey($key)) {throw "Missing Russian key: $key"}
  foreach($code in @('en','ru')) {if(-not $script:translations[$code][$key]) {throw "Empty translation: $key"}}
 }
 if($script:translations.en.get_Count() -ne $script:translations.ru.get_Count()) {throw 'Translation keys do not match'}
 Write-Output 'PASS English/Russian translation keys'
 $v=Convert-Limits '32' '256'; if($v[0] -ne 32MB -or $v[1] -ne 256MB) {throw 'Conversion failed'}
 foreach($pair in @(@('0','10'),@('20','10'),@('abc','100'),@('1','999999999999999999999'))) {
  $rejected=$false;try {$null=Convert-Limits $pair[0] $pair[1]} catch {$rejected=$true}; if(-not $rejected) {throw 'Validation failed'}
 }
 $m=[RamNative]::Memory($PID)
 if($m[0] -le 0 -or $m[0] -gt $m[1]) {throw 'Private memory invalid'}
 Write-Output ('PASS private resident {0:F1} MiB <= total {1:F1} MiB' -f ($m[0]/1MB),($m[1]/1MB))
 $child=Start-Process powershell.exe -ArgumentList '-NoProfile -WindowStyle Hidden -Command Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
 try {
  $before=[RamNative]::Read($child.Id)
  [RamNative]::Set($child.Id,$before[0],256MB,6)
  $after=[RamNative]::Read($child.Id)
  if($after[1] -ne 256MB -or ($after[2] -band 4) -eq 0) {throw 'Native limit failed'}
  [RamNative]::Set($child.Id,$before[0],$before[1],[uint32]$before[2])
  $after=[RamNative]::Read($child.Id)
  if($after[0] -ne $before[0] -or $after[1] -ne $before[1] -or $after[2] -ne $before[2]) {throw 'Restore failed'}
  Write-Output 'PASS validation, native apply/restore'
 } finally {Stop-Process -Id $child.Id -ErrorAction SilentlyContinue;$child.Dispose()}
 exit
}
[xml]$xaml=Get-Content (Join-Path $PSScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8
# Localize the empty-state labels before WPF creates the window.
$xamlNs=[Xml.XmlNamespaceManager]::new($xaml.NameTable)
$xamlNs.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
$xaml.SelectSingleNode('//*[@x:Name="ProcessName"]',$xamlNs).SetAttribute('Text',(T 'SelectProcess'))
$xaml.SelectSingleNode('//*[@x:Name="ProcessInfo"]',$xamlNs).SetAttribute('Text',(T 'ClickRow'))
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$ui=@{};foreach($name in @('Summary','Search','Processes','ProcessName','ProcessInfo','MinRam','MaxRam','Apply','Restore','Status')) {$ui[$name]=$window.FindName($name)}
$script:originals=@{};$script:selectedKey=$null;$script:currentId=0;$script:refreshing=$false
function Set-Status([string]$Text,[bool]$Failed=$false) {
 $ui.Status.Text=$Text;$ui.Status.Foreground=if($Failed) {'#FFABAB'} else {'#9DB0CA'}
}
function Format-ProcessInfo($Item) {
 $private=if($null -eq $Item.Ram) {(T 'Unavailable')} else {(T 'MemoryValue') -f $Item.Ram}
 return ((T 'Info') -f $Item.Id,$private,$Item.TotalRam)
}
function Update-Selection {
 if($script:refreshing) {return}
 $item=$ui.Processes.SelectedItem
 $ui.Apply.IsEnabled=$false;$ui.Restore.IsEnabled=$false;$ui.MinRam.IsEnabled=$false;$ui.MaxRam.IsEnabled=$false
 $script:currentId=0;$script:selectedKey=$null
 if($null -eq $item) {$ui.ProcessName.Text=T 'SelectProcess';$ui.ProcessInfo.Text=T 'ClickRow';return}
 $ui.ProcessName.Text=$item.Name;$ui.ProcessInfo.Text=Format-ProcessInfo $item
 try {
  $key=Get-Identity $item.Id;$limits=[RamNative]::Read($item.Id)
  if((Get-Identity $item.Id) -ne $key) {throw (T 'Changed')}
  $script:currentId=$item.Id;$script:selectedKey=$key
  $ui.MinRam.Text=[math]::Max(1,[math]::Ceiling($limits[0]/1MB)).ToString('0')
  $ui.MaxRam.Text=[math]::Max(1,[math]::Ceiling($limits[1]/1MB)).ToString('0')
  $ui.Apply.IsEnabled=$true;$ui.MinRam.IsEnabled=$true;$ui.MaxRam.IsEnabled=$true;$ui.Restore.IsEnabled=$script:originals.ContainsKey($key)
 } catch {Set-Status (T 'ReadFailed') $true}
}
function Refresh-Processes {
 $selectedId=if($ui.Processes.SelectedItem) {$ui.Processes.SelectedItem.Id} else {-1}
 $query=$ui.Search.Text.Trim();$items=[Collections.Generic.List[object]]::new()
 foreach($p in [Diagnostics.Process]::GetProcesses()) {
  try {
   $name=$p.ProcessName
   if($query -and $name.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and "$($p.Id)" -notlike "*$query*") {continue}
   $group=if($p.MainWindowHandle -ne [IntPtr]::Zero) {(T 'Active')} else {(T 'Background')}
   $private=$null;$total=$p.WorkingSet64/1MB
   try {$m=[RamNative]::Memory($p.Id);$private=$m[0]/1MB;$total=$m[1]/1MB} catch {}
   $items.Add([pscustomobject]@{Name=$name;Id=$p.Id;Ram=$private;TotalRam=$total;Group=$group})
  } catch {} finally {$p.Dispose()}
 }
 $script:refreshing=$true
 try {
  $sorted=@($items|Sort-Object Group,Name,Id)
  $view=[Windows.Data.ListCollectionView]::new([Collections.IList]$sorted)
  $view.GroupDescriptions.Add([Windows.Data.PropertyGroupDescription]::new('Group'));$ui.Processes.ItemsSource=$view
  $same=$sorted|Where-Object Id -eq $selectedId|Select-Object -First 1
  if($same) {$ui.Processes.SelectedItem=$same;$ui.ProcessInfo.Text=Format-ProcessInfo $same} else {$ui.Processes.SelectedItem=$null}
  $ui.Summary.Text=((T 'Count') -f $items.Count)
 } finally {$script:refreshing=$false}
 if(-not $same) {Update-Selection}
}
$ui.Processes.Add_SelectionChanged({Update-Selection})
$ui.Search.Add_TextChanged({Refresh-Processes})
$ui.Apply.Add_Click({
 try {
  $v=Convert-Limits $ui.MinRam.Text $ui.MaxRam.Text
  if(-not $script:selectedKey -or (Get-Identity $script:currentId) -ne $script:selectedKey) {throw (T 'Changed')}
  $old=[RamNative]::Read($script:currentId);[RamNative]::Set($script:currentId,$v[0],$v[1],6)
  if(-not $script:originals.ContainsKey($script:selectedKey)) {$script:originals[$script:selectedKey]=$old}
  $ui.Restore.IsEnabled=$true;Set-Status ((T 'Applied') -f $script:currentId,$ui.MinRam.Text,$ui.MaxRam.Text)
 } catch {
  $reason=$_.Exception.GetBaseException()
  if($reason -is [ComponentModel.Win32Exception] -and $reason.NativeErrorCode -eq 1314) {Set-Status (T 'Privilege') $true}
  else {Set-Status ((T 'ApplyFailed') -f $reason.Message) $true}
 }
})
$ui.Restore.Add_Click({
 try {
  if(-not $script:selectedKey -or (Get-Identity $script:currentId) -ne $script:selectedKey) {throw (T 'Changed')}
  $old=$script:originals[$script:selectedKey];if($null -eq $old) {throw (T 'NoOriginal')}
  [RamNative]::Set($script:currentId,$old[0],$old[1],[uint32]$old[2]);$script:originals.Remove($script:selectedKey)
  Update-Selection;Set-Status (T 'Restored')
 } catch {Set-Status ((T 'RestoreFailed') -f $_.Exception.GetBaseException().Message) $true}
})
$script:changingLanguage=$false
function Set-Language([string]$Code,[bool]$Persist=$true) {
 if($Code -notin @('en','ru')) {throw 'Unsupported language'}
 $script:language=$Code
 $window.Language=[Windows.Markup.XmlLanguage]::GetLanguage($Code)
 foreach($key in @('Subtitle','Help','Parameters','MinHint','MaxHint','LimitsHelp')) {
  $window.FindName("Loc$key").Text=T $key
 }
 $ui.Search.ToolTip=T 'Search'
 $ui.Apply.Content=T 'Apply';$ui.Restore.Content=T 'Restore'
 $ui.Processes.Columns[0].Header=T 'Process'
 $ui.Processes.Columns[2].Header=T 'PrivateRam'
 $ui.Processes.Columns[3].Header=T 'TotalRam'
 $window.FindName('LanguageLabel').Text=T 'Language'
 $script:changingLanguage=$true
 try {
  foreach($option in $window.FindName('LanguagePicker').Items) {
   if($option.Tag -eq $Code) {$window.FindName('LanguagePicker').SelectedItem=$option}
  }
 } finally {$script:changingLanguage=$false}
 Refresh-Processes
 if(-not $ui.Processes.SelectedItem) {$ui.ProcessName.Text=T 'SelectProcess';$ui.ProcessInfo.Text=T 'ClickRow'}
 Set-Status (T 'Ready')
 if($Persist) {
  try { @{language=$Code} | ConvertTo-Json | Set-Content $script:settingsPath -Encoding UTF8 }
  catch {Set-Status ((T 'LanguageSaveFailed') -f $_.Exception.Message) $true}
 }
}
$window.FindName('LanguagePicker').Add_SelectionChanged({
 if(-not $script:changingLanguage) {
  $code=$window.FindName('LanguagePicker').SelectedItem.Tag
  if($code) {Set-Language $code (-not $UiTest)}
 }
})
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromSeconds(2)
$timer.Add_Tick({try {Refresh-Processes} catch {Set-Status $_.Exception.Message $true}})
$window.Add_Closed({$timer.Stop()})
$window.Add_Closing({
 $failures=0
 foreach($key in @($script:originals.Keys)) {
  try {
   $targetId=[int]($key.Split('/')[0])
   if((Get-Identity $targetId) -eq $key) {$old=$script:originals[$key];[RamNative]::Set($targetId,$old[0],$old[1],[uint32]$old[2])}
  } catch {try {if((Get-Identity $targetId) -eq $key) {$failures++}} catch {}}
 }
 if($failures -gt 0) {[Windows.MessageBox]::Show(((T 'CloseFailed') -f $failures),'RAM Control')|Out-Null}
})
Set-Language $script:language $false
if($UiTest) {
 foreach($code in @('en','ru','en')) {
  Set-Language $code $false
  if($ui.ProcessName.Text -ne (T 'SelectProcess') -or $ui.ProcessInfo.Text -ne (T 'ClickRow')) {throw "Empty-state localization failed: code=$code name=$($ui.ProcessName.Text) info=$($ui.ProcessInfo.Text) selected=$($ui.Processes.SelectedItem.Name)"}
  Refresh-Processes
  if($ui.ProcessName.Text -ne (T 'SelectProcess')) {throw 'Refresh changed empty-state language'}
 }
 if($ui.Processes.Items.Count -lt 1) {throw 'Empty process list'}
 $own=@($ui.Processes.Items)|Where-Object Id -eq $PID|Select-Object -First 1
 if($null -eq $own.Ram -or $own.Ram -le 0 -or $own.Ram -gt $own.TotalRam) {throw 'UI memory metric invalid'}
 $ui.Processes.SelectedItem=$own;if(-not $ui.Apply.IsEnabled) {throw 'Selection panel failed'}
 foreach($code in @('en','ru')) {
  $ui.MinRam.Text='42';$ui.MaxRam.Text='500'
  Set-Language $code $false
  if($ui.Apply.Content -ne $script:translations[$code].Apply) {throw 'Button localization failed'}
  if($ui.Processes.Columns[0].Header -ne $script:translations[$code].Process) {throw 'Column localization failed'}
  if($ui.MinRam.Text -ne '42' -or $ui.MaxRam.Text -ne '500') {throw 'Language switch changed draft limits'}
  if($ui.Processes.SelectedItem.Id -ne $PID) {throw 'Language switch lost selected process'}
  if($ui.Processes.SelectedItem.Group -notin @((T 'Active'),(T 'Background'))) {throw 'Group localization failed'}
  try {$null=Convert-Limits 'abc' '100';throw 'Validation accepted bad input'} catch {if($_.Exception.Message -ne (T 'WholeNumber')) {throw}}
 }
 $ui.Search.Text='unlikely-process-name-903812';if($ui.Processes.Items.Count -ne 0) {throw 'Search failed'}
 if($ui.ProcessName.Text -ne (T 'SelectProcess')) {throw 'Filtered empty-state localization failed'}
 $ui.Search.Text='';Write-Output 'PASS WPF load, memory columns, selection, search';exit
}
$timer.Start();$null=$window.ShowDialog()
