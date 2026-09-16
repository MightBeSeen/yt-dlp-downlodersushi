Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Run the actual picker against a small console buffer. Newlines scroll exactly
# as a terminal does; this catches stale cursor anchors without sending real keys.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class MenuTestConsole {
    public static int BufferWidth = 80, BufferHeight = 25, WindowHeight = 25;
    public static int CursorTop = 22, CursorLeft = 0;
    public static bool CursorVisible = true, IsInputRedirected = false;
    public static ConsoleColor ForegroundColor = ConsoleColor.Gray, BackgroundColor = ConsoleColor.Black;
    public static List<string> Rows = new List<string>();
    public static Queue<ConsoleKey> Keys = new Queue<ConsoleKey>();
    public static bool Resize;
    public static int ResizeWidth = 65;
    public static void Reset(int top) {
        BufferWidth = 80; BufferHeight = WindowHeight = 25;
        CursorTop = top; CursorLeft = 0; Rows.Clear(); Keys.Clear();
        for (int i=0;i<25;i++) Rows.Add("");
        Keys.Enqueue(ConsoleKey.DownArrow); Keys.Enqueue(ConsoleKey.UpArrow);
        Keys.Enqueue(ConsoleKey.DownArrow); Keys.Enqueue(ConsoleKey.Enter);
    }
    public static void SetCursorPosition(int left, int top) {
        if (left<0 || left>=BufferWidth || top<0 || top>=BufferHeight) throw new Exception("Invalid cursor");
        CursorLeft=left; CursorTop=top;
    }
    public static void Clear() { for(int i=0;i<Rows.Count;i++) Rows[i]=""; CursorTop=CursorLeft=0; }
    public static void Write(string text) {
        foreach(char c in text) {
            if(c=='\r') { CursorLeft=0; continue; }
            if(c=='\n') { NewLine(); continue; }
            string row=Rows[CursorTop].PadRight(BufferWidth);
            Rows[CursorTop]=row.Substring(0,CursorLeft)+c+row.Substring(CursorLeft+1);
            CursorLeft++;
            if(CursorLeft>=BufferWidth) NewLine();
        }
    }
    static void NewLine() {
        CursorLeft=0; CursorTop++;
        if(CursorTop>=BufferHeight) { Rows.RemoveAt(0); Rows.Add(""); CursorTop=BufferHeight-1; }
    }
    public static void WriteLine() { NewLine(); }
    public static void WriteLine(string text) { Write(text); NewLine(); }
    public static ConsoleKeyInfo ReadKey(bool intercept) {
        if(Resize && Keys.Count==3) { BufferWidth=ResizeWidth; Resize=false; }
        if(Keys.Count==0) throw new Exception("Unexpected key read");
        return new ConsoleKeyInfo('\0',Keys.Dequeue(),false,false,false);
    }
}
'@
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot) 'smart-downloader.ps1'),[ref]$tokens,[ref]$errors)
$definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-MenuChoiceArrows'},$false)[0]
. ([scriptblock]::Create($definition.Extent.Text.Replace('[Console]','[MenuTestConsole]')))
function Write-Host {
    param($Object, $ForegroundColor, $BackgroundColor, [switch]$NoNewline)
    if($NoNewline) { [MenuTestConsole]::Write([string]$Object) }
    else { [MenuTestConsole]::WriteLine([string]$Object) }
}
$items=@(
    [pscustomobject]@{Key='1';Label='Start download';Value='Start';Disabled=$false},
    [pscustomobject]@{Key='2';Label='Change choices';Value='Change';Disabled=$false}
)
foreach($top in @(0,22)) {
    [MenuTestConsole]::Reset($top)
    $result=Read-MenuChoiceArrows -Title 'Ready to download?' -Items $items -Notes @() -DefaultIndex 0
    $screen=[MenuTestConsole]::Rows -join "`n"
    $titles=[regex]::Matches($screen,'Ready to download\?').Count
    if($titles -ne 1) { throw "FAIL: redraw at row $top leaves $titles headings (expected 1).`n$screen" }
    if($result -ne 'Change') { throw 'FAIL: arrows select wrong item' }
    if(-not [MenuTestConsole]::CursorVisible) { throw 'FAIL: cursor visibility not restored' }
    Microsoft.PowerShell.Utility\Write-Host "PASS: stable redraw at row $top"
}
[MenuTestConsole]::Reset(22)
[MenuTestConsole]::Resize=$true
$items[0].Label='Long label ' * 15
$result=Read-MenuChoiceArrows -Title 'Ready to download?' -Items $items -Notes @() -DefaultIndex 0
if($result -ne 'Change' -or [regex]::Matches(([MenuTestConsole]::Rows -join "`n"),'Ready to download\?').Count -ne 1) { throw 'FAIL: resize/long label redraw' }
Microsoft.PowerShell.Utility\Write-Host 'PASS: resize and long labels'

[MenuTestConsole]::Reset(22)
[MenuTestConsole]::Resize=$true
$script:headerPaints=0
$result=Read-MenuChoiceArrows -Title 'Ready to download?' -Items $items -Notes @() -DefaultIndex 0 -RedrawHeader { $script:headerPaints++; [MenuTestConsole]::WriteLine('Review summary') }
if($script:headerPaints -ne 1 -or ([MenuTestConsole]::Rows -join "`n") -notmatch 'Review summary') { throw 'FAIL: resize loses review summary' }
Microsoft.PowerShell.Utility\Write-Host 'PASS: resize preserves review context'

function Read-MenuChoiceText {
    param($Title,$Items,$Notes,[switch]$AllowBack,$DefaultIndex)
    [MenuTestConsole]::WriteLine($Title)
    return $Items[$DefaultIndex].Value
}
[MenuTestConsole]::Reset(22)
[MenuTestConsole]::Resize=$true
[MenuTestConsole]::ResizeWidth=40
$result=Read-MenuChoiceArrows -Title 'Ready to download?' -Items $items -Notes @() -DefaultIndex 0
if($result -ne 'Start' -or [regex]::Matches(([MenuTestConsole]::Rows -join "`n"),'Ready to download\?').Count -ne 1) { throw 'FAIL: narrow resize retains stale frame or loses selection' }
Microsoft.PowerShell.Utility\Write-Host 'PASS: narrow resize switches cleanly to numbered input'

foreach($key in @([ConsoleKey]::Escape,[ConsoleKey]::LeftArrow)) {
    [MenuTestConsole]::Reset(0)
    [MenuTestConsole]::Keys.Clear(); [MenuTestConsole]::Keys.Enqueue($key)
    $result=Read-MenuChoiceArrows -Title 'Ready?' -Items $items -Notes @() -DefaultIndex 0 -AllowBack
    if(($key -eq [ConsoleKey]::Escape -and $null -ne $result) -or ($key -eq [ConsoleKey]::LeftArrow -and $result -ne 'BACK')) { throw 'FAIL: cancel/back navigation' }
}
Microsoft.PowerShell.Utility\Write-Host 'PASS: escape and back'

[MenuTestConsole]::Reset(0)
[MenuTestConsole]::Keys.Clear(); [MenuTestConsole]::Keys.Enqueue([ConsoleKey]::Enter)
$items[0].Disabled=$true
$result=Read-MenuChoiceArrows -Title 'Ready?' -Items $items -Notes @() -DefaultIndex 0
if($result -ne 'Change') { throw 'FAIL: disabled default remains selectable' }
Microsoft.PowerShell.Utility\Write-Host 'PASS: disabled choices are skipped'
