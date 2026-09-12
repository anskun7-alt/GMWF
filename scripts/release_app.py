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
    
    # 1. Update pubspec.yaml
    pubspec_path = os.path.join(os.getcwd(), 'pubspec.yaml')
    if os.path.exists(pubspec_path):
        with open(pubspec_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        match = re.search(r'version:\s*([\d.]+)(?:\+(\d+))?', content)
        if match:
            old_build = int(match.group(2)) if match.group(2) else 1
            new_build = old_build + 1
            new_ver_str = f"version: {clean_ver}+{new_build}"
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
        content = re.sub(r"static const String minSupportedVersion = '[^']+';", f"static const String minSupportedVersion = '{clean_ver}';", content)
        with open(auto_update_path, 'w', encoding='utf-8') as f:
            f.write(content)
        log(f"Updated auto_update_service.dart currentVersion to '{clean_ver}'")

    # 3. Update GMWFSetup.iss & GMWFSetup_x86.iss
    for iss_name, arch in [('GMWFSetup.iss', 'x64'), ('GMWFSetup_x86.iss', 'x86')]:
        iss_path = os.path.join(os.getcwd(), iss_name)
        if os.path.exists(iss_path):
            with open(iss_path, 'r', encoding='utf-8') as f:
                content = f.read()
            content = re.sub(r'AppVersion=[\d.]+', f'AppVersion={clean_ver}', content)
            content = re.sub(r'OutputBaseFilename=GMWF-v[\d.]+-(' + arch + ')', f'OutputBaseFilename=GMWF-v{clean_ver}-\\1', content)
            with open(iss_path, 'w', encoding='utf-8') as f:
                f.write(content)
            log(f"Updated {iss_name} to version {clean_ver}")

    # 4. Build Android Release APK with persistent release keystore
    log("Building Android Release APKs (split per ABI)...")
    res_apk = subprocess.run(["flutter", "build", "apk", "--release", "--split-per-abi"], shell=True)
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

    # 7. Build Inno Setup Installer if ISCC is installed
    iscc_path = r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    if os.path.exists(iscc_path):
        log("Compiling Inno Setup Installer...")
        subprocess.run([iscc_path, iss_path])

    log(f"RELEASE v{clean_ver} BUILD SUCCESSFUL!")
    print(f"""
============================================================
GMWF RELEASE v{clean_ver} ASSETS READY FOR GITHUB RELEASE:
============================================================
1. Android ARM64 APK:
   build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

2. Android ARMv7 APK:
   build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk

3. Web Release:
   build/web/

4. Windows Installer:
   installer/GMWF-v{clean_ver}-x64.exe

Upload these assets to GitHub Release tag: v{clean_ver}
============================================================
""")

if __name__ == '__main__':
    main()
