; ══════════════════════════════════════════════════════════════
; GMWF Installer — Premium Edition v1.6.4 (x86 / 32-bit)
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

#define MyAppVersion "1.6.4"

[Setup]
AppId={{B7E4D2A1-5C38-4F6E-9A10-2D8F6C3B9E47}
AppName=GMWF
AppVersion={#MyAppVersion}
AppVerName=GMWF Management System v{#MyAppVersion} (32-bit)
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
OutputBaseFilename=GMWF-v{#MyAppVersion}-x86
SetupIconFile=Installer\gmwf.ico

; Compression
Compression=lzma2/ultra64
SolidCompression=yes

; Privileges
PrivilegesRequired=admin

; ── Premium Modern UI ────────────────────────────────────────
WizardStyle=modern
WizardSizePercent=150,135

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
CloseApplications=force
CloseApplicationsFilter=*.exe,*.lock,*.hive
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupWindowTitle=GMWF Management System — Setup Wizard (32-bit)
WelcomeLabel1=Welcome to GMWF
WelcomeLabel2=This setup wizard will guide you through the installation of GMWF Management System v{#MyAppVersion} (32-bit) on your computer.%n%nGMWF is a comprehensive welfare management platform for dispensaries, donations, attendance, madrassa, and branch operations.%n%nClick Next to continue, or Cancel to exit.
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
; Bundled with pyzk & firebase-admin pre-installed (Zero setup / 100% offline)
; Overwrites and repairs missing/corrupted runtime DLLs (python312.dll, python3.dll, vcruntime140.dll)
Source: "Installer\python-3.12.10-embed-win32\*"; \
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
Source: "Installer\vc_redist.x64.exe"; \
    DestDir: "{tmp}"; \
    Flags: deleteafterinstall

Source: "Installer\LICENSE_EULA.txt"; DestDir: "{tmp}"; Flags: dontcopy

; ── App icon ─────────────────────────────────────────────────
Source: "Installer\gmwf.ico"; \
    DestDir: "{app}"; \
    Flags: ignoreversion

[Icons]
Name: "{group}\GMWF";          Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"
Name: "{commondesktop}\GMWF";  Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"; Tasks: desktopicon
Name: "{commonstartup}\GMWF";  Filename: "{app}\gmwf.exe"; WorkingDir: "{app}"; IconFilename: "{app}\gmwf.ico"; Tasks: startupicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
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

; ── Permanent Inbound & Outbound Windows Firewall Rules ──────
Filename: "{cmd}"; \
    Parameters: "/c netsh advfirewall firewall show rule name=""GMWF Application (Inbound)"" >nul 2>&1 || netsh advfirewall firewall add rule name=""GMWF Application (Inbound)"" dir=in action=allow program=""{app}\gmwf.exe"" enable=yes profile=any"; \
    StatusMsg: "Configuring Windows Defender Firewall (Inbound: gmwf.exe)..."; \
    Flags: runhidden waituntilterminated

Filename: "{cmd}"; \
    Parameters: "/c netsh advfirewall firewall show rule name=""GMWF Application (Outbound)"" >nul 2>&1 || netsh advfirewall firewall add rule name=""GMWF Application (Outbound)"" dir=out action=allow program=""{app}\gmwf.exe"" enable=yes profile=any"; \
    StatusMsg: "Configuring Windows Defender Firewall (Outbound: gmwf.exe)..."; \
    Flags: runhidden waituntilterminated

Filename: "{cmd}"; \
    Parameters: "/c netsh advfirewall firewall show rule name=""GMWF Python Service (Inbound)"" >nul 2>&1 || netsh advfirewall firewall add rule name=""GMWF Python Service (Inbound)"" dir=in action=allow program=""{app}\python\python.exe"" enable=yes profile=any"; \
    StatusMsg: "Configuring Windows Defender Firewall (Inbound: Python Service)..."; \
    Flags: runhidden waituntilterminated

Filename: "{cmd}"; \
    Parameters: "/c netsh advfirewall firewall show rule name=""GMWF Python Service (Outbound)"" >nul 2>&1 || netsh advfirewall firewall add rule name=""GMWF Python Service (Outbound)"" dir=out action=allow program=""{app}\python\python.exe"" enable=yes profile=any"; \
    StatusMsg: "Configuring Windows Defender Firewall (Outbound: Python Service)..."; \
    Flags: runhidden waituntilterminated

; 4. Auto-launch app after install (handled reliably in [Code] via LaunchGMWFApplication with error recovery)
; Filename: "{app}\gmwf.exe"; Flags: nowait runascurrentuser skipifsilent

[UninstallRun]
Filename: "{cmd}"; \
    Parameters: "/c taskkill /f /im gmwf.exe /im python.exe /im pythonw.exe >nul 2>&1"; \
    Flags: runhidden waituntilterminated; \
    RunOnceId: "KillGMWF"

Filename: "{cmd}"; \
    Parameters: "/c schtasks /Delete /TN ""GMWF Server"" /F"; \
    Flags: runhidden waituntilterminated; \
    RunOnceId: "RemoveGMWFServerTask"

Filename: "{cmd}"; \
    Parameters: "/c netsh advfirewall firewall delete rule name=""GMWF Application (Inbound)"" & netsh advfirewall firewall delete rule name=""GMWF Application (Outbound)"" & netsh advfirewall firewall delete rule name=""GMWF Python Service (Inbound)"" & netsh advfirewall firewall delete rule name=""GMWF Python Service (Outbound)"" & netsh advfirewall firewall delete rule name=""GMWF LAN Sync and ADMS (TCP-In)"" & netsh advfirewall firewall delete rule name=""GMWF LAN Sync and ADMS (TCP-Out)"" & netsh advfirewall firewall delete rule name=""GMWF UDP Discovery and Biometrics (UDP-In)"" & netsh advfirewall firewall delete rule name=""GMWF UDP Discovery and Biometrics (UDP-Out)"""; \
    Flags: runhidden waituntilterminated; \
    RunOnceId: "RemoveGMWFFirewallRules"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\*.log"
Type: filesandordirs; Name: "{app}\python"
Type: files; Name: "{commonstartup}\GMWF.lnk"
; Type: filesandordirs; Name: "{userappdata}\com.example\gmwf"

[Code]
#include "Installer\GMWF_DesignSystem.isi"

// ── Utility: Kill Process ───────────────────────────────────
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

function IsPythonInstalled(): Boolean;
var
  AppPython, AppDll: String;
begin
  AppPython := ExpandConstant('{app}\python\python.exe');
  AppDll := ExpandConstant('{app}\python\python312.dll');
  Result := FileExists(AppPython) and FileExists(AppDll);
end;

function ShouldInstallPython(): Boolean;
begin
  // Always install and repair Python runtime to prevent missing python312.dll errors
  Result := True;
end;

function IsUpgrade(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\gmwf.exe'));
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

  if IsPythonInstalled() then
    S := S + 'PYTHON RUNTIME' + NewLine + Space + 'Updating & repairing bundled Python 3.12 runtime (32-bit)' + NewLine + NewLine
  else
    S := S + 'PYTHON RUNTIME' + NewLine + Space + 'Installing bundled Python 3.12 embedded runtime (32-bit)' + NewLine + NewLine;

  S := S + MemoDirInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then
    S := S + MemoTasksInfo + NewLine + NewLine;

  S := S + 'COMPONENTS' + NewLine;
  S := S + Space + 'GMWF Management System v1.6.4 (32-bit)' + NewLine;
  S := S + Space + 'Python 3.12 Embedded Runtime (x86)' + NewLine;
  S := S + Space + 'Background Sync Scripts' + NewLine;
  S := S + Space + 'Visual C++ Runtime' + NewLine;
  S := S + Space + 'GMWF Security Certificate' + NewLine;
  Result := S;
end;



// ══════════════════════════════════════════════════════════════
// PROFESSIONAL MODERN UI — InitializeWizard
// ══════════════════════════════════════════════════════════════
procedure InitializeWizard();
begin
  SetupGMWFDesignSystemLayout();

  // Ensure All Options are Checked by Default
  WizardSelectTasks('desktopicon');
  WizardSelectTasks('startupicon');
  WizardSelectTasks('runasadmin');
  WizardSelectTasks('serverautostart');
end;

// ══════════════════════════════════════════════════════════════
// PAGE CHANGE — step indicator, tasks init, and auto-finish
// ══════════════════════════════════════════════════════════════
procedure CurPageChanged(CurPageID: Integer);
var
  SidebarW, ContentW: Integer;
begin
  if GSidebarPanel <> nil then
  begin
    SidebarW := GSidebarPanel.Width;
    ContentW := WizardForm.ClientWidth - SidebarW;

    WizardForm.OuterNotebook.SetBounds(SidebarW, 0, ContentW, GBottomSep.Top);
    WizardForm.MainPanel.SetBounds(SidebarW, 0, ContentW, ScaleY(74));
    WizardForm.InnerNotebook.SetBounds(0, ScaleY(74), ContentW, WizardForm.OuterNotebook.Height - ScaleY(74));
    WizardForm.PageNameLabel.Width := ContentW - ScaleX(48);
    WizardForm.PageDescriptionLabel.Width := ContentW - ScaleX(48);
  end;

  if CurPageID = wpWelcome then
    WizardForm.BackButton.Visible := False;

  if CurPageID = wpFinished then
    WizardForm.NextButton.Caption := 'Finish'
  else
    WizardForm.NextButton.Caption := 'Next →';

  // Responsive button alignment
  WizardForm.CancelButton.Left := WizardForm.ClientWidth - WizardForm.CancelButton.Width - ScaleX(24);
  WizardForm.NextButton.Left := WizardForm.CancelButton.Left - WizardForm.NextButton.Width - ScaleX(10);
  WizardForm.BackButton.Left := WizardForm.NextButton.Left - WizardForm.BackButton.Width - ScaleX(8);

  // Dynamically update sidebar stepper and framing
  UpdateGMWFSidebar(CurPageID);
  ApplyGMWFTheme(GIsDarkMode);

  // Clear, non-overflowing page header descriptions
  case CurPageID of
    wpWelcome:
    begin
      WizardForm.PageNameLabel.Caption := 'Welcome';
      WizardForm.PageDescriptionLabel.Caption := 'Install GMWF Management System on your computer.';
    end;
    wpLicense:
    begin
      WizardForm.PageNameLabel.Caption := 'License Agreement';
      WizardForm.PageDescriptionLabel.Caption := 'Review and accept the license terms before proceeding.';
    end;
    wpSelectDir:
    begin
      WizardForm.PageNameLabel.Caption := 'Destination Location';
      WizardForm.PageDescriptionLabel.Caption := 'Choose the folder where GMWF will be installed.';
    end;
    wpSelectTasks:
    begin
      WizardForm.PageNameLabel.Caption := 'Additional Tasks';
      WizardForm.PageDescriptionLabel.Caption := 'Select shortcuts and desktop configurations.';
    end;
    wpReady:
    begin
      WizardForm.PageNameLabel.Caption := 'Ready to Install';
      WizardForm.PageDescriptionLabel.Caption := 'Setup is ready to begin installing GMWF on your computer.';
    end;
    wpInstalling:
    begin
      WizardForm.PageNameLabel.Caption := 'Installing';
      WizardForm.PageDescriptionLabel.Caption := 'Please wait while Setup installs GMWF on your computer.';
      StartProgressTimer();
    end;
    wpFinished:
    begin
      StopProgressTimer();
      WizardForm.PageNameLabel.Caption := 'Complete';
      WizardForm.PageDescriptionLabel.Caption := 'GMWF Management System has been successfully installed.';
    end;
  end;

  // Ensure navigation buttons are always visible on every step
  WizardForm.BackButton.BringToFront;
  WizardForm.NextButton.BringToFront;
  WizardForm.CancelButton.BringToFront;

  if (CurPageID = wpSelectTasks) and (not GTasksInitialized) then
  begin
    WizardSelectTasks('desktopicon');
    WizardSelectTasks('startupicon');
    WizardSelectTasks('runasadmin');
    WizardSelectTasks('serverautostart');
    GTasksInitialized := True;
  end;

  // Installation complete: launch app reliably and close setup
  if CurPageID = wpFinished then
  begin
    LaunchGMWFApplication();
    WizardForm.NextButton.OnClick(WizardForm.NextButton);
  end;
end;

// ══════════════════════════════════════════════════════════════
// PRE-INSTALL — kill running instances, release file locks, clean locks
// ══════════════════════════════════════════════════════════════
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    // Terminate application and background python daemons so python312.dll is not locked
    KillProcessByName('gmwf.exe');
    KillProcessByName('python.exe');
    KillProcessByName('pythonw.exe');
    Sleep(1000);
    DeleteHiveLockFiles();
  end;
end;

// ══════════════════════════════════════════════════════════════
// UNINSTALL CLEANUP
// ══════════════════════════════════════════════════════════════
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    KillProcessByName('gmwf.exe');
    KillProcessByName('python.exe');
    KillProcessByName('pythonw.exe');
    Sleep(800);
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    if (not UninstallSilent) and
       (MsgBox('Also delete GMWF local data (records, sync queues, credentials)?' + #13#10 +
               'Choose No to keep your data for a future reinstall.',
               mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES) then
      DelTree(ExpandConstant('{userappdata}\com.example\gmwf'), True, True, True);
  end;
end;
