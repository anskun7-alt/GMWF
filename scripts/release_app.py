import os
import re
import sys
import subprocess

def log(msg):
    print(f"\n[GMWF Release Helper] {msg}")

def main():
    if len(sys.argv) > 1:
        new_version = sys.argv[1].strip()
    else:
        log("Usage: python scripts/release_app.py <new_version>  (e.g. python scripts/release_app.py 1.3.8)")
        sys.exit(1)

    clean_ver = new_version.lstrip('v')
    
    # 1. Update pubspec.yaml (Keep exact clean version)
    pubspec_path = os.path.join(os.getcwd(), 'pubspec.yaml')
    if os.path.exists(pubspec_path):
        with open(pubspec_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        new_ver_str = f"version: {clean_ver}"
        content = re.sub(r'version:\s*[\d.]+(?:\+\d+)?', new_ver_str, content)
        with open(pubspec_path, 'w', encoding='utf-8') as f:
            f.write(content)
        log(f"Updated pubspec.yaml to {new_ver_str}")

    # 2. Update AutoUpdateService
    auto_update_path = os.path.join(os.getcwd(), 'lib', 'services', 'auto_update_service.dart')
    if os.path.exists(auto_update_path):
        with open(auto_update_path, 'r', encoding='utf-8') as f:
            content = f.read()
        content = re.sub(r"static const String currentVersion = '[^']+';", f"static const String currentVersion = '{clean_ver}';", content)
        content = re.sub(r"static const String fallbackVersion = '[^']+';", f"static const String fallbackVersion = '{clean_ver}';", content)
        with open(auto_update_path, 'w', encoding='utf-8') as f:
            f.write(content)
        log(f"Updated auto_update_service.dart version to '{clean_ver}'")

    # 3. Update GMWFSetup.iss & GMWFSetup_x86.iss
    for iss_name, arch in [('GMWFSetup.iss', 'x64'), ('GMWFSetup_x86.iss', 'x86')]:
        iss_path = os.path.join(os.getcwd(), iss_name)
        if os.path.exists(iss_path):
            with open(iss_path, 'r', encoding='utf-8') as f:
                content = f.read()
            content = re.sub(r'#define MyAppVersion "[^"]+"', f'#define MyAppVersion "{clean_ver}"', content)
            content = re.sub(r'AppVersion=[\d.]+', f'AppVersion={clean_ver}', content)
            content = re.sub(r'AppVerName=GMWF Management System v[\d.]+', f'AppVerName=GMWF Management System v{clean_ver}', content)
            content = re.sub(r'OutputBaseFilename=GMWF-v[\d.]+-(' + arch + ')', f'OutputBaseFilename=GMWF-v{clean_ver}-\\1', content)
            with open(iss_path, 'w', encoding='utf-8') as f:
                f.write(content)
            log(f"Updated {iss_name} to version {clean_ver}")

    # 4. Build Universal Android Release APK
    log("Building Android Release APK...")
    res_apk = subprocess.run(["flutter", "build", "apk", "--release"], shell=True)
    if res_apk.returncode != 0:
        log("Android build failed!")
        sys.exit(1)

    # 5. Build Web Release
    log("Building Web Release...")
    res_web = subprocess.run(["flutter", "build", "web", "--release"], shell=True)
    if res_web.returncode != 0:
        log("Web build failed!")
        sys.exit(1)

    # 6. Build Windows Release
    log("Building Windows Release Executable...")
    res_win = subprocess.run(["flutter", "build", "windows", "--release"], shell=True)
    if res_win.returncode != 0:
        log("Windows build failed!")
        sys.exit(1)

    # 7. Build Inno Setup Installers (x64 and x86) if ISCC is installed
    iscc_candidates = [
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe"),
        r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        r"C:\Program Files\Inno Setup 6\ISCC.exe",
    ]
    iscc_path = next((p for p in iscc_candidates if os.path.exists(p)), None)
    if iscc_path:
        for iss_file in ['GMWFSetup.iss', 'GMWFSetup_x86.iss']:
            iss_full_path = os.path.join(os.getcwd(), iss_file)
            if os.path.exists(iss_full_path):
                log(f"Compiling Inno Setup Installer: {iss_file}...")
                subprocess.run([iscc_path, iss_full_path])

    # 8. Upload code to GitHub
    log("Committing source code to Git...")
    subprocess.run(["git", "add", "."], shell=True)
    subprocess.run(["git", "commit", "-m", f"Release v{clean_ver}: update builds and code sync"], shell=True)
    # Detect current git branch
    try:
        branch_out = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], shell=True).decode().strip()
        if branch_out:
            log(f"Pushing to origin/{branch_out}...")
            subprocess.run(["git", "push", "origin", branch_out], shell=True)
    except Exception as e:
        log(f"Git push notice: {e}")

    log(f"RELEASE v{clean_ver} BUILD SUCCESSFUL!")
    print(f"""
============================================================
GMWF RELEASE v{clean_ver} ASSETS READY FOR GITHUB RELEASE:
============================================================
1. Android Universal Release APK:
   build/app/outputs/flutter-apk/app-release.apk

2. Web Release:
   build/web/

3. Windows Release Executable / Assets:
   build/windows/x64/runner/Release/
   (Or Installer if compiled: installer/GMWF-v{clean_ver}-x64.exe)

Upload these assets to GitHub Release tag: v{clean_ver}
============================================================
""")

if __name__ == '__main__':
    main()
