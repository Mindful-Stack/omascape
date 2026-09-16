import QtQuick
import QtTest
import "../logic.js" as Logic

TestCase {
    name: "Motion"

    // "auto" follows the compositor's switch; "full"/"off" win regardless of it; anything
    // unknown is treated as "auto" (a typo in the config must never freeze the picker).
    function test_motion_policy() {
        compare(Logic.motionPolicy("auto", true), "full")
        compare(Logic.motionPolicy("auto", false), "off")
        compare(Logic.motionPolicy("full", false), "full")
        compare(Logic.motionPolicy("off", true), "off")
        compare(Logic.motionPolicy("sideways", false), "off")
        compare(Logic.motionPolicy(undefined, true), "full")
    }

    // Hyprland 0.56 reports {"bool": true}; older builds reported {"int": 1}. Anything the
    // probe cannot read counts as enabled: a failed probe must not lose motion.
    function test_hyprctl_animations_enabled_json() {
        compare(Logic.hyprAnimationsEnabled('{"option": "animations:enabled", "bool": true, "set": true }'), true)
        compare(Logic.hyprAnimationsEnabled('{"option": "animations:enabled", "bool": false, "set": true }'), false)
        compare(Logic.hyprAnimationsEnabled('{"option": "animations:enabled", "int": 0, "set": true }'), false)
        compare(Logic.hyprAnimationsEnabled('{"option": "animations:enabled", "int": 1, "set": true }'), true)
        compare(Logic.hyprAnimationsEnabled(""), true)
        compare(Logic.hyprAnimationsEnabled("not json"), true)
        compare(Logic.hyprAnimationsEnabled(undefined), true)
    }

    // Every key has a default; a wrong type, an unknown key, or unparseable text never
    // changes behaviour (the existing OmascapeConfig contract, now with `motion`).
    function test_parse_config_defaults_types_and_motion_key() {
        var d = Logic.parseConfig("")
        compare(d.scrim, true); compare(d.hint, true); compare(d.motion, "auto")
        var o = Logic.parseConfig('{"scrim": false, "motion": "off", "bogus": 1}')
        compare(o.scrim, false); compare(o.hint, true); compare(o.motion, "off")
        compare(Logic.parseConfig('{"motion": "full"}').motion, "full")
        compare(Logic.parseConfig('{"motion": "fast"}').motion, "auto")
        compare(Logic.parseConfig('{"motion": true}').motion, "auto")
        compare(Logic.parseConfig('{"scrim": "no", "hint": 0}').scrim, true)
        compare(Logic.parseConfig('{"scrim": "no", "hint": 0}').hint, true)
        compare(Logic.parseConfig('{bad').hint, true)
        compare(Logic.parseConfig('null').motion, "auto")
    }
}
