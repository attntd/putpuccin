pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.UPower

Singleton {
    id: root

    readonly property var batteryDevice: UPower.displayDevice
    readonly property bool batteryAvailable: batteryDevice && batteryDevice.ready && batteryDevice.isPresent
    readonly property string batteryState: !batteryDevice || !batteryDevice.ready ? "loading" : (batteryAvailable ? "ready" : "unavailable")
    readonly property int percentage: batteryAvailable ? Math.round(batteryDevice.percentage * 100) : 0
    readonly property bool charging: batteryAvailable && (batteryDevice.state === UPowerDeviceState.Charging || batteryDevice.state === UPowerDeviceState.PendingCharge)
    readonly property bool fullyCharged: batteryAvailable && batteryDevice.state === UPowerDeviceState.FullyCharged
    readonly property real timeRemaining: !batteryAvailable ? 0 : (charging ? batteryDevice.timeToFull : batteryDevice.timeToEmpty)
    readonly property bool healthAvailable: batteryAvailable && batteryDevice.healthSupported
    readonly property int health: healthAvailable ? Math.round(batteryDevice.healthPercentage) : 0

    readonly property int profile: PowerProfiles.profile
    readonly property string profileName: profile === PowerProfile.PowerSaver ? "Oszczędny"
        : profile === PowerProfile.Performance ? "Wydajność" : "Zrównoważony"
    readonly property bool performanceAvailable: PowerProfiles.hasPerformanceProfile

    function setProfile(profile) {
        if (profile === PowerProfile.Performance && !root.performanceAvailable)
            return;
        PowerProfiles.profile = profile;
    }
}
