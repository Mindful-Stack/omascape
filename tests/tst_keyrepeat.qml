import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "KeyRepeat"

    // Distinguishes: a grace that drifted. 50 ms sits between fcitx5's measured 1 ms
    // release→press gap and the ~80 ms a person needs to re-press the same key.
    function test_the_grace_is_fifty_ms() {
        compare(Logic.KEY_RELEASE_GRACE_MS, 50)
    }
    // Distinguishes: an input-method repeat pair read as a real release and a fresh press — the
    // measured cause of the peek flicker. The press after a pending release is a repeat, and the
    // release is dropped so it never takes effect.
    function test_a_press_while_its_release_is_pending_is_a_repeat() {
        var tr = Logic.keyRepeatTracker()
        compare(Logic.trackPress(tr, Qt.Key_Space, false), false, "the first press is real")
        verify(Logic.trackRelease(tr, Qt.Key_Space, false, 1000), "a real release is recorded")
        compare(Logic.trackPress(tr, Qt.Key_Space, false), true, "same key while pending: a repeat")
        compare(Logic.dueReleases(tr, 5000, 50, false).length, 0, "the dropped release never takes effect")
    }
    // Distinguishes: a release that never takes effect. Past the grace, it is due exactly once.
    function test_a_release_takes_effect_once_after_the_grace() {
        var tr = Logic.keyRepeatTracker()
        Logic.trackRelease(tr, Qt.Key_Space, false, 1000)
        compare(Logic.dueReleases(tr, 1049, 50, false).length, 0, "not before the grace")
        compare(Logic.dueReleases(tr, 1050, 50, false), [Qt.Key_Space])
        compare(Logic.dueReleases(tr, 9999, 50, false).length, 0, "and only once")
        compare(Logic.hasPendingReleases(tr), false)
    }
    // Distinguishes: a detector that swallows a real second press. After the release has taken
    // effect, the next press of the same key is fresh.
    function test_a_press_after_the_release_took_effect_is_fresh() {
        var tr = Logic.keyRepeatTracker()
        Logic.trackRelease(tr, Qt.Key_2, false, 1000)
        Logic.dueReleases(tr, 1100, 50, false)
        compare(Logic.trackPress(tr, Qt.Key_2, false), false)
    }
    // Distinguishes: per-key state collapsed into one flag. Another key's press does not cancel
    // Space's pending release, and a force flush releases everything at once (focus loss).
    function test_keys_are_tracked_independently_and_force_flushes_all() {
        var tr = Logic.keyRepeatTracker()
        Logic.trackRelease(tr, Qt.Key_Space, false, 1000)
        compare(Logic.trackPress(tr, Qt.Key_W, false), false, "a different key is a fresh press")
        verify(Logic.hasPendingReleases(tr), "Space is still pending")
        Logic.trackRelease(tr, Qt.Key_W, false, 1010)
        var due = Logic.dueReleases(tr, 1011, 50, true)
        compare(due.length, 2, "force releases every pending key")
    }
    // Distinguishes: Qt's own repeat flag lost. A press Qt flags is a repeat; a release Qt flags
    // is ignored, as every release guard did before this change.
    function test_qt_flagged_repeats_keep_their_meaning() {
        var tr = Logic.keyRepeatTracker()
        compare(Logic.trackPress(tr, Qt.Key_Space, true), true)
        compare(Logic.trackRelease(tr, Qt.Key_Space, true, 1000), false, "ignored, not pending")
        compare(Logic.hasPendingReleases(tr), false)
    }
}
