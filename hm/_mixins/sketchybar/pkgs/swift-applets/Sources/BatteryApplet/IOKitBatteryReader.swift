import Foundation
import IOKit.ps

public final class IOKitBatteryReader: BatteryReading {
  public init() {}

  public func currentState() -> BatteryState? {
    let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

    for source in sources {
      guard
        let values = IOPSGetPowerSourceDescription(snapshot, source)?
          .takeUnretainedValue() as? [String: Any],
        values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let currentCapacity = values[kIOPSCurrentCapacityKey] as? Int,
        let maximumCapacity = values[kIOPSMaxCapacityKey] as? Int,
        maximumCapacity > 0
      else {
        continue
      }

      let percentage = min(
        100,
        max(0, Int((Double(currentCapacity) / Double(maximumCapacity) * 100).rounded()))
      )
      return BatteryState(
        percentage: percentage,
        externalPower: values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
      )
    }
    return nil
  }
}
