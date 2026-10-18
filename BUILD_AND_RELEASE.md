# Build and Release

## Requirements

- Windows x64
- .NET 10 SDK

The application targets `net10.0-windows` and uses WPF. The publish profiles target `win-x64`.

## Build

From the repository root, build the application in Debug configuration:

```powershell
dotnet build .\SUTWinExplorer.csproj -c Debug
```

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

Both profiles enable native-library self-extraction. The publish output includes the application executable and a `.pdb` symbols file.

## Release Checklist

1. Build the application with `dotnet build .\SUTWinExplorer.csproj -c Debug`.
2. Publish the `Included` profile for machines that should not require a preinstalled .NET runtime, or publish the `Dependent` profile when the .NET 10 Desktop Runtime is a deployment prerequisite.
3. Distribute the contents of the selected output directory. Keep the `.pdb` file for diagnostics if desired; it is not required to run the application.

The publish profiles currently create application builds only. They do not create an installer or upload artifacts to a release service.