//! Tutor result capture and history scheduling, separate from rendering.
const std = @import("std");
const desktop = @import("desktop-core");
const Tutor = @import("Tutor.zig");

pub const Frame = struct {
    now_us: u64,
    practicing: bool,
    rundown_fixture: bool,
    data_preview: bool,
};

pub fn update(tutor: *Tutor, io: std.Io, labels: *const desktop.label_cache.LabelCache, frame: Frame) !void {
    const practice = &tutor.controller;
    if ((practice.session.state == .complete or practice.stopped_result_pending) and practice.completed == null) {
        practice.completed = try captureResult(practice, io, labels, frame.now_us);
        // Rundown fixtures show results without saving them, except to the
        // scratch database of the data gallery.
        practice.completed_enqueued = frame.rundown_fixture and !frame.data_preview;
    }
    if (tutor.view.rundown.cleared) practice.completed_enqueued = true;
    enqueueResult(tutor);
    requestHistory(tutor, frame);
}

fn captureResult(
    practice: *desktop.practice_controller.Controller,
    io: std.Io,
    labels: *const desktop.label_cache.LabelCache,
    now_us: u64,
) !desktop.practice_results.Record {
    // Labels describe the result only when the run kept its key mapping.
    const same_mapping = std.mem.eql(u8, &practice.cohort.mapping, &practice.captured_cohort.mapping);
    const result_labels = if (same_mapping) labels.practiceLabels() else null;
    var record = if (practice.stopped_result_pending)
        try desktop.practice_results.captureStopped(&practice.session, practice.captured_cohort, result_labels, now_us)
    else
        try desktop.practice_results.capture(&practice.session, practice.captured_cohort, result_labels);
    try std.Io.randomSecure(io, &record.id);
    record.timestamp = @intCast(std.Io.Clock.real.now(io).toNanoseconds());
    record.seed = practice.exercise_seed;
    record.target_count = practice.captured_config.target_count;
    record.targets = practice.captured_config.targets;
    record.profile = practice.captured_profile;
    record.input_source = practice.captured_source;
    return record;
}

/// Queues the finished result for saving. A full queue blocks new runs.
fn enqueueResult(tutor: *Tutor) void {
    const practice = &tutor.controller;
    const history = &tutor.history;
    if (practice.completed) |record| if (!practice.completed_enqueued and history.queued < history.queue.len) {
        if (history.enqueueWithTiming(record, tutor.timing.payload())) |_| {
            practice.completed_enqueued = true;
        } else |err| history.error_value = err;
    };
    practice.save_blocked = practice.completed != null and !practice.completed_enqueued and history.queued == history.queue.len;
    if (practice.save_blocked) history.error_value = error.PracticeSaveQueueFull;
}

/// Reads the history of the cohort on display after saves, explicit
/// requests, or when practice starts on a different cohort.
fn requestHistory(tutor: *Tutor, frame: Frame) void {
    const practice = &tutor.controller;
    const history = &tutor.history;
    const rundown = &tutor.view.rundown;
    const cohort = if (tutor.view.curriculum_open)
        practice.cohortFor(tutor.view.curriculum.config)
    else if (tutor.view.review_open)
        practice.configCohort()
    else if (rundown.reviewed) |record|
        record.cohort
    else if (practice.completed) |record|
        record.cohort
    else
        practice.configCohort();
    const requested = rundown.refresh or rundown.retry or rundown.clear;
    const stale = !tutor.history_loaded or !std.meta.eql(cohort, history.cohort);
    const wanted = history.queued > 0 or requested or (frame.practicing and !frame.rundown_fixture and stale);
    const may_retry = history.error_value == null or rundown.retry or rundown.clear;
    if (history.worker != null or !may_retry or !wanted) return;
    const inspected = tutor.view.progress.inspect orelse
        if (rundown.reviewed) |record| record.id else if (practice.completed) |record| record.id else null;
    history.request(cohort, rundown.before, rundown.clear, rundown.retry, inspected) catch |err| {
        history.error_value = err;
    };
    tutor.history_loaded = true;
    rundown.refresh = false;
    rundown.retry = false;
    rundown.clear = false;
}
