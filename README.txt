Gear VR Pointer
===============
Android app that connects to a Samsung Gear VR controller over Bluetooth and
uses it to control the phone: on-screen pointer, tap, swipe, scroll, Back,
Home and volume.

BUILD (Windows)
  1. Install Android Studio and open it once so it downloads the Android SDK.
  2. Double-click build-apk.bat in this folder.
  3. When it finishes, GearVRPointer.apk appears in this folder.
  If the build fails, the reason is in build-log.txt.

INSTALL ON THE PHONE
  1. Copy GearVRPointer.apk to the phone and open it (allow "install unknown apps").
  2. Open the app and follow steps 1-3 on its screen.
  3. On Android 13+, if the accessibility switch is greyed out: Settings > Apps >
     Gear VR Pointer > three-dot menu > "Allow restricted settings".

CONTROLS
  Trigger / touchpad click   tap (hold = long press, hold + move = swipe)
  Touchpad swipe             scroll
  Back                       back (hold = recent apps)
  Home                       home screen
  Volume keys                media volume
