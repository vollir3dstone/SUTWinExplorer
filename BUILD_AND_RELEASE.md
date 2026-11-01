# Build and Release

## Requirements

- Windows x64
- .NET 10 SDK

The application targets `net10.0-windows` and uses WPF. The publish profiles target `win-x64`.
The user-facing product name is `KIS Explorer`, and its publisher is `SUT`.
The project and internal assembly retain the `SUTWinExplorer` name.
The product version is read from the first line of [ReleaseDescription.txt](ReleaseDescription.txt). Edit the file before building; see [RELEASE_GUIDE.md](RELEASE_GUIDE.md).

## Build

From the repository root, build the application in Debug configuration:

```powershell
dotnet build .\SUTWinExplorer.csproj -c Debug
```

The Debug application is `bin\Debug\net10.0-windows\KIS Explorer.exe`.

Do not run a standard Release build with `dotnet build -c Release`. The only Release builds are the `Included` and `Dependent` publish profiles below.

## Publish Profiles

Publish a profile from the repository root with:

```powershell
dotnet publish .\SUTWinExplorer.csproj -p:PublishProfile=Included
dotnet publish .\SUTWinExplorer.csproj -p:PublishProfile=Dependent
```

Each command creates or updates its own output directory under `bin\Release`.

### Included

Profile: `Properties\PublishProfiles\Included.pubxml`

- Publishes a single-file, self-contained `win-x64` application.
- Includes the .NET runtime, so the target machine does not need a separate .NET installation.
- Output directory: `bin\Release\net10.0-included`
- The executable is larger because it contains the runtime.

### Dependent

Profile: `Properties\PublishProfiles\Dependent.pubxml`

- Publishes a single-file, framework-dependent `win-x64` application.
- The target machine must have the .NET 10 Desktop Runtime for Windows x64 installed. The regular .NET runtime alone is not sufficient for this WPF application.
- Output directory: `bin\Release\net10.0-dependent`
- The executable is much smaller because it uses the installed .NET runtime.

Both profiles enable native-library self-extraction. The publish output includes `KIS Explorer.exe` and a `.pdb` symbols file.

## Release Checklist

1. Build the application with `dotnet build .\SUTWinExplorer.csproj -c Debug`.
2. Publish the `Included` profile for machines that should not require a preinstalled .NET runtime, or publish the `Dependent` profile when the .NET 10 Desktop Runtime is a deployment prerequisite.
3. Distribute the contents of the selected output directory. Keep the `.pdb` file for diagnostics if desired; it is not required to run the application.

Running `dotnet publish` directly creates application builds only. It does not create an installer or upload artifacts to a release service.

## Build Installers

### Requirements and Files

- Windows x64, the .NET 10 SDK, and Inno Setup 6.
- `ISCC.exe` must be available on `PATH` or installed in the standard Inno Setup 6 directory under `Program Files`.
- `installer-config\installer.json` is the versioned configuration: it contains shared product metadata and a list of installer profiles. The version comes from the first line of `ReleaseDescription.txt`.
- `installer-config\installer.iss` is the versioned Inno Setup template. It contains the installer behavior and layout, such as the destination directory, application files, Start Menu shortcut, and optional shell integration. It is not generated from the JSON.
- `installer-config\build-installer.ps1` orchestrates publishing, creates one complete temporary ISS script per selected profile, and invokes `ISCC.exe`.

The JSON and ISS have different responsibilities. The JSON supplies values that vary between builds; the ISS template defines what the installer does. For each profile, the PowerShell script prepends Inno Setup `#define` directives to the template and writes the resulting complete script to `installer\Temp\<profileId>.iss`. Inno Setup compiles that generated script, not the template file directly. The temporary ISS file for each selected profile is regenerated on every script run and should not be edited manually. Files for profiles not selected in a filtered run are left untouched.

### Configuration

The root object must have `_type` set to `installer_profiles`. Shared properties are `appName` and `publisher`. Each entry in `profiles` must have `_type` set to `profile`, a unique `profileId`, and a `configuration` object. The current configuration supports:

- `publishProfile`: `Included` or `Dependent`; selects the matching MSBuild publish profile and output directory.
- `addFolderContextMenu`: Boolean; controls whether the per-user Explorer folder context-menu entry is included and registered for removal on uninstall.

Example:

```json
{
	"_type": "installer_profiles",
	"appName": "KIS Explorer",
	"publisher": "SUT",
	"profiles": [
		{
			"_type": "profile",
			"profileId": "net-included",
			"configuration": {
				"publishProfile": "Included",
				"addFolderContextMenu": true
			}
		},
		{
			"_type": "profile",
			"profileId": "net-dependent",
			"configuration": {
				"publishProfile": "Dependent",
				"addFolderContextMenu": true
			}
		}
	]
}
```

`profileId` is used in the generated temporary script and installer filename. `publishProfile` must match one of the two profiles supported by the build script. To add another installer variant, add a profile entry using a supported publish profile and configure its options; the installer behavior itself remains in `installer.iss`.

### Build and Outputs

The installer script is not automatically run by `dotnet build` or `dotnet publish`. Run it explicitly from the repository root. With no filter it processes every entry in the JSON profile list:

```powershell
.\installer-config\build-installer.ps1
```

To process only one or more selected profiles, pass their IDs:

```powershell
.\installer-config\build-installer.ps1 -ProfileId net-included
```

To select multiple profiles in one run:

```powershell
.\installer-config\build-installer.ps1 -ProfileId net-included,net-dependent
```

For each selected profile, the script performs these steps:

1. Validates the configuration and resolves `publishProfile` to its publish output directory.
2. Checks that the corresponding `KIS Explorer.exe` is not running. If it is, the script stops with an instruction to close it; it does not terminate the application.
3. Runs `dotnet publish` for that profile. `Included` publishes to `bin\Release\net10.0-included`; `Dependent` publishes to `bin\Release\net10.0-dependent`.
4. Prepends the shared metadata, profile ID, publish directory, installer output directory, and context-menu option as `#define` directives to the ISS template. The resulting complete per-profile ISS file is written under `installer\Temp`.
5. Runs Inno Setup's command-line compiler (`ISCC.exe`) on that generated ISS file.

The setup executable is written to `installer\Release` as `<appName> v<version> Installer <profileId>.exe`. Characters not allowed in Windows filenames are encoded in the filename; the installer metadata retains the original version. The installer installs per-user under `%LOCALAPPDATA%\Programs\<appName>`, creates a Start Menu shortcut, excludes `.pdb` files, and optionally adds the Explorer folder context-menu entry under the current user's registry hive. Inno Setup removes that entry during uninstall.

KIS Explorer uses a new installer ID. Uninstall any earlier SUTWinExplorer installation before installing it; migration of old installations is not supported.

`installer\Release` contains distributable installer artifacts. `installer\Temp` contains generated ISS scripts and Inno Setup's temporary build data. Both directories are ignored by Git; the JSON, template, and build script remain versioned. Re-running the script recreates or replaces the generated scripts and installer files for the selected profiles. Outputs for unselected profiles are not removed.