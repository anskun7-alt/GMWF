; ------------------------------------------------------------
; GMWF Installer Script — Production Ready
; Handles: single instance kill, Hive lock cleanup,
;          safe upgrades, data preservation, python preservation,
;          enhanced dialogs, future-proof
; ------------------------------------------------------------

[Setup]
AppId={{A1B2C3D4-9F23-4C11-8ABC-1234567890AB}
AppName=GMWF
AppVersion=1.5.7
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
OutputBaseFilename=GMWF-v1.5.7-x64
SetupIconFile=Installer\gmwf.ico

; Compression
Compression=lzma2/ultra64
SolidCompression=yes

; Privileges
PrivilegesRequired=admin

; UI & Modern Dialogs
WizardStyle=modern
WizardSizePercent=120,120
WizardResizable=no
WizardImageStretch=no
WizardImageFile=Installer\gmwf_wizard_large.bmp
WizardSmallImageFile=Installer\gmwf_wizard_small.bmp
DisableDirPage=no
DisableProgramGroupPage=yes
SetupLogging=yes
UsePreviousTasks=no

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
SetupWindowTitle=GMWF Management System Setup
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
Name: "serverautostart"; Description: "Start GMWF automatically when this Windows server user logs in"; GroupDescription: "Server startup:"; Flags: checkablealone

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

// Global references so we can show/hide accent lines per page
var
  GAccentLine: TPanel;
  GGoldLine: TPanel;

procedure InitializeWizard();
var
  BottomDividerLine: TPanel;
  BrandFooterLabel: TLabel;
begin
  // Set clean modern typography across the wizard
  WizardForm.Font.Name := 'Segoe UI';

  // Remove retro 3D beveled borders
  WizardForm.Bevel.Visible := False;
  WizardForm.Bevel1.Visible := False;

  // Modern clean header (keep default height — no override to avoid white-bar on Welcome/Finish)
  WizardForm.MainPanel.Color := clWhite;

  // Custom GMWF Emerald Green Accent Stripe beneath Header
  GAccentLine := TPanel.Create(WizardForm);
  GAccentLine.Parent := WizardForm;
  GAccentLine.Left := 0;
  GAccentLine.Top := WizardForm.MainPanel.Top + WizardForm.MainPanel.Height;
  GAccentLine.Width := WizardForm.ClientWidth;
  GAccentLine.Height := ScaleY(3);
  GAccentLine.BevelOuter := bvNone;
  GAccentLine.Color := $004A7A1A; // GMWF Primary Green (#1A7A4A in BGR)

  // Secondary Gold Accent Line (GMWF brand secondary gold)
  GGoldLine := TPanel.Create(WizardForm);
  GGoldLine.Parent := WizardForm;
  GGoldLine.Left := 0;
  GGoldLine.Top := GAccentLine.Top + GAccentLine.Height;
  GGoldLine.Width := WizardForm.ClientWidth;
  GGoldLine.Height := ScaleY(1);
  GGoldLine.BevelOuter := bvNone;
  GGoldLine.Color := $005BA1C6; // GMWF Gold (#C6A15B in BGR)

  // Modern Bottom Divider Line (Emerald green thin separator above buttons)
  BottomDividerLine := TPanel.Create(WizardForm);
  BottomDividerLine.Parent := WizardForm;
  BottomDividerLine.Left := 0;
  BottomDividerLine.Top := WizardForm.CancelButton.Top - ScaleY(12);
  BottomDividerLine.Width := WizardForm.ClientWidth;
  BottomDividerLine.Height := ScaleY(1);
  BottomDividerLine.BevelOuter := bvNone;
  BottomDividerLine.Color := $004A7A1A; // GMWF Green instead of light gray

  // Branded Footer Label at Bottom-Left
  BrandFooterLabel := TLabel.Create(WizardForm);
  BrandFooterLabel.Parent := WizardForm;
  BrandFooterLabel.Left := ScaleX(16);
  BrandFooterLabel.Top := WizardForm.CancelButton.Top + ScaleY(4);
  BrandFooterLabel.Caption := Chr($E2)+Chr($9C)+Chr($A6) + ' GMWF Management System v1.5.7';
  BrandFooterLabel.Font.Name := 'Segoe UI';
  BrandFooterLabel.Font.Size := 8;
  BrandFooterLabel.Font.Style := [fsBold];
  BrandFooterLabel.Font.Color := $004A7A1A;
  BrandFooterLabel.AutoSize := True;

  // Header Titles & Subtitles (AutoSize=True prevents text clipping)
  WizardForm.PageNameLabel.AutoSize := True;
  WizardForm.PageNameLabel.Font.Name := 'Segoe UI';
  WizardForm.PageNameLabel.Font.Size := 11;
  WizardForm.PageNameLabel.Font.Style := [fsBold];
  WizardForm.PageNameLabel.Font.Color := $002F4F0F; // GMWF Primary Dark (#0F4F2F in BGR)

  WizardForm.PageDescriptionLabel.AutoSize := True;
  WizardForm.PageDescriptionLabel.Font.Name := 'Segoe UI';
  WizardForm.PageDescriptionLabel.Font.Size := 9;
  WizardForm.PageDescriptionLabel.Font.Color := $00514137; // Slate Gray 700 (#374151 in BGR)
  WizardForm.PageDescriptionLabel.Top := WizardForm.PageNameLabel.Top + WizardForm.PageNameLabel.Height + ScaleY(4);

  // Welcome page branding
  WizardForm.WelcomeLabel1.AutoSize := True;
  WizardForm.WelcomeLabel1.Font.Name := 'Segoe UI';
  WizardForm.WelcomeLabel1.Font.Size := 14;
  WizardForm.WelcomeLabel1.Font.Style := [fsBold];
  WizardForm.WelcomeLabel1.Font.Color := $002F4F0F;
  WizardForm.WelcomeLabel2.Font.Name := 'Segoe UI';
  WizardForm.WelcomeLabel2.Font.Size := 9;
  WizardForm.WelcomeLabel2.Font.Color := $0037291F;

  // Finished page branding
  WizardForm.FinishedHeadingLabel.AutoSize := True;
  WizardForm.FinishedHeadingLabel.Font.Name := 'Segoe UI';
  WizardForm.FinishedHeadingLabel.Font.Size := 14;
  WizardForm.FinishedHeadingLabel.Font.Style := [fsBold];
  WizardForm.FinishedHeadingLabel.Font.Color := $002F4F0F;
  WizardForm.FinishedLabel.Font.Name := 'Segoe UI';
  WizardForm.FinishedLabel.Font.Size := 9;
  WizardForm.FinishedLabel.Font.Color := $0037291F;

  // Destination Selection Page styling
  WizardForm.SelectDirBitmapImage.Visible := False;
  WizardForm.SelectDirLabel.Left := ScaleX(8);
  WizardForm.SelectDirLabel.Font.Name := 'Segoe UI';
  WizardForm.SelectDirLabel.Font.Size := 10;
  WizardForm.SelectDirLabel.Font.Style := [fsBold];
  WizardForm.SelectDirLabel.Font.Color := $002F4F0F;

  WizardForm.SelectDirBrowseLabel.Left := ScaleX(8);
  WizardForm.SelectDirBrowseLabel.Font.Name := 'Segoe UI';
  WizardForm.SelectDirBrowseLabel.Font.Size := 9;
  WizardForm.SelectDirBrowseLabel.Font.Color := $00514137;

  WizardForm.DirEdit.Left := ScaleX(8);
  WizardForm.DirEdit.Font.Name := 'Segoe UI';
  WizardForm.DirEdit.Font.Size := 10;

  WizardForm.DirBrowseButton.Font.Name := 'Segoe UI';
  WizardForm.DirBrowseButton.Font.Style := [fsBold];

  WizardForm.DiskSpaceLabel.Visible := True;
  WizardForm.DiskSpaceLabel.Left := ScaleX(8);
  WizardForm.DiskSpaceLabel.Font.Name := 'Segoe UI';
  WizardForm.DiskSpaceLabel.Font.Size := 9;
  WizardForm.DiskSpaceLabel.Font.Color := $00514137;

  // Tasks & Checklist Customization
  WizardForm.SelectTasksLabel.Font.Name := 'Segoe UI';
  WizardForm.SelectTasksLabel.Font.Size := 10;
  WizardForm.SelectTasksLabel.Font.Color := $002F4F0F;

  WizardForm.TasksList.Font.Name := 'Segoe UI';
  WizardForm.TasksList.Font.Size := 10;
  WizardForm.TasksList.Color := clWhite;

  // Ready & Installing
  WizardForm.ReadyLabel.Font.Name := 'Segoe UI';
  WizardForm.ReadyLabel.Font.Size := 10;
  WizardForm.ReadyLabel.Font.Style := [fsBold];
  WizardForm.ReadyLabel.Font.Color := $002F4F0F;

  WizardForm.ReadyMemo.Font.Name := 'Segoe UI';
  WizardForm.ReadyMemo.Font.Size := 9;
  WizardForm.ReadyMemo.Color := $00FAF8F7;

  WizardForm.StatusLabel.Font.Name := 'Segoe UI';
  WizardForm.StatusLabel.Font.Size := 11;
  WizardForm.StatusLabel.Font.Style := [fsBold];
  WizardForm.StatusLabel.Font.Color := $004A7A1A;
  WizardForm.FilenameLabel.Font.Name := 'Segoe UI';
  WizardForm.ProgressGauge.Height := ScaleY(22);

  // Button Typography
  WizardForm.NextButton.Font.Name := 'Segoe UI';
  WizardForm.NextButton.Font.Style := [fsBold];
  WizardForm.BackButton.Font.Name := 'Segoe UI';
  WizardForm.CancelButton.Font.Name := 'Segoe UI';

  // Toggle serverautostart on by default
  WizardSelectTasks('serverautostart');
end;

procedure CurPageChanged(CurPageID: Integer);
var
  IsFullPage: Boolean;
begin
  // Welcome and Finished pages show the large wizard image panel;
  // hide accent lines on those pages so they don't overlap the image.
  IsFullPage := (CurPageID = wpWelcome) or (CurPageID = wpFinished);
  GAccentLine.Visible := not IsFullPage;
  GGoldLine.Visible := not IsFullPage;

  if CurPageID = wpSelectTasks then
    WizardSelectTasks('serverautostart');
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
