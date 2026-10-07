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
int32_t aether_search_best_score(const void *query, const void *const *segments, size_t count);
// Owned immutable documents retain segments independently of Swift handles.
void *aether_search_document_create(const void *const *segments, size_t count);
void *aether_search_document_merge(const void *const *documents, size_t count);
void aether_search_document_destroy(void *document);
int32_t aether_search_document_score(const void *query, const void *document);
typedef struct { intptr_t score; double timestamp; } AetherSearchRankEntry;
// Stable score/date descending order; invalid/nonfinite input leaves output untouched.
uint8_t aether_search_rank(const AetherSearchRankEntry *entries, size_t count, size_t *order, size_t capacity);
typedef struct { uint8_t kind, pinned; } AetherSearchBucketEntry;
typedef struct { const size_t *indices; size_t count; uint8_t identity; } AetherSearchBucketView;
void *aether_clipboard_search_buckets_create(const AetherSearchBucketEntry *entries, size_t count);
AetherSearchBucketView aether_clipboard_search_buckets_view(const void *owner, uint8_t tab);
void aether_clipboard_search_buckets_destroy(void *owner);
typedef struct {
    double value, away_date;
    uint32_t phase, paused_phase, reason;
    uint8_t away_active, changed;
} AetherEyeCare;
AetherEyeCare aether_eyecare_event(AetherEyeCare state, uint32_t event, double now, double duration, double threshold, uint32_t reason);
double aether_eyecare_remaining(AetherEyeCare state, double now);
uint32_t aether_core_abi_version(void);
typedef struct { int64_t id; uint8_t magsafe; } AetherEnrichmentPort;
typedef struct { int64_t id; uint8_t flags; } AetherEnrichmentSource;
typedef struct { int64_t display, stats, cable, hpm; size_t device_start, device_count; } AetherEnrichmentRow;
typedef struct { const AetherEnrichmentRow *rows; size_t count; const size_t *devices; size_t device_count; } AetherEnrichmentView;
void *aether_port_enrichment_create(const AetherEnrichmentPort *ports, size_t count,
    const AetherEnrichmentSource *displays, size_t display_count, const AetherEnrichmentSource *stats, size_t stats_count,
    const AetherEnrichmentSource *cables, size_t cable_count, const AetherEnrichmentSource *hpm, size_t hpm_count,
    const int64_t *devices, size_t device_count);
AetherEnrichmentView aether_port_enrichment_view(const void *plan);
void aether_port_enrichment_destroy(void *plan);
typedef struct { int64_t primary; size_t additional; } AetherUSBSelection;
AetherUSBSelection aether_usb_device_selection(const uint8_t *hubs, size_t count);
uint8_t aether_usb_device_class(int64_t code);
typedef struct { uint16_t code, physical; uint8_t modifiers; } AetherKey;
typedef struct { uint8_t bytes[16]; } AetherUUID;
typedef struct { AetherKey source, target; uint8_t enabled, remap; } AetherRule;
uint8_t aether_shortcut_resolve(uint8_t required, uint8_t event, uint16_t physical, uint16_t active, uint8_t remap);
uint8_t aether_shortcut_claims(AetherKey key, const AetherRule *rules, size_t count);
void *aether_shortcut_validate(const AetherRule *rules, size_t count);
typedef struct { uint32_t kind; size_t source; const size_t *members; size_t count; } AetherIssueView;
size_t aether_validation_count(const void *handle);
AetherIssueView aether_validation_issue(const void *handle, size_t index);
void aether_validation_destroy(void *handle);
// Borrow the same immutable rules and IDs used for validation. Flags use bit 0/1
// for UUID membership without/with monitoring. Invalid input leaves output untouched.
uint8_t aether_shortcut_execution_flags(const void *handle, const AetherRule *rules,
    const AetherUUID *ids, size_t count, uint8_t *flags, size_t capacity);
uint8_t aether_shortcut_execution_mask(uint8_t monitoring, uint8_t permission, uint8_t recording);
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
typedef struct { size_t count; size_t selected; uint8_t create; uint8_t changed; uint8_t accepted; uint8_t identity; } AetherClipboardGroupPlan;
typedef uint8_t (*AetherClipboardGroupMatching)(void *context, size_t index);
void *aether_clipboard_group_accumulator_create(void);
/* Per-pass only: equal groups require equal fingerprints. Matching synchronously borrows prior
   accepted positions in acceptance order; it must not access the accumulator or retain context. */
uint8_t aether_clipboard_group_accumulator_accept(void *owner, uint64_t fingerprint, size_t item_count,
    AetherClipboardGroupMatching matching, void *context);
void aether_clipboard_group_accumulator_destroy(void *owner);

AetherClipboardGroupPlan aether_clipboard_groups_plan(const AetherUUID *ids, size_t count, AetherUUID candidate_id,
    size_t unique_items, uint8_t action, AetherClipboardGroupMatching matching, void *context, size_t *output, size_t capacity);

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
// Read-only byte views borrow the decoded owner; copy them before destroying it.
typedef struct {
    AetherBytes id, preview, string_data, image_file_name, image_content_hash, rtf_data, rtf_file_name;
    double timestamp;
    size_t file_count;
    uint16_t present;
    uint8_t kind, pinned;
} AetherClipboardArchiveItem;
void *aether_clipboard_archive_load_decoded(void *store);
void aether_clipboard_archive_decoded_destroy(void *decoded);
uint32_t aether_clipboard_archive_decoded_status(const void *decoded);
size_t aether_clipboard_archive_decoded_count(const void *decoded, uint8_t section, size_t group);
AetherClipboardArchiveItem aether_clipboard_archive_decoded_item(const void *decoded, uint8_t section, size_t group, size_t index);
AetherBytes aether_clipboard_archive_decoded_url(const void *decoded, uint8_t section, size_t group, size_t index, size_t url);
AetherClipboardArchiveItem aether_clipboard_archive_decoded_group(const void *decoded, size_t index);
uint8_t aether_clipboard_archive_decoded_has_groups(const void *decoded);
typedef struct { AetherClipboardArchiveItem item; size_t url_start; } AetherClipboardArchiveWriteItem;
typedef struct { AetherBytes id; double timestamp; size_t start, count; } AetherClipboardArchiveWriteGroup;
uint32_t aether_clipboard_archive_write_records(void *store,
    const AetherClipboardArchiveWriteItem *rows, size_t row_count, size_t history_count, size_t pinned_count,
    const AetherBytes *urls, size_t url_count, const AetherClipboardArchiveWriteGroup *groups, size_t group_count, uint8_t has_groups);
// USB-C/Thunderbolt domain lifecycle; platform notifications remain native.
typedef struct { int64_t port_id; uint8_t phase; } AetherPortPhase;
void *aether_port_lifecycle_create(void);
void *aether_port_lifecycle_clone(const void *core);
void aether_port_lifecycle_destroy(void *core);
void aether_port_lifecycle_handle(void *core, uint8_t signal, int64_t port_id, double now);
void aether_port_lifecycle_reconcile(void *core, const int64_t *disconnected, size_t disconnected_count,
    const int64_t *resolved, size_t resolved_count, double now);
size_t aether_port_lifecycle_phases(const void *core, AetherPortPhase *output, size_t capacity);
typedef struct { int64_t port_id; double watts; uint8_t has_power; uint8_t direction; } AetherPortReading;
typedef struct { int64_t port_id; uint64_t token; double timestamp; double watts; int64_t segment; uint8_t removed; } AetherPortHistoryEvent;
void *aether_port_history_create(void);
void *aether_port_history_clone(const void *core);
void aether_port_history_destroy(void *core);
void aether_port_history_break(void *core);
void aether_port_history_append(void *core, const AetherPortReading *ports, size_t count, double now);
void aether_port_history_prune(void *core, double now);
size_t aether_port_history_events(const void *core, AetherPortHistoryEvent *output, size_t capacity);
typedef struct { size_t index; size_t depth; size_t parent_index; } AetherDeviceTreeRow;
int64_t aether_device_parent(int64_t location_id);
AetherDeviceTreeRow aether_device_query(const int64_t *ids, size_t count, int64_t location_id);
size_t aether_device_plan(const int64_t *ids, size_t count, AetherDeviceTreeRow *output, size_t capacity);
typedef struct { uint64_t key; int64_t power; int64_t voltage; int64_t current; uint8_t outgoing_label; } AetherSMCContract;
typedef struct { uint64_t key; int64_t id; uint8_t usb; uint8_t connected; uint8_t has_power; uint8_t incoming; } AetherSMCPort;
typedef struct { int64_t id; uint8_t usb; uint8_t winning; } AetherSMCNode;
typedef struct { uint64_t key; double watts; } AetherSMCPowerOut;
typedef struct { int64_t index; int64_t port_id; } AetherSMCResult;
uint8_t aether_smc_resolution_enabled(uint8_t enabled, uint8_t external);
uint8_t aether_smc_contract_consistent(int64_t power, int64_t voltage, int64_t current);
uint8_t aether_smc_contract_plausible(const AetherSMCContract *contract, uint8_t has_out, double watts);
uint8_t aether_smc_sourcing_power(double watts, uint8_t present);
uint8_t aether_smc_describes_charging(const AetherSMCNode *nodes, size_t count);
AetherSMCResult aether_smc_contract_select(const AetherSMCContract *contracts, size_t contract_count,
    const AetherSMCPort *ports, size_t port_count, const AetherSMCNode *nodes, size_t node_count,
    const AetherSMCPowerOut *outputs, size_t output_count, uint8_t external, uint8_t enabled, uint8_t candidate_only);
typedef struct { int64_t socket; int64_t width; } AetherPortTB;
typedef struct { int64_t port; int64_t id; uint8_t active; } AetherPortPhy;
typedef struct { uint8_t confirmed; uint8_t pending; } AetherPortTier;
AetherPortTier aether_port_tier_step(AetherPortTier state, uint8_t resolved);
size_t aether_port_tb_plan(const AetherPortTB *rows, size_t count, size_t *output, size_t capacity);
size_t aether_port_phy_plan(const AetherPortPhy *rows, size_t count, size_t *output, size_t capacity);
typedef struct { double watts; int64_t current; int64_t voltage; int64_t configured_voltage; int64_t configured_current;
    int64_t vconn_current; int64_t vconn_power; int64_t vconn_max_current; uint8_t incoming; uint8_t estimated; } AetherPortPower;
typedef struct { int64_t id; uint64_t key; uint8_t connected; uint8_t has_power; AetherPortPower power; } AetherPowerPort;
typedef struct { int64_t id; int64_t max_watts; int64_t voltage; int64_t current; uint8_t usb; uint8_t winning; } AetherPowerCharger;
typedef struct { uint8_t present; int64_t power; int64_t current; int64_t voltage; } AetherPowerTelemetry;
typedef struct { uint64_t key; double volts; double amps; } AetherPowerOutput;
typedef struct { size_t index; AetherPortPower power; double raw_current; double raw_voltage; uint8_t convert_raw; } AetherPowerPatch;
size_t aether_port_charger_power(const AetherPowerPort *ports, size_t count, const AetherPowerCharger *chargers, size_t charger_count,
    AetherPowerTelemetry telemetry, AetherPowerPatch *output, size_t capacity);
size_t aether_port_contract_power(const AetherPowerPort *ports, size_t count, int64_t id, int64_t voltage, int64_t current,
    AetherPowerTelemetry telemetry, AetherPowerPatch *output, size_t capacity);
size_t aether_port_output_power(const AetherPowerPort *ports, size_t count, const AetherPowerOutput *channels, size_t channel_count,
    AetherPowerPatch *output, size_t capacity);
typedef struct { int64_t id; uint8_t magsafe; } AetherRosterHPM;
typedef struct { int64_t id; uint8_t usb; uint8_t active; } AetherRosterCC;
typedef struct { int64_t port_id; int64_t hpm; int64_t phy; int64_t tb; int64_t power; uint8_t cc_active; } AetherRosterRow;
typedef struct { size_t count; size_t tb_count; uint8_t tier; } AetherRosterResult;
AetherRosterResult aether_port_roster(const AetherRosterHPM *hpm, size_t hpm_count,
    const AetherPortPhy *phy, size_t phy_count, const AetherPortTB *tb, size_t tb_count,
    const int64_t *power_ids, size_t power_count, const AetherRosterCC *cc, size_t cc_count,
    AetherRosterRow *output, size_t capacity, size_t *tb_output, size_t tb_capacity);
typedef struct { int64_t id; uint64_t key; uint8_t empty; uint8_t magsafe; } AetherJoinHPM;
typedef struct { uint64_t key; int64_t channel; uint8_t empty; } AetherJoinChannel;
typedef struct { int64_t id; uint64_t key; uint8_t usb; } AetherJoinPort;
typedef struct { int64_t port_id; size_t index; } AetherJoinPair;
typedef struct { int64_t hpm; int64_t channel; } AetherJoinRecovery;
typedef struct { size_t offset; int64_t channel; int64_t ordinal; int64_t keyed; } AetherJoinDisagreement;
AetherJoinRecovery aether_port_identity_recover(const AetherJoinHPM *hpm, size_t count, const AetherJoinChannel *channels, size_t channel_count);
size_t aether_port_pd_ordinal(const int64_t *offsets, size_t count, const int64_t *ids, size_t port_count, AetherJoinPair *output, size_t capacity);
size_t aether_port_pd_cross(const int64_t *ordinal_ids, size_t ordinal_count, const int64_t *ids, size_t count,
    const AetherJoinChannel *channels, size_t channel_count, const AetherJoinPort *ports, size_t port_count,
    AetherJoinDisagreement *output, size_t capacity);
typedef struct { int64_t id; uint8_t tb_link; } AetherTransportPort;
typedef struct { int64_t id; uint8_t active; uint8_t restricted; } AetherTransportSource;
typedef struct { int64_t hpm; int64_t cio; int64_t usb; int64_t dp; int64_t live_cio; int64_t identity_cio; } AetherTransportRow;
size_t aether_port_transports(const AetherTransportPort *ports, size_t count,
    const AetherTransportSource *hpm, size_t hpm_count, const AetherTransportSource *usb, size_t usb_count,
    const AetherTransportSource *dp, size_t dp_count, const AetherTransportSource *cio, size_t cio_count,
    AetherTransportRow *output, size_t capacity);
typedef struct { int64_t id; uint8_t active; } AetherPowerConnector;
size_t aether_port_connector_power(const AetherPowerConnector *connectors, size_t count,
    const AetherPowerCharger *chargers, size_t charger_count, const int64_t *smc_ports, size_t smc_count,
    AetherPowerTelemetry telemetry, uint8_t usb_node, uint8_t usb_smc, AetherPowerPatch *output, size_t capacity);
typedef struct { uint8_t transport; uint8_t on; } AetherDecodedLane;
AetherDecodedLane aether_port_lane(const uint8_t *transport, size_t count, const uint8_t *power, size_t power_count);
typedef struct { double watts; int64_t tx; int64_t rx; int64_t gbps; uint8_t generation; uint8_t link; uint8_t power; uint8_t energy; } AetherDecodedPort;
AetherDecodedPort aether_port_decode(uint8_t tb, int64_t width, int64_t speed, uint8_t power, int64_t watts, int64_t samples, int64_t energy);
typedef struct { uint8_t source; size_t index; } AetherAppReference;
typedef struct { size_t count; uint8_t valid; } AetherAppMoveResult;
size_t aether_app_order(const uint64_t *apps, size_t count, const uint64_t *prefs, size_t pref_count, size_t *output, size_t capacity);
AetherAppMoveResult aether_app_move(const uint64_t *apps, size_t count, const uint64_t *prefs, size_t pref_count,
    const int64_t *offsets, size_t offset_count, int64_t destination, AetherAppReference *output, size_t capacity);
typedef struct { double pressed; uint8_t has_pressed; uint8_t manual; uint8_t decision; } AetherABCGuard;
AetherABCGuard aether_abc_decide(AetherABCGuard state, uint8_t block, uint8_t abc, uint8_t observe, double now, double duration);
typedef struct { int64_t version; int64_t archive_version; int64_t archive_default; int64_t stored_default; double hold; uint8_t launch; uint8_t block; uint8_t show; uint8_t restore; } AetherPreferencesDefaults;
typedef struct { uint8_t launch; uint8_t block; uint8_t show; } AetherGeneralPreferences;
AetherPreferencesDefaults aether_preferences_defaults(void);
double aether_preferences_hold(double value);
uint8_t aether_preferences_window(uint8_t behavior, uint8_t restore);
uint8_t aether_preferences_legacy_launch(uint8_t app_key);
AetherGeneralPreferences aether_preferences_migrate(AetherGeneralPreferences current, uint8_t app_key, uint8_t launch, uint8_t has_launch, uint8_t block, uint8_t has_block);
int8_t aether_preferences_source(uint8_t current_exists, uint8_t legacy_exists);
uint8_t aether_preferences_should_write(uint8_t persist, uint8_t legacy, int64_t version);
uint8_t aether_physical_input_switch(uint16_t code);
uint8_t aether_application_letter(uint16_t code);
int32_t aether_application_letter_key(const uint8_t *bytes, size_t count);
// Default catalog strings have static lifetime. Plans own only source/recipe indices.
typedef struct {
    AetherBytes name, display, bundle, path;
    AetherKey source, target;
    uint8_t kind, argument, valid;
} AetherShortcutDefaultRecipe;
typedef struct { size_t index; uint8_t recipe; } AetherShortcutDefaultRef;
int64_t aether_shortcut_default_version(void);
AetherShortcutDefaultRecipe aether_shortcut_default_recipe(size_t index);
// mode: 0 make, 1 merge, 2 migrate. Callback and keys are borrowed synchronously.
void *aether_shortcut_defaults_plan(const AetherKey *keys, size_t count, uint8_t mode, int64_t version,
    uint8_t (*matches)(void *, size_t, uint8_t, size_t), void *context);
size_t aether_shortcut_defaults_count(const void *plan);
uint8_t aether_shortcut_defaults_identity(const void *plan);
AetherShortcutDefaultRef aether_shortcut_defaults_ref(const void *plan, size_t index);
void aether_shortcut_defaults_destroy(void *plan);
// Value states: caller owns synchronization, clocks and platform object lifetimes.
typedef struct { uint64_t revision; uint8_t current, cancel, clear; } AetherApplicationIntent;
AetherApplicationIntent aether_application_intent_update(AetherApplicationIntent state, uint8_t event, uint8_t accepted);
typedef struct { double deadline; uint8_t cancelled; } AetherActionDeadline;
AetherActionDeadline aether_action_deadline_create(double now, double duration);
AetherActionDeadline aether_action_deadline_cancel(AetherActionDeadline state);
uint8_t aether_action_deadline_active(AetherActionDeadline state, double now);
typedef struct {
    AetherActionDeadline timeout;
    int32_t source, target;
    uint8_t source_present, target_present, target_activated;
} AetherApplicationAction;
AetherApplicationAction aether_application_action_create(int32_t source, uint8_t source_present,
    int32_t target, uint8_t target_present, double now);
AetherApplicationAction aether_application_action_target(AetherApplicationAction state, int32_t target);
AetherApplicationAction aether_application_action_cancel(AetherApplicationAction state);
uint8_t aether_application_action_active(AetherApplicationAction state, double now);
typedef struct { AetherApplicationAction state; uint8_t accepted; } AetherApplicationActivation;
AetherApplicationActivation aether_application_action_activate(AetherApplicationAction state, int32_t pid);
uint8_t aether_application_action_matches(AetherApplicationAction state, int32_t pid, int32_t front, uint8_t front_present);
// Session-only layout memory. Serial owner; no platform pointers or persistent files.
typedef struct { AetherRect frame; int64_t id; int32_t pid; uint8_t flags; } AetherMoveWindow;
typedef struct { AetherRect frame, visible; uint32_t id; } AetherPlacementScreen;
typedef struct { AetherMoveWindow window; AetherPlacementScreen screen; } AetherSavedWindowLayout;
typedef struct { AetherSavedWindowLayout saved; uint8_t valid; } AetherSavedWindowLayoutView;
typedef struct { AetherUUID operation; int32_t pid; size_t count; } AetherWindowSnapshotInfo;
void *aether_window_history_create(void);
void aether_window_history_destroy(void *history);
uint8_t aether_window_history_record(void *history, AetherSavedWindowLayout saved, AetherUUID operation);
AetherSavedWindowLayoutView aether_window_history_saved(const void *history, int64_t id, uint32_t screen);
uint8_t aether_window_history_has_undo(const void *history);
// mode 0: closed/evicted handles; mode 1: successfully restored undo entries only.
uint8_t aether_window_history_remove(void *history, const int64_t *ids, size_t count, uint8_t mode);
// Owned immutable snapshot, independent of later mutations and history destruction.
void *aether_window_history_snapshot(const void *history);
AetherWindowSnapshotInfo aether_window_snapshot_info(const void *snapshot);
AetherSavedWindowLayoutView aether_window_snapshot_saved(const void *snapshot, size_t index);
void aether_window_snapshot_destroy(void *snapshot);
intptr_t aether_window_focus_choose(const AetherMoveWindow *windows, size_t count,
    const AetherPlacementScreen *screens, size_t screen_count, uint32_t target, uint8_t restore_minimized);
// Window progress value policy; platform calls and cancellation stay in the native adapter.
// flags: minimized=1, recorded=2, complete=4, failed=8, closed=16.
// decision command: 0 none, 1 set frame, 2 set minimized. Summary: 0 pending, 1 undo, 2 finish.
typedef struct { AetherRect desired; double next_attempt; uint8_t attempts, flags; } AetherWindowProgress;
typedef struct { AetherWindowProgress state; uint8_t command, disconnected; } AetherWindowProgressDecision;
typedef struct { AetherWindowProgress state; uint8_t record; } AetherWindowProgressAcknowledgement;
AetherWindowProgress aether_window_progress_create(AetherRect desired, uint8_t minimized);
AetherWindowProgressDecision aether_window_progress_decide(AetherWindowProgress state, uint8_t current,
    uint8_t fullscreen, uint8_t target, uint8_t positioned, uint8_t restored, double now);
AetherWindowProgressAcknowledgement aether_window_progress_ack(AetherWindowProgress state, uint8_t changed, uint8_t undo);
typedef struct { AetherRect original, desired; uint8_t flags, preferred; } AetherWindowProgressSummaryEntry;
typedef struct { size_t moved, failed; intptr_t focus; size_t restored; uint8_t command, valid; } AetherWindowProgressSummary;
AetherWindowProgressSummary aether_window_progress_summary(const AetherWindowProgressSummaryEntry *entries, size_t count,
    size_t unreadable, uint8_t undo, size_t *restored, size_t capacity);
typedef struct { double first; uint8_t has_first; } AetherWindowCollection;
typedef struct { AetherWindowCollection state; uint8_t ready; } AetherWindowCollectionDecision;
AetherWindowCollectionDecision aether_window_collection_update(AetherWindowCollection state, uint8_t standard, double now);
double aether_window_scope_time_limit(uint8_t scope);
// Cohort/geometry planning: canonical bounds for decisions, raw rectangle for same-screen preservation.
typedef struct { AetherMoveWindow window; AetherRect raw; } AetherWindowFreezeInput;
typedef struct { AetherRect frame, visible; uint32_t screen; uint8_t minimized, valid; } AetherWindowFreezeSaved;
typedef struct { size_t window, source, target; AetherRect desired; uint8_t minimized, valid; } AetherWindowFreezeEntry;
typedef struct {
    AetherWindowCollection collection; size_t count; intptr_t preferred;
    size_t fullscreen, minimized, unreadable; uint8_t ready, disconnected;
} AetherWindowFreezeInfo;
// scope: 0 existing, 1 appearing excluding IDs, 2 undo including IDs. All inputs/callbacks borrow synchronously.
void *aether_window_freeze_plan(const AetherWindowFreezeInput *inputs, size_t count,
    const AetherPlacementScreen *screens, size_t screen_count, const int64_t *ids, size_t id_count,
    uint8_t scope, uint32_t target_id, uint8_t restore, AetherWindowCollection collection, double now,
    AetherWindowFreezeSaved (*lookup)(void *, size_t, uint32_t, uint8_t), void *context);
AetherWindowFreezeInfo aether_window_freeze_info(const void *plan);
AetherWindowFreezeEntry aether_window_freeze_entry(const void *plan, size_t index);
void aether_window_freeze_destroy(void *plan);
// Application catalog tokens preserve native String equality; buffers borrow synchronously.
typedef struct { uint64_t initial, bundle, path; } AetherCatalogApp;
typedef struct { uint64_t initial, default_bundle; size_t start, count; uint8_t has_default; } AetherCatalogGroup;
typedef struct { uint64_t bundle, path; uint8_t enabled; } AetherCatalogTarget;
typedef struct { size_t count; intptr_t default_index, seed_index; } AetherCatalogInfo;
void *aether_app_catalog_create(const AetherCatalogApp *, size_t, const AetherCatalogGroup *, size_t,
    const uint64_t *, size_t, const AetherCatalogTarget *, size_t);
AetherCatalogInfo aether_app_catalog_info(const void *, size_t);
intptr_t aether_app_catalog_index(const void *, size_t, size_t);
void aether_app_catalog_destroy(void *);
#endif
