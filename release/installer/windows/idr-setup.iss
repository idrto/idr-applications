; IDR Setup for Windows: a small bootstrapper. The user picks components; the
; signed release manifest says what to download (selected components plus the
; agents they need, shared ones once); Inno's download page fetches them with
; SHA-256 checks; idr-install.ps1 installs them into one per-user folder.
;
; Build:  iscc /DChannel=staging /DAppVersion=0.2.0-57 idr-setup.iss
; Rerun to add, update or remove components; user data in %APPDATA% is never touched.

#ifndef Channel
  #define Channel "staging"
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{8C3B6A52-6F0E-4E8B-9C1A-2D7E5B4F9A10}
AppName=IDR
AppVersion={#AppVersion}
AppVerName=IDR ({#Channel} {#AppVersion})
AppPublisher=IDR
AppPublisherURL=https://billing.idr.to/{#Channel}/download/
DefaultDirName={localappdata}\Programs\IDR
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
ChangesEnvironment=yes
WizardStyle=modern
; Same icon as the Target app (Auth_repo/download-site/favicon.svg).
SetupIconFile=..\..\..\idr_target_app\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
OutputDir=Output
OutputBaseFilename=IDR-Setup-{#Channel}
UninstallDisplayName=IDR
UninstallDisplayIcon={app}\idr_target_app.exe
SetupLogging=yes

[Types]
Name: "custom"; Description: "Choose components"; Flags: iscustom

[Components]
Name: "target_gui"; Description: "IDR Target GUI: desktop app to share this machine's services"; Types: custom
Name: "target_cli"; Description: "IDR Target CLI (idrt): the same from a terminal or a server"; Types: custom
Name: "source_cli"; Description: "IDR Source CLI (idr): use services and send files to your Targets"; Types: custom

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut for idrt"; Components: target_gui

[Files]
; Kept for the uninstaller (removes the PATH entry).
Source: "idr-install.ps1"; DestDir: "{app}\.idr"; Flags: ignoreversion

[InstallDelete]
; Older versions named the shortcuts "IDR Target"; always remove those.
Type: files; Name: "{autoprograms}\IDR Target.lnk"
Type: files; Name: "{autodesktop}\IDR Target.lnk"
Type: files; Name: "{autoprograms}\idrt.lnk"; Components: not target_gui
Type: files; Name: "{autodesktop}\idrt.lnk"; Components: not target_gui

[Icons]
Name: "{autoprograms}\idrt"; Filename: "{app}\idr_target_app.exe"; Components: target_gui
Name: "{autodesktop}\idrt"; Filename: "{app}\idr_target_app.exe"; Components: target_gui; Tasks: desktopicon

[Run]
Filename: "{app}\idr_target_app.exe"; Description: "Open idrt"; Flags: nowait postinstall skipifsilent; Components: target_gui

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\.idr\idr-install.ps1"" -Mode Uninstall -InstallDir ""{app}"""; Flags: runhidden; RunOnceId: "IdrUninstall"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
var
  DownloadPage: TDownloadWizardPage;

function SelectedIds(): String;
begin
  Result := '';
  if WizardIsComponentSelected('target_cli') then Result := Result + 'target-cli,';
  if WizardIsComponentSelected('target_gui') then Result := Result + 'target-gui,';
  if WizardIsComponentSelected('source_cli') then Result := Result + 'source-cli,';
end;

{ Runs idr-install.ps1; returns '' or the error it reported. }
function RunPs(const Mode: String): String;
var
  Code: Integer;
  Err: AnsiString;
  ErrFile: String;
begin
  ErrFile := ExpandConstant('{tmp}\error.txt');
  DeleteFile(ErrFile);
  if Exec('powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\idr-install.ps1') + '"' +
      ' -Mode ' + Mode + ' -Channel {#Channel}' +
      ' -Components "' + SelectedIds() + '"' +
      ' -InstallDir "' + WizardDirValue() + '"' +
      ' -WorkDir "' + ExpandConstant('{tmp}') + '"' +
      ' -ErrorFile "' + ErrFile + '"',
      '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then
    Result := ''
  else if LoadStringFromFile(ErrFile, Err) and (Err <> '') then
    Result := String(Err)
  else
    Result := 'IDR setup failed (PowerShell exit code ' + IntToStr(Code) + '). See the setup log.';
end;

function NextField(var S: String): String;
var
  P: Integer;
begin
  P := Pos(#9, S);
  if P = 0 then begin
    Result := S;
    S := '';
  end else begin
    Result := Copy(S, 1, P - 1);
    Delete(S, 1, P);
  end;
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage('Downloading IDR', 'Downloading the selected components and the agents they need.', nil);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Lines: TArrayOfString;
  I: Integer;
  Line, Kind, Url, Name, Sha: String;
  Err: String;
begin
  Result := True;
  if (CurPageID = wpSelectComponents) and (SelectedIds() = '') then begin
    MsgBox('Select at least one component.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if CurPageID <> wpReady then Exit;

  { Fetch and verify the signed manifest, work out what to download. }
  if not FileExists(ExpandConstant('{tmp}\idr-install.ps1')) then
    ExtractTemporaryFile('idr-install.ps1');
  Err := RunPs('Resolve');
  if Err <> '' then begin
    SuppressibleMsgBox(Err, mbCriticalError, MB_OK, IDOK);
    Result := False;
    Exit;
  end;
  LoadStringsFromFile(ExpandConstant('{tmp}\plan.tsv'), Lines);
  DownloadPage.Clear;
  for I := 0 to GetArrayLength(Lines) - 1 do begin
    Line := Lines[I];
    Kind := NextField(Line);
    if Kind = 'get' then begin
      Name := NextField(Line); { component id, unused }
      Url := NextField(Line);
      Name := NextField(Line);
      Sha := NextField(Line);
      DownloadPage.Add(Url, Name, Sha);
    end;
  end;
  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
    except
      if not DownloadPage.AbortedByUser then
        SuppressibleMsgBox(AddPeriod(GetExceptionMessage), mbCriticalError, MB_OK, IDOK);
      Result := False;
    end;
  finally
    DownloadPage.Hide;
  end;
end;

{ Install the verified downloads before Inno writes its own files; an error here
  stops setup on the Preparing page with nothing half-installed. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := RunPs('Apply');
end;
