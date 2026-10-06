// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
#ifndef AETHER_CORE_H
#define AETHER_CORE_H
#include <stdint.h>
#include <stddef.h>
typedef struct { double value; uint32_t phase; } AetherCountdown;
AetherCountdown aether_countdown_start(AetherCountdown state, double duration, double now);
double aether_countdown_remaining(AetherCountdown state, double now);
AetherCountdown aether_countdown_pause(AetherCountdown state, double now);
AetherCountdown aether_countdown_resume(AetherCountdown state, double now);
typedef struct { uint16_t required; uint8_t held, cancelled, visible, transition; } AetherGuide;
AetherGuide aether_guide_update(AetherGuide state, uint16_t active, uint8_t event);
// Immutable Rust-owned search segment; byte and grapheme buffers are copied on creation.
void *aether_search_create(const uint8_t *bytes, size_t length, const size_t *boundaries, size_t count, uint8_t numeric);
void aether_search_destroy(void *segment);
int32_t aether_search_score(const void *query, const void *segment);
typedef struct {
    double value, away_date;
    uint32_t phase, paused_phase, reason;
    uint8_t away_active, changed;
} AetherEyeCare;
AetherEyeCare aether_eyecare_event(AetherEyeCare state, uint32_t event, double now, double duration, double threshold, uint32_t reason);
double aether_eyecare_remaining(AetherEyeCare state, double now);
uint32_t aether_core_abi_version(void);
typedef struct { uint16_t code, physical; uint8_t modifiers; } AetherKey;
typedef struct { AetherKey source, target; uint8_t enabled, remap; } AetherRule;
uint8_t aether_shortcut_resolve(uint8_t required, uint8_t event, uint16_t physical, uint16_t active, uint8_t remap);
uint8_t aether_shortcut_claims(AetherKey key, const AetherRule *rules, size_t count);
void *aether_shortcut_validate(const AetherRule *rules, size_t count);
typedef struct { uint32_t kind; size_t source; const size_t *members; size_t count; } AetherIssueView;
size_t aether_validation_count(const void *handle);
AetherIssueView aether_validation_issue(const void *handle, size_t index);
void aether_validation_destroy(void *handle);
uint8_t aether_menu_include(AetherKey key, intptr_t top, const AetherKey *branch, size_t count);
typedef struct { double x, y, width, height; } AetherRect;
AetherRect aether_rect_quartz(AetherRect rect, double top);
intptr_t aether_rect_source(AetherRect window, const AetherRect *screens, size_t count);
AetherRect aether_rect_destination(AetherRect window, AetherRect source, AetherRect target, uint8_t resizable);
uint8_t aether_rect_approximately_equal(AetherRect a, AetherRect b);
AetherRect aether_rect_avoid_overlap(AetherRect frame, const AetherRect *occupied, size_t count, AetherRect bounds);
#endif
