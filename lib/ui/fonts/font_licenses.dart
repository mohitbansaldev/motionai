import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../fonts/font_catalog.dart';

/// Registers the bundled fonts' OFL / Apache licence texts with Flutter's
/// [LicenseRegistry] (shown by showLicensePage). Safe to call many times.
class FontLicenses {
  FontLicenses._();
  static bool _registered = false;

  static void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    LicenseRegistry.addLicense(() async* {
      for (final f in FontCatalog.all) {
        try {
          final text = await rootBundle.loadString(f.licensePath);
          yield LicenseEntryWithLineBreaks(['Font: ${f.family}'], text);
        } catch (_) {
          // Missing licence asset: skip rather than break the licence page.
        }
      }
    });
  }
}
