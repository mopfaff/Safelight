import Foundation
import Security

// Stand-ins that keep the copy from changing the lock screen's clock: the face and weight it would write
// for the user are printed instead, and macOS's password dialog is never asked for, so the copy can't run
// anything as root. scripts/clock-appearance.sh checks the built app has no way left to call either.
func CFPreferencesSetValue(_ key: CFString, _ value: CFPropertyList?, _ applicationID: CFString, _ userName: CFString, _ hostName: CFString) {
    print("would set \(applicationID) \(key) = \(value.map { "\($0)" } ?? "nil")")
}

func AuthorizationCopyRights(_ authorization: AuthorizationRef, _ rights: UnsafePointer<AuthorizationRights>, _ environment: UnsafePointer<AuthorizationEnvironment>?,
                             _ flags: AuthorizationFlags, _ authorizedRights: UnsafeMutablePointer<UnsafeMutablePointer<AuthorizationRights>?>?) -> OSStatus {
    print("would ask for an administrator's password")
    return errAuthorizationCanceled
}

func kill(_ pid: pid_t, _ signal: Int32) -> Int32 {
    0
}
