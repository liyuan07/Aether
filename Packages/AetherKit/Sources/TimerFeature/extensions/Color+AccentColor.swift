/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#if os(macOS)
import SwiftUI
import Defaults
import AppKit

extension Color {
    /// Returns the accent color configured in settings, falling back to the system accent color.
    static var effectiveAccent: Color {
        Defaults[.accentColor]
    }

    /// Returns a subtle background variant of the accent color.
    static var effectiveAccentBackground: Color {
        Defaults[.accentColor].opacity(0.25)
    }

    func ensureMinimumBrightness(factor: CGFloat) -> Color {
        guard (0...1).contains(factor),
              let rgb = NSColor(self).usingColorSpace(.sRGB) else {
            return self
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let brightness = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        guard brightness > 0, brightness < factor else { return self }
        let scale = factor / brightness
        return Color(
            red: Double(min(red * scale, 1)),
            green: Double(min(green * scale, 1)),
            blue: Double(min(blue * scale, 1)),
            opacity: Double(alpha)
        )
    }
}
#endif
