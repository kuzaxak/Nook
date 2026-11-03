// Licensed under GPL-3.0. See LICENSE.

import SwiftUI

public extension View {
    /// A macOS grouped Form sets footer text against the trailing edge of its section.
    func settingsFooter() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}
