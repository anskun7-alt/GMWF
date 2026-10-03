; ══════════════════════════════════════════════════════════════
; GMWF Installer — Premium Edition v1.6.0 (x86 / 32-bit)
; ──────────────────────────────────────────────────────────────
; Features:
;   • Premium dark-themed modern UI with GMWF emerald/gold branding
;   • License & Terms of Use agreement page
;   • "Start at Windows startup" checked by default
;   • Safe upgrades: kills running instance, cleans Hive locks
;   • Preserves all local data, sync queues, Python environments
;   • VC++ Runtime & GMWF certificate auto-provisioning
;   • Task Scheduler integration for server mode
;   • Professional finish page with launch option
; ══════════════════════════════════════════════════════════════

[Setup]
AppId={{A1B2C3D4-9F23-4C11-8ABC-1234567890AB}
AppName=GMWF
AppVersion=1.6.0
AppVerName=GMWF Management System v1.6.0 (32-bit)
AppPublisher=GMWF
AppPublisherURL=https://gmwf.pk/
AppSupportURL=https://gmwf.pk/
AppUpdatesURL=https://gmwf.pk/
AppComments=Developed by Ans for GMWF
AppCopyright=Copyright (C) 2026 GMWF. Developed by Ans.

ArchitecturesAllowed=x86

; Install to Program Files (x86)
DefaultDirName={pf}\GMWF
DefaultGroupName=GMWF

; Output
OutputDir=installer
OutputBaseFilename=GMWF-v1.6.0-x86
SetupIconFile=Installer\gmwf.ico

; Compression
Compression=lzma2/ultra64
SolidCompression=yes

; Privileges
PrivilegesRequired=admin

; ── Premium Modern UI ────────────────────────────────────────
WizardStyle=modern
WizardSizePercent=125,125

WizardImageStretch=no
WizardImageFile=Installer\gmwf_wizard_large.bmp
WizardSmallImageFile=Installer\gmwf_wizard_small.bmp
DisableDirPage=no
DisableProgramGroupPage=yes
SetupLogging=yes
UsePreviousTasks=no

; License Agreement
LicenseFile=Installer\LICENSE_EULA.txt

; Uninstall display
UninstallDisplayIcon={app}\gmwf.exe
UninstallDisplayName=GMWF Management System (32-bit)

; ── Upgrade behavior ────────────────────────────────────────
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.lock,*.hive
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupWindowTitle=GMWF Management System — Setup Wizard (32-bit)
WelcomeLabel1=Welcome to GMWF
WelcomeLabel2=This setup wizard will guide you through the installation of GMWF Management System v1.6.0 (32-bit) on your computer.%n%nGMWF is a comprehensive welfare management platform for dispensaries, donations, attendance, madrassa, and branch operations.%n%nClick Next to continue, or Cancel to exit.
ReadyLabel1=Ready to Install
ReadyLabel2a=The installer is ready to begin. Review your settings below, then click Install to proceed.
FinishedHeadingLabel=Installation Complete
FinishedLabelNoIcons=GMWF Management System has been successfully installed on your computer.%n%nYour local data, records, and configurations have been fully preserved.
FinishedLabel=GMWF Management System has been successfully installed on your computer.%n%nYour local data, records, and configurations have been fully preserved.%n%nClick Finish to close this wizard.

[Files]
; ── Main Flutter Release Build ───────────────────────────────
Source: "build\windows\x64\runner\Release\*"; \
    DestDir: "{app}"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ── Standalone Python Runtime (x86 / 32-bit) ──────────────────
Source: "Installer\python-3.12.10-embed-win32\*"; \
    DestDir: "{app}\python"; \
    Check: ShouldInstallPython; \
    Flags: recursesubdirs createallsubdirs onlyifdoesntexist uninsneveruninstall

; ── Background Sync Scripts & Configs ────────────────────────
Source: "scripts\*"; \
    DestDir: "{app}\scripts"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ── GMWF Digital Certificate ─────────────────────────────────
Source: "Installer\gmwf_trusted.cer"; \
    DestDir: "{tmp}"; \
    Flags: deleteafterinstall

; ── VC++ Redistributable ─────────────────────────────────────
Source: "Installer\vc_redist.x64.exe"; \
    DestDir: "{tmp}"; \
    Flags: deleteafterinstall

; ── App icon ─────────────────────────────────────────────────
Source: "Installer\gmwf.ico"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

[Icons]
Name: "{group}\GMWF";          Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"
Name: "{commondesktop}\GMWF";  Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"
Name: "{commonstartup}\GMWF";  Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"; Tasks: startupicon

[Tasks]
Name: "startupicon"; Description: "Launch GMWF automatically when Windows starts"; GroupDescription: "Startup:"; Flags: checkablealone
Name: "runasadmin"; Description: "Always run GMWF as administrator (Required for Biometrics & Local Server)"; GroupDescription: "Privileges:"; Flags: checkablealone
Name: "serverautostart"; Description: "Register GMWF as a Windows Task Scheduler service (High Privilege Server Mode)"; GroupDescription: "Advanced:"; Flags: checkablealone

[Registry]
; Configure Windows AppCompatFlags so GMWF always launches with administrator privileges
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\gmwf.exe"; ValueData: "~ RUNASADMIN"; Tasks: runasadmin; Flags: uninsdeletevalue
Root: HKCU; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\gmwf.exe"; ValueData: "~ RUNASADMIN"; Tasks: runasadmin; Flags: uninsdeletevalue

[Run]
Filename: "{cmd}"; \
    Parameters: "/c certutil -addstore -f ""Root"" ""{tmp}\gmwf_trusted.cer"" & certutil -addstore -f ""TrustedPublisher"" ""{tmp}\gmwf_trusted.cer"""; \
    StatusMsg: "Registering GMWF security certificate..."; \
    Flags: runhidden waituntilterminated

Filename: "{tmp}\vc_redist.x64.exe"; \
    Parameters: "/install /quiet /norestart"; \
    StatusMsg: "Installing Microsoft Visual C++ Runtime..."; \
    Flags: waituntilterminated

Filename: "{cmd}"; \
  Parameters: "/c schtasks /Create /TN ""GMWF Server"" /TR ""{app}\gmwf.exe"" /SC ONLOGON /RL HIGHEST /F"; \
  Tasks: serverautostart; \
  Flags: runhidden waituntilterminated

; 4. Auto-launch app after install (runs with admin privileges configured by installer)
Filename: "{app}\gmwf.exe"; \
    Flags: nowait runascurrentuser

[UninstallRun]
Filename: "{cmd}"; \
    Parameters: "/c taskkill /f /im gmwf.exe"; \
    Flags: runhidden waituntilterminated; \
    RunOnceId: "KillGMWF"

Filename: "{cmd}"; \
  Parameters: "/c schtasks /Delete /TN ""GMWF Server"" /F"; \
  Flags: runhidden waituntilterminated; \
  RunOnceId: "RemoveGMWFServerTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\*.log"
Type: files; Name: "{commonstartup}\GMWF.lnk"
; Type: filesandordirs; Name: "{userappdata}\com.example\gmwf"

[Code]
// ══════════════════════════════════════════════════════════════
// Premium GMWF Installer — Pascal Script Engine (x86)
// Dual-Theme Support: Windows 11 Light (Default) & Sleek Dark
// ══════════════════════════════════════════════════════════════

var
  GAccentLine: TPanel;
  GGoldLine: TPanel;
  GTasksInitialized: Boolean;
  GStepIndicator: TLabel;
  GBottomDivider: TPanel;
  GBrandLabel: TLabel;
  GVersionLabel: TLabel;
  GThemeToggleBtn: TButton;
  GIsDarkMode: Boolean;

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

function ShouldInstallPython(): Boolean;
var
  AppPython: String;
begin
  AppPython := ExpandConstant('{app}\python\python.exe');
  if FileExists(AppPython) then
  begin
    Log('[GMWF] Existing Python detected. Preserving.');
    Result := False;
  end
  else
  begin
    Log('[GMWF] No Python found. Installing bundled Python 3.12 (x86).');
    Result := True;
  end;
end;

function IsUpgrade(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\gmwf.exe'));
end;

function GetStepText(PageID: Integer): String;
begin
  case PageID of
    wpWelcome:     Result := 'STEP 1 OF 5';
    wpLicense:     Result := 'STEP 2 OF 5';
    wpSelectDir:   Result := 'STEP 3 OF 5';
    wpSelectTasks: Result := 'STEP 4 OF 5';
    wpReady:       Result := 'STEP 5 OF 5';
    wpInstalling:  Result := 'INSTALLING';
    wpFinished:    Result := 'COMPLETE';
  else
    Result := '';
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S: String;
begin
  S := '';
  if IsUpgrade() then
    S := S + 'INSTALLATION MODE' + NewLine + Space + 'Seamless Upgrade (all local data preserved)' + NewLine + NewLine
  else
    S := S + 'INSTALLATION MODE' + NewLine + Space + 'Fresh Installation' + NewLine + NewLine;

  if not ShouldInstallPython() then
    S := S + 'PYTHON RUNTIME' + NewLine + Space + 'Existing runtime found (will be preserved)' + NewLine + NewLine
  else
    S := S + 'PYTHON RUNTIME' + NewLine + Space + 'Installing bundled Python 3.12 (32-bit)' + NewLine + NewLine;

  S := S + MemoDirInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then
    S := S + MemoTasksInfo + NewLine + NewLine;

  S := S + 'COMPONENTS' + NewLine;
  S := S + Space + 'GMWF Management System v1.6.0 (32-bit)' + NewLine;
  S := S + Space + 'Python 3.12 Embedded Runtime (x86)' + NewLine;
  S := S + Space + 'Background Sync Scripts' + NewLine;
  S := S + Space + 'Visual C++ Runtime' + NewLine;
  S := S + Space + 'GMWF Security Certificate' + NewLine;
  Result := S;
end;

// ── Apply Theme: Light / Dark Mode Switcher ─────────────────
procedure ApplyTheme(DarkMode: Boolean);
var
  BgColor, SurfaceColor, HeaderColor, TextPrimary, TextSecondary, EmeraldColor, GoldColor, DividerColor: TColor;
begin
  if DarkMode then
  begin
    BgColor        := $00181512;
    SurfaceColor   := $00241E1A;
    HeaderColor    := $00241E1A;
    TextPrimary    := $00F8F8F8;
    TextSecondary  := $00D0C8C0;
    EmeraldColor   := $005CC070;
    GoldColor      := $0060B5E0;
    DividerColor   := $00382E26;

    if GThemeToggleBtn <> nil then
      GThemeToggleBtn.Caption := 'Light Mode';
  end
  else
  begin
    BgColor        := clWhite;
    SurfaceColor   := $00FAF8F7;
    HeaderColor    := clWhite;
    TextPrimary    := $00202020;
    TextSecondary  := $00514137;
    EmeraldColor   := $004A7A1A;
    GoldColor      := $005BA1C6;
    DividerColor   := $00E5E7EB;

    if GThemeToggleBtn <> nil then
      GThemeToggleBtn.Caption := 'Dark Mode';
  end;

  WizardForm.Color := BgColor;
  WizardForm.MainPanel.Color := HeaderColor;
  WizardForm.WizardSmallBitmapImage.BackColor := HeaderColor;

  if GAccentLine <> nil then GAccentLine.Color := EmeraldColor;
  if GGoldLine <> nil then GGoldLine.Color := GoldColor;
  if GBottomDivider <> nil then GBottomDivider.Color := DividerColor;

  WizardForm.PageNameLabel.Font.Color := EmeraldColor;
  WizardForm.PageDescriptionLabel.Font.Color := TextSecondary;
  if GStepIndicator <> nil then GStepIndicator.Font.Color := GoldColor;

  WizardForm.WelcomeLabel1.Font.Color := EmeraldColor;
  WizardForm.WelcomeLabel2.Font.Color := TextSecondary;
  WizardForm.FinishedHeadingLabel.Font.Color := EmeraldColor;
  WizardForm.FinishedLabel.Font.Color := TextSecondary;

  WizardForm.LicenseLabel1.Font.Color := TextSecondary;
  WizardForm.LicenseMemo.Color := SurfaceColor;
  WizardForm.LicenseMemo.Font.Color := TextPrimary;
  WizardForm.LicenseAcceptedRadio.Font.Color := EmeraldColor;
  WizardForm.LicenseNotAcceptedRadio.Font.Color := TextSecondary;

  WizardForm.SelectDirLabel.Font.Color := EmeraldColor;
  WizardForm.SelectDirBrowseLabel.Font.Color := TextSecondary;
  WizardForm.DirEdit.Color := SurfaceColor;
  WizardForm.DirEdit.Font.Color := TextPrimary;
  WizardForm.DiskSpaceLabel.Font.Color := TextSecondary;

  WizardForm.SelectTasksLabel.Font.Color := EmeraldColor;
  WizardForm.TasksList.Color := SurfaceColor;
  WizardForm.TasksList.Font.Color := TextPrimary;

  WizardForm.ReadyLabel.Font.Color := EmeraldColor;
  WizardForm.ReadyMemo.Color := SurfaceColor;
  WizardForm.ReadyMemo.Font.Color := TextPrimary;

  WizardForm.StatusLabel.Font.Color := EmeraldColor;
  WizardForm.FilenameLabel.Font.Color := TextSecondary;

  if GBrandLabel <> nil then GBrandLabel.Font.Color := EmeraldColor;
  if GVersionLabel <> nil then GVersionLabel.Font.Color := TextSecondary;
end;

procedure ThemeToggleClick(Sender: TObject);
begin
  GIsDarkMode := not GIsDarkMode;
  ApplyTheme(GIsDarkMode);
end;

procedure InitializeWizard();
begin
  WizardForm.Font.Name := 'Segoe UI';

  WizardForm.Bevel.Visible := False;
  WizardForm.Bevel1.Visible := False;

  GAccentLine := TPanel.Create(WizardForm);
  GAccentLine.Parent := WizardForm;
  GAccentLine.Left := 0;
  GAccentLine.Top := WizardForm.MainPanel.Top + WizardForm.MainPanel.Height;
  GAccentLine.Width := WizardForm.ClientWidth;
  GAccentLine.Height := ScaleY(3);
  GAccentLine.BevelOuter := bvNone;

  GGoldLine := TPanel.Create(WizardForm);
  GGoldLine.Parent := WizardForm;
  GGoldLine.Left := 0;
  GGoldLine.Top := GAccentLine.Top + GAccentLine.Height;
  GGoldLine.Width := WizardForm.ClientWidth;
  GGoldLine.Height := ScaleY(1);
  GGoldLine.BevelOuter := bvNone;

  GStepIndicator := TLabel.Create(WizardForm);
  GStepIndicator.Parent := WizardForm.MainPanel;
  GStepIndicator.AutoSize := True;
  GStepIndicator.Font.Name := 'Segoe UI';
  GStepIndicator.Font.Size := 8;
  GStepIndicator.Font.Style := [fsBold];
  GStepIndicator.Anchors := [akTop, akRight];
  GStepIndicator.Top := ScaleY(14);
  GStepIndicator.Left := WizardForm.MainPanel.ClientWidth - ScaleX(160);
  GStepIndicator.Caption := 'STEP 1 OF 5';

  GBottomDivider := TPanel.Create(WizardForm);
  GBottomDivider.Parent := WizardForm;
  GBottomDivider.Left := 0;
  GBottomDivider.Top := WizardForm.CancelButton.Top - ScaleY(10);
  GBottomDivider.Width := WizardForm.ClientWidth;
  GBottomDivider.Height := ScaleY(1);
  GBottomDivider.BevelOuter := bvNone;

  GBrandLabel := TLabel.Create(WizardForm);
  GBrandLabel.Parent := WizardForm;
  GBrandLabel.Left := ScaleX(16);
  GBrandLabel.Top := WizardForm.CancelButton.Top + ScaleY(1);
  GBrandLabel.Caption := 'GMWF Management System';
  GBrandLabel.Font.Name := 'Segoe UI';
  GBrandLabel.Font.Size := 8;
  GBrandLabel.Font.Style := [fsBold];
  GBrandLabel.AutoSize := True;

  GVersionLabel := TLabel.Create(WizardForm);
  GVersionLabel.Parent := WizardForm;
  GVersionLabel.Left := ScaleX(16);
  GVersionLabel.Top := GBrandLabel.Top + GBrandLabel.Height + ScaleY(1);
  GVersionLabel.Caption := 'v1.6.0  |  x86 Admin  |  By Ans';
  GVersionLabel.Font.Name := 'Segoe UI';
  GVersionLabel.Font.Size := 7;
  GVersionLabel.Font.Style := [];
  GVersionLabel.AutoSize := True;

  GThemeToggleBtn := TButton.Create(WizardForm);
  GThemeToggleBtn.Parent := WizardForm;
  GThemeToggleBtn.Top := WizardForm.CancelButton.Top;
  GThemeToggleBtn.Height := WizardForm.CancelButton.Height;
  GThemeToggleBtn.Width := ScaleX(92);
  if WizardForm.BackButton.Left > (ScaleX(160) + ScaleX(92)) then
    GThemeToggleBtn.Left := WizardForm.BackButton.Left - GThemeToggleBtn.Width - ScaleX(10)
  else
    GThemeToggleBtn.Left := ScaleX(150);
  GThemeToggleBtn.Font.Name := 'Segoe UI';
  GThemeToggleBtn.Font.Size := 8;
  GThemeToggleBtn.OnClick := @ThemeToggleClick;

  WizardForm.PageNameLabel.AutoSize := True;
  WizardForm.PageNameLabel.Font.Name := 'Segoe UI';
  WizardForm.PageNameLabel.Font.Size := 11;
  WizardForm.PageNameLabel.Font.Style := [fsBold];

  WizardForm.PageDescriptionLabel.AutoSize := True;
  WizardForm.PageDescriptionLabel.Font.Name := 'Segoe UI';
  WizardForm.PageDescriptionLabel.Font.Size := 9;
  WizardForm.PageDescriptionLabel.Top := WizardForm.PageNameLabel.Top + WizardForm.PageNameLabel.Height + ScaleY(4);

  WizardForm.WelcomeLabel1.AutoSize := True;
  WizardForm.WelcomeLabel1.Font.Name := 'Segoe UI';
  WizardForm.WelcomeLabel1.Font.Size := 14;
  WizardForm.WelcomeLabel1.Font.Style := [fsBold];
  WizardForm.WelcomeLabel2.Font.Name := 'Segoe UI';
  WizardForm.WelcomeLabel2.Font.Size := 9;

  WizardForm.FinishedHeadingLabel.AutoSize := True;
  WizardForm.FinishedHeadingLabel.Font.Name := 'Segoe UI';
  WizardForm.FinishedHeadingLabel.Font.Size := 14;
  WizardForm.FinishedHeadingLabel.Font.Style := [fsBold];
  WizardForm.FinishedLabel.Font.Name := 'Segoe UI';
  WizardForm.FinishedLabel.Font.Size := 9;

  WizardForm.LicenseLabel1.Font.Name := 'Segoe UI';
  WizardForm.LicenseLabel1.Font.Size := 9;
  WizardForm.LicenseMemo.Font.Name := 'Segoe UI';
  WizardForm.LicenseMemo.Font.Size := 9;
  WizardForm.LicenseAcceptedRadio.Font.Name := 'Segoe UI';
  WizardForm.LicenseAcceptedRadio.Font.Size := 9;
  WizardForm.LicenseAcceptedRadio.Font.Style := [fsBold];
  WizardForm.LicenseNotAcceptedRadio.Font.Name := 'Segoe UI';
  WizardForm.LicenseNotAcceptedRadio.Font.Size := 9;

  WizardForm.SelectDirBitmapImage.Visible := False;
  WizardForm.SelectDirLabel.Font.Name := 'Segoe UI';
  WizardForm.SelectDirLabel.Font.Size := 10;
  WizardForm.SelectDirLabel.Font.Style := [fsBold];
  WizardForm.SelectDirLabel.Left := ScaleX(8);

  WizardForm.SelectDirBrowseLabel.Font.Name := 'Segoe UI';
  WizardForm.SelectDirBrowseLabel.Font.Size := 9;
  WizardForm.SelectDirBrowseLabel.Left := ScaleX(8);

  WizardForm.DirEdit.Left := ScaleX(8);
  WizardForm.DirEdit.Font.Name := 'Segoe UI';
  WizardForm.DirEdit.Font.Size := 10;

  WizardForm.DirBrowseButton.Font.Name := 'Segoe UI';
  WizardForm.DirBrowseButton.Font.Style := [fsBold];

  WizardForm.DiskSpaceLabel.Visible := True;
  WizardForm.DiskSpaceLabel.Left := ScaleX(8);
  WizardForm.DiskSpaceLabel.Font.Name := 'Segoe UI';
  WizardForm.DiskSpaceLabel.Font.Size := 9;

  WizardForm.SelectTasksLabel.Font.Name := 'Segoe UI';
  WizardForm.SelectTasksLabel.Font.Size := 10;
  WizardForm.SelectTasksLabel.Font.Style := [fsBold];
  WizardForm.TasksList.Font.Name := 'Segoe UI';
  WizardForm.TasksList.Font.Size := 10;

  WizardForm.ReadyLabel.Font.Name := 'Segoe UI';
  WizardForm.ReadyLabel.Font.Size := 10;
  WizardForm.ReadyLabel.Font.Style := [fsBold];
  WizardForm.ReadyMemo.Font.Name := 'Segoe UI';
  WizardForm.ReadyMemo.Font.Size := 9;

  WizardForm.StatusLabel.Font.Name := 'Segoe UI';
  WizardForm.StatusLabel.Font.Size := 11;
  WizardForm.StatusLabel.Font.Style := [fsBold];
  WizardForm.FilenameLabel.Font.Name := 'Segoe UI';
  WizardForm.ProgressGauge.Height := ScaleY(22);

  WizardForm.NextButton.Font.Name := 'Segoe UI';
  WizardForm.NextButton.Font.Size := 9;
  WizardForm.NextButton.Font.Style := [fsBold];
  WizardForm.BackButton.Font.Name := 'Segoe UI';
  WizardForm.BackButton.Font.Size := 9;
  WizardForm.BackButton.Font.Style := [fsBold];
  WizardForm.CancelButton.Font.Name := 'Segoe UI';
  WizardForm.CancelButton.Font.Size := 9;

  WizardForm.BackButton.BringToFront;
  WizardForm.NextButton.BringToFront;
  WizardForm.CancelButton.BringToFront;
  GThemeToggleBtn.BringToFront;

  GIsDarkMode := False;
  ApplyTheme(False);

  WizardSelectTasks('startupicon');
  WizardSelectTasks('runasadmin');
  WizardSelectTasks('serverautostart');
end;

procedure CurPageChanged(CurPageID: Integer);
var
  IsFullPage: Boolean;
  StepText: String;
begin
  IsFullPage := (CurPageID = wpWelcome) or (CurPageID = wpFinished);
  GAccentLine.Visible := not IsFullPage;
  GGoldLine.Visible := not IsFullPage;

  StepText := GetStepText(CurPageID);
  if StepText <> '' then
    GStepIndicator.Caption := StepText;
  GStepIndicator.Visible := not IsFullPage;

  WizardForm.BackButton.BringToFront;
  WizardForm.NextButton.BringToFront;
  WizardForm.CancelButton.BringToFront;
  GThemeToggleBtn.BringToFront;

  if (CurPageID = wpSelectTasks) and (not GTasksInitialized) then
  begin
    WizardSelectTasks('startupicon');
    WizardSelectTasks('runasadmin');
    WizardSelectTasks('serverautostart');
    GTasksInitialized := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    KillProcessByName('gmwf.exe');
    Sleep(800);
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
