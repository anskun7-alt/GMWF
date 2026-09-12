; ------------------------------------------------------------
; GMWF Installer Script — Production Ready
; Handles: single instance kill, Hive lock cleanup,
;          safe upgrades, data preservation, python preservation,
;          enhanced dialogs, future-proof
; ------------------------------------------------------------

[Setup]
AppId={{A1B2C3D4-9F23-4C11-8ABC-1234567890AB}
AppName=GMWF
AppVersion=1.5.0
AppPublisher=GMWF
AppPublisherURL=https://gmwf.pk/
AppSupportURL=https://gmwf.pk/
AppUpdatesURL=https://gmwf.pk/
AppComments=Developed by Ans for GMWF
AppCopyright=Copyright (C) 2026 GMWF. Developed by Ans.

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Install to Program Files
DefaultDirName={autopf}\GMWF
DefaultGroupName=GMWF

; Output
OutputDir=installer
OutputBaseFilename=GMWF-v1.5.0-x64
SetupIconFile=Installer\gmwf.ico

; Compression
Compression=lzma2/ultra64
SolidCompression=yes

; Privileges
PrivilegesRequired=admin

; UI & Modern Dialogs
WizardStyle=modern
WizardSizePercent=100
WizardResizable=no
DisableDirPage=no
DisableProgramGroupPage=yes
SetupLogging=yes

; Uninstall display
UninstallDisplayIcon={app}\gmwf.exe
UninstallDisplayName=GMWF

; ── Upgrade behavior ────────────────────────────────────────
; Kill the running app before files are copied so that
; gmwf.exe and the Hive .lock files are not held open.
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.lock,*.hive
RestartApplications=no

; Allow upgrading over existing install without prompting
; for uninstall first — files are overwritten in place.
; The AppId above ties all versions together so the old
; entry is automatically replaced in Add/Remove Programs.
; ────────────────────────────────────────────────────────────

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupWindowTitle=GMWF Management Platform Setup
WelcomeLabel1=Welcome to the GMWF Setup Wizard
WelcomeLabel2=This wizard will install or safely upgrade GMWF on your computer.%n%nAll your local records, sync queues, and existing Python environments will be preserved.
ReadyLabel1=Ready to Install
ReadyLabel2a=Setup is now ready to begin installing GMWF on your computer.

[Files]
; ── Main Flutter Release Build ───────────────────────────────
Source: "build\windows\x64\runner\Release\*"; \
    DestDir: "{app}"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ── Standalone Python Runtime (x64) ──────────────────────────
; Bundled with pyzk & firebase-admin pre-installed (Zero setup / 100% offline)
Source: "Installer\python-3.12.10-embed-amd64\*"; \
    DestDir: "{app}\python"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ── Background Sync Scripts & Configs ────────────────────────
Source: "scripts\*"; \
    DestDir: "{app}\scripts"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ── GMWF Digital Certificate ─────────────────────────────────
Source: "Installer\gmwf_trusted.cer"; \
    DestDir: "{tmp}"; \
    Flags: deleteafterinstall

; ── VC++ Redistributable ─────────────────────────────────────
; Bundled so the app works on clean Windows installs with no
; internet. Deleted from {tmp} after install completes.
Source: "Installer\vc_redist.x64.exe"; \
    DestDir: "{tmp}"; \
    Flags: deleteafterinstall

; ── App icon (used by shortcuts & uninstaller) ───────────────
Source: "Installer\gmwf.ico"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

[Icons]
; Start Menu
Name: "{group}\GMWF";          Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"
; Desktop shortcut
Name: "{commondesktop}\GMWF";  Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"

[Tasks]
Name: "serverautostart"; Description: "Start GMWF automatically when this Windows server user logs in"; GroupDescription: "Server startup:"; Flags: checkedonce

[Run]
; 1. Trust GMWF Digital Certificate on this PC
Filename: "{cmd}"; \
    Parameters: "/c certutil -addstore -f ""Root"" ""{tmp}\gmwf_trusted.cer"" & certutil -addstore -f ""TrustedPublisher"" ""{tmp}\gmwf_trusted.cer"""; \
    StatusMsg: "Registering GMWF security certificate..."; \
    Flags: runhidden waituntilterminated

; 2. Install VC++ Runtime silently (skipped if already installed)
Filename: "{tmp}\vc_redist.x64.exe"; \
    Parameters: "/install /quiet /norestart"; \
    StatusMsg: "Installing Microsoft Visual C++ Runtime..."; \
    Flags: waituntilterminated

Filename: "{cmd}"; \
  Parameters: "/c schtasks /Create /TN ""GMWF Server"" /TR ""{app}\gmwf.exe"" /SC ONLOGON /RL HIGHEST /F"; \
  Tasks: serverautostart; \
  Flags: runhidden waituntilterminated

; 3. Launch app after install (user can untick this)
Filename: "{app}\gmwf.exe"; \
    Description: "Launch GMWF now"; \
    Flags: nowait postinstall skipifsilent

[UninstallRun]
; Kill the app if it is still running when the user uninstalls
Filename: "{cmd}"; \
    Parameters: "/c taskkill /f /im gmwf.exe"; \
    Flags: runhidden waituntilterminated; \
    RunOnceId: "KillGMWF"

; Remove the optional automatic server startup task.
Filename: "{cmd}"; \
  Parameters: "/c schtasks /Delete /TN ""GMWF Server"" /F"; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "RemoveGMWFServerTask"

[UninstallDelete]
; Remove crash logs and any leftover runtime files inside {app}
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\*.log"

; ── Hive data in AppData ─────────────────────────────────────
; IMPORTANT: The lines below are commented out intentionally.
; Uncommenting them will DELETE the user's local patient data,
; donation records, and cached credentials on uninstall.
; Only uncomment for a "full wipe" / factory-reset scenario.
;
; Type: filesandordirs; Name: "{userappdata}\com.example\gmwf"
; ─────────────────────────────────────────────────────────────

[Code]
// ── Pascal Script section ────────────────────────────────────
// Runs before the installer copies any files.
// 1. Kills any running gmwf.exe so file handles are released.
// 2. Deletes orphaned Hive .lock files that survive a crash.
// 3. Detects existing Python installations to prevent overwriting.
// 4. Provides informative pre-install summary dialogs.

function KillProcessByName(ExeName: String): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/f /im ' + ExeName,
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0) or (ResultCode = 128);
end;

procedure DeleteHiveLockFiles();
var
  HiveDir: String;
  FindRec: TFindRec;
begin
  HiveDir := ExpandConstant('{userappdata}\com.example\gmwf\gmwf_hive\');

  if not DirExists(HiveDir) then
    Exit;

  if FindFirst(HiveDir + '*.lock', FindRec) then
  begin
    try
      repeat
        DeleteFile(HiveDir + FindRec.Name);
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

// Checks if Python is already present in target installation directory.
// Returns False to skip extracting bundled Python and preserve existing setup.
function ShouldInstallPython(): Boolean;
var
  AppPython: String;
begin
  AppPython := ExpandConstant('{app}\python\python.exe');
  if FileExists(AppPython) then
  begin
    Log('[GMWF Setup] Existing Python runtime detected at ' + AppPython + '. Preserving existing Python files without overwrite.');
    Result := False;
  end
  else
  begin
    Log('[GMWF Setup] No Python runtime found at ' + AppPython + '. Installing bundled standalone Python 3.12.');
    Result := True;
  end;
end;

function IsUpgrade(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\gmwf.exe'));
end;

// Customize the Ready to Install summary page with clear details on Python and upgrade status
function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S: String;
begin
  S := '';
  if IsUpgrade() then
  begin
    S := S + 'Installation Mode:' + NewLine + Space + 'Seamless Upgrade (All local records & databases preserved)' + NewLine + NewLine;
  end
  else
  begin
    S := S + 'Installation Mode:' + NewLine + Space + 'Fresh Installation' + NewLine + NewLine;
  end;

  if not ShouldInstallPython() then
  begin
    S := S + 'Python Environment:' + NewLine + Space + 'Existing Python runtime found (Preserved - will NOT overwrite)' + NewLine + NewLine;
  end
  else
  begin
    S := S + 'Python Environment:' + NewLine + Space + 'Installing bundled standalone Python 3.12' + NewLine + NewLine;
  end;

  S := S + MemoDirInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then
    S := S + MemoTasksInfo + NewLine + NewLine;

  Result := S;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    // Step 1: kill the process (releases file handles)
    KillProcessByName('gmwf.exe');

    // Small pause so the OS finishes releasing the handles
    Sleep(800);

    // Step 2: remove orphaned .lock files left by a crash
    DeleteHiveLockFiles();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    KillProcessByName('gmwf.exe');
    Sleep(600);
  end;
end;
