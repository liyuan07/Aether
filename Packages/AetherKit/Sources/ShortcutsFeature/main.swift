import SwiftUI

if DesktopActivationHelper.isHelperProcess {
    DesktopActivationHelper.runHelperAndExit()
}

KeyPilotApp.main()
