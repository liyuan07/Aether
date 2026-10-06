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
typedef struct { uint8_t *bytes; size_t length; uint32_t status; } AetherBufferView;
void *aether_file_read(const char *path, uint8_t reject_links);
uint32_t aether_file_write(const char *path, const uint8_t *bytes, size_t length, uint8_t private_file, uint8_t synchronize);
AetherBufferView aether_buffer_view(void *handle);
void aether_buffer_destroy(void *handle);
void *aether_memo_create(const char *directory);
void aether_memo_destroy(void *store);
void *aether_memo_load(void *store);
uint32_t aether_memo_save(void *store, const uint8_t *json, size_t length);
uint32_t aether_memo_add(void *store, const uint8_t *json, size_t length);
uint32_t aether_memo_complete(void *store, const char *id);
void *aether_memo_snapshot(const void *store, uint8_t sorted);
size_t aether_memo_order(const void *store, size_t *output, size_t capacity);
typedef struct { const uint8_t *data; size_t length; } AetherBytes;
void *aether_prompt_request(AetherBytes model, AetherBytes rules, AetherBytes input);
void *aether_prompt_response(int32_t status, AetherBytes body);
void *aether_prompt_endpoint(uint8_t scheme, AetherBytes host, AetherBytes path);
typedef struct { uint64_t generation; uint8_t active, writable, changed; } AetherPromptGate;
AetherPromptGate aether_prompt_begin(AetherPromptGate state);
AetherPromptGate aether_prompt_cancel(AetherPromptGate state);
AetherPromptGate aether_prompt_finish(AetherPromptGate state, uint64_t token, uint8_t acceptable);
AetherPromptGate aether_prompt_history_writable(AetherPromptGate state, uint8_t writable);
intptr_t aether_prompt_limit(intptr_t limit);
uint8_t aether_prompt_credential_consistent(uint8_t fingerprint_present, uint8_t key_empty, uint8_t matches);
typedef struct { uint8_t bytes[16]; } AetherUUID;
typedef struct { AetherUUID id; double timestamp; uint8_t matched; } AetherHistoryRow;
size_t aether_prompt_history_plan(const AetherHistoryRow *rows, size_t count, uint32_t action, AetherUUID id, size_t limit, size_t *output, size_t capacity);
void *aether_prompt_store_create(const char *directory, AetherBytes fallback);
void aether_prompt_store_destroy(void *store);
void *aether_prompt_store_load(void *store, uint32_t slot);
uint32_t aether_prompt_store_save(void *store, uint32_t slot, AetherBytes data);

void *aether_quick_create(const char *path);
void aether_quick_destroy(void *store);
void *aether_quick_load(void *store);
uint32_t aether_quick_save(void *store, AetherBytes data);
uint32_t aether_quick_comparisons(void *store, AetherBytes data);
void *aether_quick_apply(void *store, AetherBytes command);

typedef struct { uint8_t match_kind; double timestamp; size_t start; size_t count; } AetherQuickSearchCollection;
typedef struct { uint8_t key_match; uint8_t value_match; double timestamp; } AetherQuickSearchEntry;
typedef struct { size_t collection; size_t start; size_t count; intptr_t rank; } AetherQuickSearchSection;
size_t aether_quick_search(const AetherQuickSearchCollection *collections, size_t collection_count,
    const AetherQuickSearchEntry *entries, size_t entry_count, AetherQuickSearchSection *sections, size_t section_capacity,
    size_t *indices, size_t index_capacity);

uint8_t aether_clipboard_content_fields(uint8_t kind, uint8_t other_kind, uint8_t both_hashes);
uint8_t aether_clipboard_history_bounded(size_t count, size_t limit);
uint8_t aether_clipboard_content_match(uint8_t kind, uint8_t other_kind, uint8_t flags);
uint8_t aether_clipboard_group_equal(const uint8_t *flags, size_t left_count, size_t right_count);
typedef struct { AetherUUID id; double timestamp; uint8_t kind; uint8_t matching; uint8_t protected; uint8_t valid; } AetherClipboardRow;
typedef struct { size_t count; uint8_t inserted; uint8_t cleanup; } AetherClipboardPlan;
AetherClipboardPlan aether_clipboard_history_plan(const AetherClipboardRow *rows, size_t count, AetherClipboardRow candidate,
    uint8_t action, size_t limit, double cutoff, uint8_t has_cutoff, size_t *output, size_t capacity);

uint8_t aether_clipboard_tab_includes(uint8_t tab, uint8_t kind, uint8_t pinned);
typedef struct { size_t history_count; size_t pinned_count; uint8_t pinned; } AetherClipboardPinPlan;
AetherClipboardPinPlan aether_clipboard_pin_plan(const AetherClipboardRow *history, size_t history_count, const AetherClipboardRow *pinned, size_t pinned_count,
    AetherClipboardRow candidate, uint8_t candidate_pinned, uint8_t action, size_t limit, size_t *history_output, size_t history_capacity,
    size_t *pinned_output, size_t pinned_capacity);

typedef struct { int64_t last_change; int64_t pending_change; uint8_t pending; uint8_t failures; uint8_t needed; } AetherClipboardCapture;
AetherClipboardCapture aether_clipboard_capture_probe(AetherClipboardCapture state, int64_t change);
AetherClipboardCapture aether_clipboard_capture_failed(AetherClipboardCapture state, int64_t change);
AetherClipboardCapture aether_clipboard_capture_observed(AetherClipboardCapture state, int64_t change);
AetherClipboardCapture aether_clipboard_capture_committed(AetherClipboardCapture state, int64_t change);
typedef struct { uint64_t history_revision; uint64_t maintenance_generation; double last_maintenance; } AetherClipboardWork;
AetherClipboardWork aether_clipboard_history_changed(AetherClipboardWork state);
AetherClipboardWork aether_clipboard_maintenance_begin(AetherClipboardWork state, double now);
uint8_t aether_clipboard_revision_current(AetherClipboardWork state, uint64_t revision);
uint8_t aether_clipboard_maintenance_current(AetherClipboardWork state, uint64_t generation);
uint8_t aether_clipboard_maintenance_due(AetherClipboardWork state, double now);
typedef struct { uint8_t pending; uint8_t cleanup; uint8_t scheduled; uint8_t schedule; } AetherClipboardWriter;
typedef struct { AetherClipboardWriter state; uint8_t write; uint8_t cleanup; } AetherClipboardWriteStep;
AetherClipboardWriter aether_clipboard_writer_enqueue(AetherClipboardWriter state, uint8_t cleanup);
AetherClipboardWriteStep aether_clipboard_writer_take(AetherClipboardWriter state);
size_t aether_clipboard_resource_plan(const AetherBytes *kept, size_t kept_count, const AetherBytes *files, size_t file_count, size_t *output, size_t capacity);

void *aether_clipboard_archive_create(const char *path);
void aether_clipboard_archive_destroy(void *store);
void *aether_clipboard_archive_read(void *store);
void aether_clipboard_archive_block(void *store);
uint32_t aether_clipboard_archive_write(void *store, AetherBytes data);
uint32_t aether_clipboard_archive_validate(AetherBytes data);
// USB-C/Thunderbolt domain lifecycle; platform notifications remain native.
typedef struct { int64_t port_id; uint8_t phase; } AetherPortPhase;
void *aether_port_lifecycle_create(void);
void *aether_port_lifecycle_clone(const void *core);
void aether_port_lifecycle_destroy(void *core);
void aether_port_lifecycle_handle(void *core, uint8_t signal, int64_t port_id, double now);
void aether_port_lifecycle_reconcile(void *core, const int64_t *disconnected, size_t disconnected_count,
    const int64_t *resolved, size_t resolved_count, double now);
size_t aether_port_lifecycle_phases(const void *core, AetherPortPhase *output, size_t capacity);
#endif
