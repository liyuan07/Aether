// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

extension KeyCombination {
    var rustKey: AetherKey { AetherKey(code: keyCode, physical: physicalModifiers.rawValue, modifiers: modifiers.rawValue) }
}
extension ShortcutRule {
    var rustRule: AetherRule {
        if case let .remap(target) = action {
            return AetherRule(source: source.rustKey, target: target.rustKey, enabled: isEnabled ? 1 : 0, remap: 1)
        }
        return AetherRule(source: source.rustKey, target: AetherKey(), enabled: isEnabled ? 1 : 0, remap: 0)
    }
}
