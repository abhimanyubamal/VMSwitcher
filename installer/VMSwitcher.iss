; VM Switcher installer (Inno Setup 6). Built by build\build.ps1, which stages files into build\stage.
#ifndef AppVer
  #define AppVer "1.0.0"
#endif

[Setup]
AppId={{B3F0E2A4-6C2D-4E8B-9F1A-5D7C3B21A9E4}
AppName=VM Switcher
AppVersion={#AppVer}
AppVerName=VM Switcher {#AppVer}
AppPublisher=VM Switcher
DefaultDirName={autopf}\VMSwitcher
DefaultGroupName=VM Switcher
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.14393
OutputDir=..\dist
OutputBaseFilename=VMSwitcher-Setup-{#AppVer}
SetupIconFile=..\assets\vmswitcher.ico
UninstallDisplayIcon={app}\VMSwitcher.exe
UninstallDisplayName=VM Switcher (Hyper-V failover)
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=no
InfoBeforeFile=..\installer\before-install.txt

DisableWelcomePage=yes

[Messages]
WelcomeLabel2=This installs VM Switcher on this Hyper-V server. Install it on BOTH servers:%n  10.10.140.160 (runs the PRIMARY VM)%n  10.10.140.140 (runs the SECONDARY VM)%n%nThe two copies talk to each other every 3 seconds. If the Primary VM or its whole server fails, the Secondary VM is turned ON automatically.%n%nYou get a background watchdog service, a windowed app with health lights, and a numbered terminal menu.

[Tasks]
Name: "desktopicon"; Description: "Put VM Switcher on the desktop (recommended)"; GroupDescription: "Shortcuts:"

[Files]
Source: "..\build\stage\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs

[Icons]
Name: "{group}\VM Switcher"; Filename: "{app}\VMSwitcher.exe"; Comment: "Health lights and one-click options"
Name: "{group}\VM Switcher Terminal"; Filename: "{app}\VMSwitcherTerminal.exe"; Comment: "Numbered menu in a console window"
Name: "{group}\Operator guide"; Filename: "{app}\docs\Operator-Guide.html"
Name: "{group}\Log files"; Filename: "{commonappdata}\VMSwitcher\logs"
Name: "{group}\Self-test report"; Filename: "{commonappdata}\VMSwitcher\selftest.txt"
Name: "{commondesktop}\VM Switcher"; Filename: "{app}\VMSwitcher.exe"; Tasks: desktopicon
Name: "{commondesktop}\VM Switcher Terminal"; Filename: "{app}\VMSwitcherTerminal.exe"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup\install.ps1"" -InstallDir ""{app}"" -PrimaryName ""{code:VmValue|0}"" -PrimaryHost ""{code:VmValue|1}"" -SecondaryName ""{code:VmValue|2}"" -SecondaryHost ""{code:VmValue|3}"" -SharedKeyFile ""{code:KeyFile}"" -Role {code:RoleValue} {code:DemoSwitch}"; \
  StatusMsg: "Starting the watchdog service and running the self-test (about 20 seconds)..."; Flags: runhidden waituntilterminated
Filename: "{commonappdata}\VMSwitcher\selftest.txt"; Description: "Show the self-test report"; Flags: postinstall shellexec skipifsilent
Filename: "{app}\VMSwitcher.exe"; Description: "Open VM Switcher now"; Flags: postinstall shellexec nowait skipifsilent
Filename: "{app}\docs\Operator-Guide.html"; Description: "Read the 1-page operator guide"; Flags: postinstall shellexec nowait skipifsilent unchecked

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup\uninstall.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveVmSwitcher"

[Code]
var
  RolePage: TInputOptionWizardPage;
  VmPage: TInputQueryWizardPage;
  KeyPage: TInputQueryWizardPage;

{ Index of the role choice: 0 = Primary server, 1 = Secondary server, 2 = training PC, -1 = none }
function RoleIndex: Integer;
begin
  Result := -1;
  if RolePage.Values[0] then Result := 0
  else if RolePage.Values[1] then Result := 1
  else if RolePage.Values[2] then Result := 2;
end;

function IsDemo: Boolean;
begin
  Result := RoleIndex = 2;
end;

{ True when this machine has the given IPv4 address (ipconfig output). }
function HasLocalIp(Ip: String): Boolean;
var Code: Integer;
begin
  Result := Exec(ExpandConstant('{cmd}'), '/c ipconfig | findstr /c:"' + Ip + '" >nul', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

procedure InitializeWizard;
var R: String;
begin
  { FIRST question of the installer: which machine is this? }
  RolePage := CreateInputOptionPage(wpWelcome,
    'Which server is this?', 'Choose the machine you are installing on right now.',
    'VM Switcher is installed on both Hyper-V servers. Each copy controls the VM on its own server and talks to the other copy.',
    True, False);
  RolePage.Add('10.10.140.160  -  PRIMARY server  (runs VirtuoSIS_16.0.0_IICC)');
  RolePage.Add('10.10.140.140  -  SECONDARY server  (runs VirtuoSIS_16.0.0_IICC_STANDBY)');
  RolePage.Add('Training PC  -  demo only, both servers are simulated, nothing real is touched');

  VmPage := CreateInputQueryPage(RolePage.ID,
    'Check the servers and virtual machines', 'These must be the SAME on both servers. Usually you just press Next.',
    'VM names must match Hyper-V Manager exactly.');
  VmPage.Add('PRIMARY VM name (main):', False);
  VmPage.Add('IP address of the PRIMARY server:', False);
  VmPage.Add('SECONDARY VM name (backup):', False);
  VmPage.Add('IP address of the SECONDARY server:', False);
  { Unattended install, for example:
      VMSwitcher-Setup.exe /VERYSILENT /ROLE=PRIMARY /SHAREDKEY=...   (or /ROLE=SECONDARY, /ROLE=DEMO) }
  VmPage.Values[0] := ExpandConstant('{param:PRIMARYNAME|VirtuoSIS_16.0.0_IICC}');
  VmPage.Values[1] := ExpandConstant('{param:PRIMARYIP|10.10.140.160}');
  VmPage.Values[2] := ExpandConstant('{param:SECONDARYNAME|VirtuoSIS_16.0.0_IICC_STANDBY}');
  VmPage.Values[3] := ExpandConstant('{param:SECONDARYIP|10.10.140.140}');

  R := UpperCase(ExpandConstant('{param:ROLE|}'));
  if CompareText(ExpandConstant('{param:MODE|}'), 'DEMO') = 0 then R := 'DEMO';
  if R = '' then
  begin
    { No /ROLE given: pre-select from this machine's own IP address, and say so on the page. }
    if HasLocalIp(Trim(VmPage.Values[1])) then
    begin
      R := 'PRIMARY';
      RolePage.Description :=
        'This machine has the IP address ' + Trim(VmPage.Values[1]) + ', so the PRIMARY server is selected.';
    end
    else if HasLocalIp(Trim(VmPage.Values[3])) then
    begin
      R := 'SECONDARY';
      RolePage.Description :=
        'This machine has the IP address ' + Trim(VmPage.Values[3]) + ', so the SECONDARY server is selected.';
    end
    else
    begin
      R := 'DEMO';
      RolePage.Description :=
        'This machine has NEITHER server''s IP address, so Training PC is selected. If this really is one of the two servers, choose it below.';
    end;
  end;
  if R = 'PRIMARY' then RolePage.Values[0] := True
  else if R = 'SECONDARY' then RolePage.Values[1] := True
  else if R = 'DEMO' then RolePage.Values[2] := True;

  KeyPage := CreateInputQueryPage(VmPage.ID,
    'Shared key', 'The two servers prove who they are with this key.',
    'Type a long secret phrase (at least 12 characters). Use EXACTLY the same key when you install VM Switcher on the other server. It is stored encrypted on each server. On an upgrade you can leave it empty to keep the current key.');
  KeyPage.Add('Shared key:', True);
  KeyPage.Add('Type it again:', True);
  KeyPage.Values[0] := ExpandConstant('{param:SHAREDKEY|}');
  KeyPage.Values[1] := KeyPage.Values[0];
end;

{ Training PC needs no shared key. }
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (KeyPage <> nil) and (PageID = KeyPage.ID) and IsDemo;
end;

function LooksLikeIp(S: String): Boolean;
var I, Dots: Integer;
begin
  Result := (Length(S) >= 7) and (Length(S) <= 15);
  Dots := 0;
  for I := 1 to Length(S) do
  begin
    if S[I] = '.' then Dots := Dots + 1
    else if (S[I] < '0') or (S[I] > '9') then Result := False;
  end;
  if Dots <> 3 then Result := False;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var Mine, Other: String;
begin
  Result := True;
  if (RolePage <> nil) and (CurPageID = RolePage.ID) then
  begin
    if RoleIndex < 0 then
    begin
      MsgBox('Please choose which server this is.', mbError, MB_OK);
      Result := False;
    end
    else if RoleIndex < 2 then
    begin
      { Friendly safety check: does this machine really have the chosen server's IP? }
      if RoleIndex = 0 then begin Mine := Trim(VmPage.Values[1]); Other := Trim(VmPage.Values[3]); end
      else begin Mine := Trim(VmPage.Values[3]); Other := Trim(VmPage.Values[1]); end;
      if (not HasLocalIp(Mine)) and HasLocalIp(Other) then
        Result := MsgBox('This machine has the IP address ' + Other + ', but you chose the server ' + Mine + '.' + #13#10 + #13#10 +
                         'Are you sure? Choosing the wrong server means VM Switcher looks for the wrong VM.' + #13#10 + #13#10 +
                         'Yes = keep my choice      No = let me change it', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
    end;
  end;
  if (VmPage <> nil) and (CurPageID = VmPage.ID) then
  begin
    if (Trim(VmPage.Values[0]) = '') or (Trim(VmPage.Values[2]) = '') then
    begin
      MsgBox('Please type both VM names.', mbError, MB_OK);
      Result := False;
    end
    else if CompareText(Trim(VmPage.Values[0]), Trim(VmPage.Values[2])) = 0 then
    begin
      MsgBox('The Primary and the Secondary must be two different VMs.', mbError, MB_OK);
      Result := False;
    end
    else if not LooksLikeIp(Trim(VmPage.Values[1])) or not LooksLikeIp(Trim(VmPage.Values[3])) then
    begin
      MsgBox('Please type the IP addresses like 10.10.140.160', mbError, MB_OK);
      Result := False;
    end
    else if CompareText(Trim(VmPage.Values[1]), Trim(VmPage.Values[3])) = 0 then
    begin
      MsgBox('The two VMs run on two different servers, so the two IP addresses must be different.', mbError, MB_OK);
      Result := False;
    end;
  end;
  if (KeyPage <> nil) and (CurPageID = KeyPage.ID) then
  begin
    if KeyPage.Values[0] <> KeyPage.Values[1] then
    begin
      MsgBox('The two keys are not the same. Please type them again.', mbError, MB_OK);
      Result := False;
    end
    else if (KeyPage.Values[0] <> '') and (Length(KeyPage.Values[0]) < 12) then
    begin
      MsgBox('Please use at least 12 characters for the shared key.', mbError, MB_OK);
      Result := False;
    end
    else if (KeyPage.Values[0] = '') and not FileExists(ExpandConstant('{commonappdata}\VMSwitcher\config.json')) then
    begin
      MsgBox('Please type a shared key. Both servers need the same key to talk to each other.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function KeyFile(Param: String): String;
begin
  Result := '';
  if (not IsDemo) and (KeyPage.Values[0] <> '') then
  begin
    Result := ExpandConstant('{tmp}\vmskey.txt');
    SaveStringToFile(Result, KeyPage.Values[0], False);
  end;
end;

function VmValue(Param: String): String;
begin
  Result := Trim(VmPage.Values[StrToInt(Param)]);
end;

function RoleValue(Param: String): String;
begin
  case RoleIndex of
    0: Result := 'Primary';
    1: Result := 'Secondary';
    2: Result := 'Both';
  else
    Result := 'Auto';   { silent install without /ROLE: detect from Hyper-V and IP }
  end;
end;

function DemoSwitch(Param: String): String;
begin
  if IsDemo then Result := '-Demo' else Result := '';
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var This: String;
begin
  case RoleIndex of
    0: This := 'PRIMARY server ' + VmValue('1') + ' (controls ' + VmValue('0') + ')';
    1: This := 'SECONDARY server ' + VmValue('3') + ' (controls ' + VmValue('2') + ')';
    2: This := 'Training PC (demo, simulated VMs)';
  else
    This := 'detected automatically';
  end;
  Result := 'This machine:' + NewLine + Space + This + NewLine + NewLine + MemoDirInfo + NewLine + NewLine +
    'Primary (main):' + NewLine + Space + VmValue('0') + '  on server ' + VmValue('1') + NewLine +
    'Secondary (backup):' + NewLine + Space + VmValue('2') + '  on server ' + VmValue('3') + NewLine + NewLine +
    'Watchdog service:' + NewLine + Space + 'VM Switcher Watchdog (starts with Windows)';
  if not IsDemo then
    Result := Result + NewLine + NewLine + 'Remember:' + NewLine + Space + 'install on the OTHER server too, with the same shared key.';
  if MemoTasksInfo <> '' then Result := Result + NewLine + NewLine + MemoTasksInfo;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var Code: Integer; Script: String;
begin
  Result := '';
  // Upgrade: stop the service and close open windows so files can be replaced.
  Script := ExpandConstant('{app}\setup\uninstall.ps1');
  if FileExists(Script) then
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + Script + '" -KeepService', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if MsgBox('Also delete the history, logs and settings in ' + ExpandConstant('{commonappdata}\VMSwitcher') + '?' + #13#10 + #13#10 +
              'Choose NO to keep them (recommended if you will reinstall).', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(ExpandConstant('{commonappdata}\VMSwitcher'), True, True, True);
  end;
end;
