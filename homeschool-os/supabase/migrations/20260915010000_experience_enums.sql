-- =============================================================================
-- 0109  STEP 8 PHASE 2 - the enum values, alone
-- =============================================================================
-- Its own migration for the reason this repository has hit four times now:
-- PostgreSQL will not let a freshly added enum label be USED in the transaction
-- that adds it, and 0110 uses all of these immediately.
--
-- `learning_activity` as a RESOURCE TYPE is the important one. A child needs to
-- be able to press start on her own morning without thereby gaining authority
-- over her own learning plan - she should not be able to reorder the path or
-- decide that a step is finished as a matter of record. Those are different
-- powers, and the capability matrix can only tell them apart if they are
-- different resources.
-- =============================================================================

alter type app.resource_type add value if not exists 'learning_activity';

-- What happened during an activity, in the log that already exists for it.
-- Extending the Phase 1 event kind rather than starting a second history:
-- "she started it" and "she opened the worksheet" belong on one timeline.
alter type app.learning_activity_event_kind add value if not exists 'session_started';
alter type app.learning_activity_event_kind add value if not exists 'session_paused';
alter type app.learning_activity_event_kind add value if not exists 'session_resumed';
alter type app.learning_activity_event_kind add value if not exists 'session_ended';
alter type app.learning_activity_event_kind add value if not exists 'resource_opened';
alter type app.learning_activity_event_kind add value if not exists 'artifact_added';
alter type app.learning_activity_event_kind add value if not exists 'note_added';
alter type app.learning_activity_event_kind add value if not exists 'evidence_offered';
alter type app.learning_activity_event_kind add value if not exists 'evidence_accepted';
alter type app.learning_activity_event_kind add value if not exists 'evidence_declined';
alter type app.learning_activity_event_kind add value if not exists 'today_pinned';
alter type app.learning_activity_event_kind add value if not exists 'today_hidden';
