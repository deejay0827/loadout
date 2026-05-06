// Placeholder. Run `flutterfire configure` to regenerate this file with
// real values for each platform after creating the Firebase project.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform. '
          'Run `flutterfire configure` to generate them.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBR2YppV0YR6VZ3eKgi1py1audpCLMmDu4',
    appId: '1:1050892389392:android:7a78dfd09b356771d4ce95',
    messagingSenderId: '1050892389392',
    projectId: 'loadout-precision-reloading',
    storageBucket: 'loadout-precision-reloading.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCblt61VZCsx29hCBzVCNgj1-TZ8gUu7Y8',
    appId: '1:1050892389392:ios:d839fab5d268e9f8d4ce95',
    messagingSenderId: '1050892389392',
    projectId: 'loadout-precision-reloading',
    storageBucket: 'loadout-precision-reloading.firebasestorage.app',
    androidClientId: '1050892389392-ilu3faaa8nu9od3io70g0fanp0qs0ks5.apps.googleusercontent.com',
    iosClientId: '1050892389392-r4625bpimt7lvm1fp5g42dsv4je018d1.apps.googleusercontent.com',
    iosBundleId: 'com.johnsondigital.loadout',
  );

}