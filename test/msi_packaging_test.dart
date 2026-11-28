import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MSI template installs per machine into Program Files\\IPTVS', () {
    final template = File('windows/packaging/Product.wxs.in').readAsStringSync();

    // The install location is the point of MSI over MSIX: a normal folder the
    // user can see, plus a normal "Apps & features" entry.
    expect(template, contains('Name="IPTVS Player"'));
    expect(template, contains('Manufacturer="SNBogdanov"'));
    expect(template, contains('Scope="perMachine"'));
    expect(template, contains('Id="ProgramFiles64Folder"'));
    expect(template, contains('<Directory Id="INSTALLFOLDER" Name="IPTVS">'));
    expect(template, contains('<MajorUpgrade'));
    expect(template, contains('Version="@VERSION@"'));
    // UpgradeCode is permanent: changing it makes every release a second app.
    expect(template, contains('UpgradeCode="@UPGRADE_CODE@"'));
  });

  test('MSI creates both shortcuts, with the desktop one optional', () {
    final template = File('windows/packaging/Product.wxs.in').readAsStringSync();

    expect(template, contains('Id="StartMenuShortcut"'));
    expect(template, contains('Id="DesktopShortcut"'));
    expect(template, contains('Id="DesktopFolder"'));
    expect(template, contains('IPTVS_DESKTOP'));
    // Each shortcut is a feature whose level drops out when the checkbox is
    // cleared, so the page's choice actually decides what gets installed.
    expect(
      template,
      contains('Condition="IPTVS_STARTMENU &lt;&gt; &quot;1&quot;"'),
    );
    expect(
      template,
      contains('Condition="IPTVS_DESKTOP &lt;&gt; &quot;1&quot;"'),
    );
    // The elevated updater relaunches from here, so it has to be registered.
    expect(template, contains(r'Name="InstallDir"'));
    expect(template, contains(r'SOFTWARE\SNBogdanov\IPTVS'));
  });

  test('MSI wizard adds a checkbox page instead of the feature tree', () {
    final template = File('windows/packaging/Product.wxs.in').readAsStringSync();

    // Stock wizard plus our own pages: WixUI's feature tree renders the MSI
    // SelectionTree ("Entire feature will be installed…"), which is not what
    // the shortcuts need.
    expect(template, contains('UIRef Id="WixUI_Common"'));
    expect(template, contains('Id="IptvsInstallDirDlg"'));
    expect(template, contains('Id="WixUILicenseRtf"'));
    expect(template, contains('Id="StartMenuCheck"'));
    expect(template, contains('Id="DesktopCheck"'));
    expect(template, contains('Property="IPTVS_STARTMENU"'));
    expect(template, contains('Property="IPTVS_DESKTOP"'));
    // "Core components" is shown but cannot be cleared.
    expect(template, contains('Id="CoreCheck"'));
    expect(template, contains('Disabled="yes"'));
    // An upgrade says so on its own page, and skips the EULA and the folder.
    expect(template, contains('Id="IptvsUpgradeDlg"'));
    expect(template, contains('WIX_UPGRADE_DETECTED'));
    // Maintenance is Repair/Remove with no Change — the component set is fixed
    // after install, so WixUI's stock page (and its Change button) is unused.
    expect(template, contains('Id="IptvsMaintenanceTypeDlg"'));
    expect(template, isNot(contains('Id="MaintenanceTypeDlg"')));
    // Remove stays reachable from that page even though Programs and features
    // offers the wizard as "Change" rather than a separate "Uninstall".
    expect(template, contains('Property Id="ARPNOREMOVE"'));
    expect(template, isNot(contains('Property Id="ARPNOMODIFY"')));
    // One artwork and one font set for every page, stock ones included.
    expect(template, contains('WixUIBannerBmp'));
    expect(template, contains('WixUIDialogBmp'));
    expect(template, contains('WixUI_Font_Title'));
    expect(template, contains('WixUI_Bmp_Banner'));
    expect(template, contains('Dialog="WelcomeDlg"'));

    final script = File('tool/package_windows_msi.ps1').readAsStringSync();
    expect(script, contains('WixToolset.UI.wixext'));
    expect(script, contains('@LICENSE_RTF@'));
  });

  test('packaging script drives WiX with the release version', () {
    final script = File('tool/package_windows_msi.ps1').readAsStringSync();

    expect(script, contains('Product.wxs.in'));
    expect(script, contains(r"'@VERSION@'"));
    expect(script, contains(r"'@UPGRADE_CODE@'"));
    expect(script, contains(r"'@COMPONENTS@'"));
    expect(script, contains('wix'));
    expect(script, contains('-arch x64'));
    expect(script, contains('B2F1C0DE-3E4A-4C55-9B7E-1D5C2A8F6E31'));
    // File components must keep one identity across builds: with
    // `MajorUpgrade afterInstallExecute` the old product is removed after the
    // new one is installed, and a random `Guid="*"` lets that removal delete
    // the files the new product just wrote. (The comment above may mention the
    // old spelling; the emitted component line must not use it.)
    expect(script, isNot(contains('Guid="*">')));
    expect(script, contains('New-StableComponentGuid'));
    expect(script, contains('SHA256'));
  });

  test('the release workflow ships an MSI, not an MSIX', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(workflow, contains('DISTRIBUTION_CHANNEL=githubDirect'));
    expect(workflow, contains('package_windows_msi.ps1'));
    expect(workflow, contains('iptvs-\$VERSION.msi'));
    expect(workflow, isNot(contains('package_windows_msix.ps1')));
    expect(workflow, isNot(contains('.msix')));
    expect(workflow, isNot(contains('Add-AppxPackage')));
  });
}
