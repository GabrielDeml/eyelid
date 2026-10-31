// Professional: calm, factual, short sentences. No jokes, no emoji, no exclamation marks (PRODUCT.md §4).
// One or two lines per pool. Professional has no quip row (`Narrator.line` returns nil for every moment), so the only
// pools are notification bodies (UX.md §10) and `lidEngaged` for the Settings personality sample
// (`CopyKind.professionalKinds`).

extension Copy {
    static let professional: [CopyKind: [String]] = [
        .deactivatedTimer: [
            "The timer ran out.",
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
        .batteryFloor: [
            "Your Mac will sleep normally.",
        ],
        .recovered: [
            "Restored normal sleep after an unexpected quit.",
        ],
        .endingSoon: [
            "Choose +15 min to keep your Mac awake longer.",
        ],
    ]
}
