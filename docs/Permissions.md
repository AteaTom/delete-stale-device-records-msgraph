# Permissions

This solution uses **delegated** (work or school account) permissions via
`Connect-MgGraph`. No application permissions, client secrets, or certificates
are used or required.

## Verified cmdlet-to-permission mapping (Microsoft Graph PowerShell SDK, v1.0)

| Cmdlet | Module | Minimum delegated permission |
| --- | --- | --- |
| `Get-MgDevice` | Microsoft.Graph.Identity.DirectoryManagement | `Device.Read.All` |
| `Remove-MgDevice` | Microsoft.Graph.Identity.DirectoryManagement | `Device.ReadWrite.All` |
| `Get-MgDeviceManagementManagedDevice` | Microsoft.Graph.DeviceManagement | `DeviceManagementManagedDevices.Read.All` |
| `Get-MgDeviceManagementWindowsAutopilotDeviceIdentity` | Microsoft.Graph.DeviceManagement.Enrollment | `DeviceManagementServiceConfig.Read.All` |
| `Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity` | Microsoft.Graph.DeviceManagement.Enrollment | `DeviceManagementServiceConfig.ReadWrite.All` |
| `Remove-MgDeviceManagementManagedDevice` | Microsoft.Graph.DeviceManagement | `DeviceManagementManagedDevices.ReadWrite.All` |

Confirmed against the official Microsoft Graph PowerShell SDK reference
(`learn.microsoft.com/powershell/module/...`) at the time this project was
built. Re-verify against current documentation before each major release,
since Microsoft periodically updates minimum-privilege guidance.

## Scopes requested by mode

| Mode | Scopes requested |
| --- | --- |
| Audit | `Device.Read.All`, `DeviceManagementManagedDevices.Read.All`, `DeviceManagementServiceConfig.Read.All` |
| Interactive / Automatic | All read scopes above, plus `Device.ReadWrite.All` and `DeviceManagementServiceConfig.ReadWrite.All` |
| Interactive / Automatic with `-ScrappedDeviceCsvPath` | All of the above, plus `DeviceManagementManagedDevices.ReadWrite.All` (required to remove Intune managed-device records for scrapped hardware) |

`Test-GraphPermissions` compares the scopes actually granted to the signed-in
session (`(Get-MgContext).Scopes`) against the scopes required for the
selected mode. If a destructive mode is missing a required write scope, the
script logs a warning, still writes all reports, and **skips deletion**
rather than failing the whole run — unless global discovery itself is also
incomplete, in which case the run exits with code `4`.

## Microsoft Entra role considerations

The signed-in user must be able to consent to (or have been granted) the
scopes above. Built-in Entra roles such as **Intune Administrator** typically
cover the Intune/Autopilot scopes, while **Cloud Device Administrator** or
**Global Administrator** typically cover Entra device read/write. Least
privilege: prefer a custom role or a combination of built-in roles that grants
only what is listed above, rather than Global Administrator.

## Intune licensing

Reading and managing Windows Autopilot identities and Intune managed devices
requires an Intune (or Microsoft Endpoint Manager) license assigned in the
tenant. No license is required merely to read Entra device objects.

## National cloud limitations

This project targets the public Microsoft Graph cloud (`graph.microsoft.com`).
Sovereign/national clouds (e.g., Microsoft Graph for US Government, China
operated by 21Vianet) may require `Connect-MgGraph -Environment` and different
base URLs; this has not been verified for this project and should be tested
before use in those environments.

## What destructive modes can and cannot do

- Deletion modes (Interactive, Automatic) may remove **only**: Windows
  Autopilot device identities and Microsoft Entra ID device objects.
- Intune managed-device records are **never** deleted by the activity-based
  stale-device workflow, in any mode.
- The one exception is the explicit `-ScrappedDeviceCsvPath` workflow: for
  serial numbers you provide, it removes the matching Windows Autopilot
  identity, Intune managed device, and Entra device object. It never acts on
  any serial number not present in that file.
- iOS and Android devices are never looked up in, or deleted from, Windows
  Autopilot.
