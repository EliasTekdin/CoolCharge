# CoolCharge build notes

This workspace builds a SpringBoard tweak with `apelin_project_build`. The build invokes `apelin/build.sh`, which compiles `Sources/Tweak.m` for the requested bootstrap, links Foundation/UIKit/IOKit, signs the dylib with `ldid -S`, writes the SpringBoard filter plist, and creates exactly one package artifact with `dpkg-deb` in Apelin's package folder.

The tweak reads IOKit power-source telemetry and AppleSmartBattery temperature, uses a learned charging-rate estimate for the Lock Screen panel, and applies only a conservative process-priority adjustment to SpringBoard while charging. It does not write private charging-controller properties or alter charging current/voltage.
