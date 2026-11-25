; Inno Setup script for the MotionAI Windows installer (built in CI by
; .github/workflows/build-windows.yml). Per-user install, no admin needed.
; Defines passed by CI: AppVersion, SourceDir (flutter Release folder), OutDir.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutDir
  #define OutDir ".."
#endif

[Setup]
AppId={{8E3B5F2A-6C1D-4B7E-9A2F-3D4C5B6A7E81}
AppName=MotionAI
AppVersion={#AppVersion}
AppVerName=MotionAI {#AppVersion}
AppPublisher=Mohitflix
AppPublisherURL=https://github.com/mohitbansaldev/motionai
DefaultDirName={localappdata}\Programs\MotionAI
DefaultGroupName=MotionAI
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=MotionAI-Setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\motionai.exe
UninstallDisplayName=MotionAI
CloseApplications=force
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MotionAI"; Filename: "{app}\motionai.exe"
Name: "{autodesktop}\MotionAI"; Filename: "{app}\motionai.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\motionai.exe"; Description: "{cm:LaunchProgram,MotionAI}"; Flags: nowait postinstall
