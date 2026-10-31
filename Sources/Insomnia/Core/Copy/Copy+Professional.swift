// Professional: calm, factual, short sentences. No jokes, no emoji, no exclamation marks (PRODUCT.md §4).
// One or two lines per moment. Decorative moments (idle, awake, poke, milestone, dates, lid reopened) have no entry:
// `Narrator.line` returns nil and the UI hides the row. These lines surface only in notification bodies; the panel's
// quip row is hidden in Professional.

extension Copy {
    static let professional: [CopyKind: [String]] = [
        .activated: [
            "Keeping your Mac awake {duration}.",
        ],
        .deactivatedUser: [
            "Sleep is allowed.",
        ],
        .deactivatedTimer: [
            "The timer ran out.",
        ],
        .deactivatedBattery: [
            "Stopped keeping awake at {floor}% battery.",
        ],
        .watching: [
            "Keeping awake while {name} is running.",
        ],
        .targetExited: [
            "Insomnia stopped keeping your Mac awake.",
        ],
        .lidEngaged: [
            "Lid mode is on.",
        ],
        .thermal: [
            "Make sure it has airflow and isn't in a bag.",
        ],
        .lowPowerMode: [
            "Paused: Low Power Mode is on.",
        ],
        .batteryFloor: [
            "Your Mac will sleep normally.",
        ],
        .acRequired: [
            "Lid mode waits for the power adapter.",
        ],
        .lidCap: [
            "Lid mode paused after {cap} closed. Open the lid to reset the limit.",
        ],
        .recovered: [
            "Restored normal sleep after an unexpected quit.",
        ],
        .setupDone: [
            "Lid mode is ready.",
        ],
        .setupCancelled: [
            "Setup skipped.",
        ],
        .endingSoon: [
            "Choose +15 min to keep your Mac awake longer.",
        ],
    ]
}
